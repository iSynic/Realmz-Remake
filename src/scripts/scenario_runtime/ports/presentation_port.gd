class_name PresentationPort
extends DelegatingScenarioPort

const COMMANDS := [
	"show_text",
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
		var target_kind := (
			"complexEncounter"
			if str(routed_request.get(
				"encounterKind",
				""
			)).to_lower().contains("complex")
			else "simpleEncounter"
		)
		var attachment_result := await invoke_behavior_attachments(
			"encounter",
			"enter",
			target_kind,
			[encounter_id],
			routed_request
		)
		if str(attachment_result.get("status", "")) == "error":
			return attachment_result
		var entry_override := _encounter_behavior_override(attachment_result)
		if not entry_override.is_empty():
			return entry_override
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
		var encounter_result := await super.execute(command_id, routed_request)
		if str(encounter_result.get("status", "")) == "error":
			return encounter_result
		var outcome := int(encounter_result.get("outcome", 0))
		var option_slot := int(encounter_result.get("optionSlot", -1))
		if option_slot >= 0:
			var option_request := routed_request.duplicate(true)
			option_request["response"] = encounter_result.duplicate(true)
			option_request["outcome"] = outcome
			option_request["slot"] = option_slot
			var option_attachments := await invoke_behavior_attachments(
				"encounter",
				"option",
				target_kind,
				[encounter_id],
				option_request
			)
			if str(option_attachments.get("status", "")) == "error":
				return option_attachments
			var option_override := _encounter_behavior_override(
				option_attachments
			)
			if not option_override.is_empty():
				encounter_result.merge(option_override, true)
				outcome = int(encounter_result.get("outcome", outcome))
		var result_request := routed_request.duplicate(true)
		result_request["response"] = encounter_result.duplicate(true)
		result_request["outcome"] = outcome
		result_request["slot"] = absi(outcome) - 1 if outcome != 0 else -1
		var result_attachments := await invoke_behavior_attachments(
			"encounter",
			"result",
			target_kind,
			[encounter_id],
			result_request
		)
		if str(result_attachments.get("status", "")) == "error":
			return result_attachments
		var result_override := _encounter_behavior_override(result_attachments)
		if not result_override.is_empty():
			encounter_result.merge(result_override, true)
		var completion_request := result_request.duplicate(true)
		completion_request["response"] = encounter_result.duplicate(true)
		var completion_result := await invoke_behavior_attachments(
			"encounter",
			"complete",
			target_kind,
			[encounter_id],
			completion_request
		)
		if str(completion_result.get("status", "")) == "error":
			return completion_result
		return encounter_result
	return await super.execute(command_id, routed_request)


func _encounter_behavior_override(result: Dictionary) -> Dictionary:
	if not bool(result.get("handled", false)):
		return {}
	for behavior_result_value: Variant in result.get("results", []):
		if not (behavior_result_value is Dictionary):
			continue
		var outcome_value: Variant = behavior_result_value.get("value")
		if not (outcome_value is Dictionary):
			continue
		var outcome: Dictionary = outcome_value
		match str(outcome.get("kind", "continue")):
			"close":
				return {
					"status": "ok",
					"outcome": 0,
					"behaviorOutcome": outcome.duplicate(true),
				}
			"resolve", "branch":
				if outcome.has("outcome"):
					return {
						"status": "ok",
						"outcome": int(outcome.get("outcome", 0)),
						"behaviorOutcome": outcome.duplicate(true),
					}
	return {}
