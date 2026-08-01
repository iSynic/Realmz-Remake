class_name PresentationPort
extends DelegatingScenarioPort

const COMMANDS := [
	"show_text",
	"query_encounter_definition",
	"query_media_definition",
	"show_scrolling_text",
	"choice",
	"encounter_response",
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
	"encounter_response": "_scenario_encounter_response",
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
	if command_id == "encounter_response":
		if _port_runtime != null \
				and _port_runtime.has_method("_scenario_encounter_response"):
			return await _port_runtime.call(
				"_scenario_encounter_response",
				routed_request
			)
		if _port_runtime == null \
				or not _port_runtime.has_method("_scenario_choice"):
			return {
				"status": "error",
				"message": "Scenario encounter-response presentation is unavailable",
			}
		var authored_responses: Variant = routed_request.get("responses", [])
		if not (authored_responses is Array) or authored_responses.is_empty():
			return {
				"status": "error",
				"message": "Scenario Encounter has no available responses",
			}
		var direct_model := fallback_direct_response_model(authored_responses)
		if str(direct_model.get("status", "")) == "error":
			return direct_model
		var direct_responses: Array = direct_model.get("responses", [])
		var choice_result: Dictionary = await _port_runtime.call(
			"_scenario_choice",
			{
				"prompt": str(routed_request.get("text", "")),
				"options": direct_model.get("labels", []),
				"encounterId": str(routed_request.get("encounterId", "")),
				"sectionId": str(routed_request.get("sectionId", "")),
			}
		)
		if str(choice_result.get("status", "")) == "error":
			return choice_result
		var selected_index := clampi(
			int(choice_result.get("choice", 0)),
			0,
			direct_responses.size() - 1
		)
		var selected: Dictionary = direct_responses[selected_index]
		choice_result["responseRef"] = {
			"kind": str(selected.get("kind", "choice")),
			"responseId": str(selected.get("id", "")),
		}
		return choice_result
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


static func fallback_direct_response_model(responses: Array) -> Dictionary:
	var labels: Array = []
	var direct_responses: Array = []
	for response_value: Variant in responses:
		if not (response_value is Dictionary):
			continue
		var response: Dictionary = response_value
		var kind := str(response.get("kind", "choice"))
		if kind in ["typed-reply", "spell", "item"]:
			continue
		if kind == "rogue" \
				and str(response.get("match", {}).get("outcome", "attempt")) \
				!= "attempt":
			continue
		if kind not in ["choice", "rogue", "back-out"]:
			continue
		var response_id := str(response.get("id", "")).strip_edges()
		if response_id.is_empty():
			return {
				"status": "error",
				"message": "Scenario Encounter response has no stable ID",
			}
		var label := str(response.get("label", "")).strip_edges()
		if label.is_empty():
			label = "Back out" if kind == "back-out" else kind.capitalize()
		labels.append(label)
		direct_responses.append(response)
	if direct_responses.is_empty():
		return {
			"status": "error",
			"message": (
				"Scenario Encounter requires the specialized Speak, Cast a spell, "
				+ "or Use an item presenter"
			),
		}
	return {
		"status": "ok",
		"labels": labels,
		"responses": direct_responses,
	}
