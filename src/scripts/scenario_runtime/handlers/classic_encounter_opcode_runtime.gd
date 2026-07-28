class_name ClassicEncounterOpcodeRuntime
extends RefCounted

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_choice(accepted: bool) -> Dictionary:
	if runtime.pending_choice.is_empty():
		return _result(
			"_error_result",
			["No classic choice is waiting for a response"]
		)
	var choice: Dictionary = runtime.pending_choice
	runtime.pending_choice = {}
	var values: Array = choice["values"]
	var inverted := int(values[0]) != 0
	var apply_result := accepted != inverted
	if not apply_result:
		return _run()

	match int(values[1]):
		0:
			runtime.call("_clear_control_flow")
			return _result("_completed_result", ["choice-exit"])
		1:
			var branch_result := _result(
				"_branch_to_extra_action_point",
				[
					int(values[2]),
					bool(choice.get("gosub", false)),
					0,
				]
			)
			if str(branch_result.get("status", "")) != "continue":
				return branch_result
			return _run()
		2, 3:
			return _execute_encounter(
				"simple" if int(values[1]) == 2 else "complex",
				int(values[2])
			)
		4:
			return _result(
				"_yield_result",
				["eliminate_encounter_option", {}]
			)
		_:
			return _halt(
				"Choice references unsupported branch mode %d"
				% int(values[1])
			)


func resume_encounter(
	outcome: int,
	encounter_state := {}
) -> Dictionary:
	if runtime.pending_encounter.is_empty():
		return _result(
			"_error_result",
			["No classic encounter is waiting for a result"]
		)
	var encounter_context: Dictionary = runtime.pending_encounter
	runtime.pending_encounter = {}
	if not (encounter_state is Dictionary):
		return _halt("Classic encounter state must be a dictionary")
	if outcome < 0 or outcome > 4:
		return _halt(
			"Classic encounter outcome must be between 0 and 4"
		)
	var state_result := _apply_encounter_state(
		encounter_context,
		encounter_state
	)
	if not state_result.is_empty():
		return state_result
	if encounter_state.has("doorActivationActionPointId"):
		var door_action_point_id := int(
			encounter_state["doorActivationActionPointId"]
		)
		if door_action_point_id < 0:
			return _halt(
				"Classic door item returned an invalid action point"
			)
		runtime.call("_clear_control_flow")
		var door_result := _result(
			"_branch_to_extra_action_point",
			[door_action_point_id, false, 0]
		)
		if str(door_result.get("status", "")) != "continue":
			return door_result
		return _run()
	if outcome == 0:
		runtime.call("_clear_control_flow")
		return _result("_completed_result", ["encounter-cancelled"])
	if not runtime.encounter_origins.is_empty():
		var encounter_loop: Dictionary = runtime.encounter_origins[-1]
		if str(encounter_context.get("encounterKind", "")) == "complex" \
				and outcome == 4 \
				and int(encounter_loop.get("remainingAttempts", 1)) == 1 \
				and int(encounter_loop.get("maxAttempts", 1)) > 1:
			outcome = 3

	var encounter: Dictionary = encounter_context["encounter"]
	var outcome_trigger := _result(
		"_encounter_outcome_trigger",
		[
			str(encounter_context["encounterKind"]),
			int(encounter_context["encounterId"]),
			encounter,
			outcome,
		]
	)
	if outcome_trigger.is_empty():
		return _halt("Classic encounter has no action array")
	runtime.call("_set_cursor", outcome_trigger, 0)
	return _run()


func _execute_choice(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Choice action references missing Extra Code row %d"
			% extra_code_id
		)
	runtime.pending_choice = {
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"choice",
		{
			"extraCodeId": extra_code_id,
			"yesLabelId": int(values[3]),
			"yesLabel": _bundle().get_option_label(int(values[3])),
			"noLabelId": int(values[4]),
			"noLabel": _bundle().get_option_label(int(values[4])),
			"yesMessageId": int(values[3]),
			"yesMessage": _bundle().get_message(int(values[3])),
			"noMessageId": int(values[4]),
			"noMessage": _bundle().get_message(int(values[4])),
		},
	])


func _execute_encounter(
	encounter_kind: String,
	encounter_id: int,
	start_slot := 0
) -> Dictionary:
	var encounter := _bundle().get_encounter(
		encounter_kind,
		encounter_id
	)
	if encounter.is_empty():
		return _halt(
			"Missing %s encounter record %d"
			% [encounter_kind, encounter_id]
		)
	if encounter_kind == "simple":
		runtime.loaded_simple_encounter_id = encounter_id
		encounter = runtime.runtime_state.get_effective_simple_encounter(
			encounter
		)
	elif encounter_kind == "complex":
		runtime.loaded_complex_encounter_id = encounter_id
		encounter = runtime.runtime_state.get_effective_complex_encounter(
			encounter
		)
	var max_attempts := maxi(1, int(encounter.get("maxTimes", 1)))
	runtime.encounter_origins.append({
		"trigger": runtime.current_trigger,
		"actionIndex": runtime.current_action_index,
		"callStack": runtime.call_stack.duplicate(true),
		"actionPointHeader": \
			runtime.active_action_point_header.duplicate(true),
		"encounterKind": encounter_kind,
		"encounterId": encounter_id,
		"maxAttempts": max_attempts,
		"remainingAttempts": max_attempts,
	})
	return _yield_encounter(encounter_kind, encounter_id, start_slot)


