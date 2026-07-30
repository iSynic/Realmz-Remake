class_name PresentationPort
extends DelegatingScenarioPort

const COMMANDS := [
	"show_text",
	"query_encounter_definition",
	"query_media_definition",
	"show_scrolling_text",
	"choice",
	"start_encounter",
	"play_sound",
	"play_music",
	"wait_for_click",
	"show_picture",
	"present_random_branch",
	"scenario_debug_pause",
]
const OPERATIONS := {
	"show_text": "_show_text",
	"query_encounter_definition": "_query_encounter_definition",
	"query_media_definition": "_query_media_definition",
	"show_scrolling_text": "_show_scrolling_text",
	"choice": "_show_yes_no_choice",
	"start_encounter": "_show_encounter",
	"play_sound": "_play_sound_command",
	"play_music": "_play_scenario_music",
	"wait_for_click": "_wait_for_click",
	"show_picture": "_show_classic_picture",
	"present_random_branch": "_present_random_branch",
	"scenario_debug_pause": "_scenario_debug_pause",
}


func port_id() -> String:
	return "core.presentation"


func service_operation(command_id: String) -> String:
	return str(OPERATIONS.get(command_id, ""))


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func resume_debugger(action: String) -> Dictionary:
	if _port_runtime == null \
			or not _port_runtime.has_method("resume_scenario_debugger"):
		return {
			"status": "error",
			"message": "Scenario debugger presentation service is unavailable",
		}
	return _port_runtime.call("resume_scenario_debugger", action)


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	var scenario_operation := str(
		routed_request.get("_scenarioApiOperation", "")
	)
	if scenario_operation == "core.presentation.text":
		routed_request["message"] = {
			"text": str(routed_request.get("text", "")),
		}
	if scenario_operation == "core.presentation.sound":
		routed_request["waitForCompletion"] = bool(
			routed_request.get("wait", false)
		)
	if scenario_operation == "core.presentation.scrolling-text":
		if _port_runtime == null \
				or not _port_runtime.has_method(
					"_hydrate_scenario_scrolling_text"
				):
			return {
				"status": "error",
				"message": "Scenario scrolling-text service is unavailable",
			}
		var hydrated: Dictionary = _port_runtime.call(
			"_hydrate_scenario_scrolling_text",
			routed_request
		)
		if str(hydrated.get("status", "")) == "error":
			return hydrated
		routed_request = hydrated.get("payload", {})
	if scenario_operation == "core.presentation.choice":
		if _port_runtime == null \
				or not _port_runtime.has_method("_scenario_choice"):
			return {
				"status": "error",
				"message": "Scenario choice presentation is unavailable",
			}
		return await _port_runtime.call("_scenario_choice", routed_request)
	if command_id == "wait_for_click" \
			and not bool(
				rule_option("presentation", "waitForAuthoredClicks", true)
			):
		return {
			"status": "ok",
			"acknowledged": true,
			"skipped": true,
			"reason": "gameplay-rules",
		}
	if command_id == "start_encounter":
		var encounter_id := str(routed_request.get("encounterId", ""))
		var extension_result := await invoke_runtime_binding(
			"encounters",
			"encounterResolvers",
			[
				"%s:%s" % [
					routed_request.get("encounterKind", ""),
					encounter_id,
				],
				encounter_id,
			],
			routed_request
		)
		if bool(extension_result.get("handled", false)):
			return extension_result
		return await super.execute(command_id, routed_request)
	return await super.execute(command_id, routed_request)