func _yield_encounter(
	encounter_kind: String,
	encounter_id: int,
	start_slot: int
) -> Dictionary:
	var encounter := _bundle().get_encounter(
		encounter_kind,
		encounter_id
	)
	if encounter_kind == "simple":
		encounter = runtime.runtime_state.get_effective_simple_encounter(
			encounter
		)
	elif encounter_kind == "complex":
		encounter = runtime.runtime_state.get_effective_complex_encounter(
			encounter
		)
	var prompt_id := int(encounter.get("prompt", 0))
	var prompt_message := _bundle().get_message(prompt_id)
	var encounter_payload := {
		"encounterKind": encounter_kind,
		"encounterId": encounter_id,
		"encounter": encounter,
		"promptMessage": prompt_message,
		"startSlot": start_slot,
	}
	if not runtime.encounter_origins.is_empty():
		encounter_payload["maxAttempts"] = int(
			runtime.encounter_origins[-1].get("maxAttempts", 1)
		)
		encounter_payload["remainingAttempts"] = int(
			runtime.encounter_origins[-1].get("remainingAttempts", 1)
		)
	if encounter_kind == "complex":
		encounter_payload["itemTexts"] = _encounter_item_texts(encounter)
		encounter_payload["scenarioItems"] = _scenario_items()
	if encounter_kind == "complex" and bool(encounter.get("thief", false)):
		var thief_encounter_id := int(encounter.get("thiefSuccess", 0))
		var thief_encounter := _bundle().get_thief_encounter(
			thief_encounter_id
		)
		if thief_encounter.is_empty():
			return _halt(
				"Missing Data TD2 rogue encounter %d" % thief_encounter_id
			)
		var effective_thief_encounter: Dictionary = \
			runtime.runtime_state.get_effective_thief_encounter(
				thief_encounter
			)
		encounter_payload["thiefEncounter"] = effective_thief_encounter
		encounter_payload["thiefMessages"] = _thief_messages(
			effective_thief_encounter
		)
	runtime.pending_encounter = encounter_payload.duplicate(true)
	return _result(
		"_yield_result",
		["start_encounter", encounter_payload]
	)


func _encounter_item_texts(encounter: Dictionary) -> Array:
	var item_texts: Array = []
	var item_ids: Variant = encounter.get("itemIds", [])
	if not (item_ids is Array):
		return item_texts
	for item_id_value: Variant in item_ids:
		var item_id: int = abs(int(item_id_value))
		if item_id == 0:
			continue
		var item_text := _bundle().get_item_text(item_id)
		if not item_text.is_empty():
			item_texts.append(item_text)
	return item_texts


func _scenario_items() -> Array:
	var scenario_items: Array = []
	var item_ids: Array = _bundle().scenario_items_by_id.keys()
	item_ids.sort()
	for item_id_value: Variant in item_ids:
		scenario_items.append(
			_bundle().scenario_items_by_id[item_id_value]
		)
	return scenario_items


func _apply_encounter_state(
	encounter_context: Dictionary,
	encounter_state: Dictionary
) -> Dictionary:
	if str(encounter_context.get("encounterKind", "")) != "complex":
		return {}
	var thief_value: Variant = encounter_state.get("thiefEncounter", {})
	if not (thief_value is Dictionary) or thief_value.is_empty():
		return {}
	var encounter: Dictionary = encounter_context["encounter"]
	var expected_id := int(encounter.get("thiefSuccess", 0))
	if int(thief_value.get("id", -1)) != expected_id:
		return _halt(
			"Classic encounter returned the wrong Data TD2 record"
		)
	runtime.runtime_state.set_thief_encounter_override(
		expected_id,
		thief_value
	)
	return {}


func _thief_messages(thief_encounter: Dictionary) -> Array:
	var messages: Array = []
	var included_ids: Dictionary = {}
	for field_name: String in ["successText", "failureText"]:
		var ids: Variant = thief_encounter.get(field_name, [])
		if not (ids is Array):
			continue
		for id_value: Variant in ids:
			var message_id: int = abs(int(id_value))
			if message_id == 0 or included_ids.has(message_id):
				continue
			included_ids[message_id] = true
			messages.append(_bundle().get_message(message_id))
	var prompts: Variant = thief_encounter.get("prompts", [])
	if prompts is Array and not prompts.is_empty():
		var prompt_id: int = abs(int(prompts[0]))
		if prompt_id != 0 and not included_ids.has(prompt_id):
			messages.append(_bundle().get_message(prompt_id))
	return messages


func _bundle() -> ClassicCampaignBundle:
	return runtime.bundle


func _values(extra_code_id: int) -> Array:
	return runtime.call("_extra_code_values", extra_code_id)


func _run() -> Dictionary:
	return runtime.run_until_yield()


func _halt(message: String) -> Dictionary:
	return _result("_halt_with_error", [message])


func _result(method_name: String, arguments := []) -> Dictionary:
	if runtime == null or not runtime.has_method(method_name):
		return {
			"status": "error",
			"message": "Classic encounter runtime requires '%s'" % method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic encounter operation '%s' returned invalid state" \
			% method_name,
	}
