class_name ClassicRulesStateOpcodeRuntime
extends RefCounted

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func _execute_action_data_patch(
	extra_code_id: int
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Action data patch references missing Extra Code row %d"
			% extra_code_id
		)
	var source_id := int(values[2])
	var source: Dictionary = runtime.bundle.get_extra_action_point(
		source_id
	)
	if source.is_empty():
		return _halt(
			"Action data patch references missing Data ED3 row %d"
			% source_id
		)
	match int(values[0]):
		-1:
			return _patch_encounter_result(
				"simple",
				int(values[1]),
				int(values[4]),
				source
			)
		-2:
			return _patch_encounter_result(
				"complex",
				int(values[1]),
				int(values[4]),
				source
			)
	return _patch_map_action_point(values, source)


func _patch_map_action_point(
	values: Array,
	source: Dictionary
) -> Dictionary:
	var level_kind: String = runtime.runtime_state.level_type
	var level_selector := int(values[3])
	if level_selector != 0:
		level_kind = "land" if level_selector == 1 else "dungeon"
	var map_level := int(values[0])
	var record_index := int(values[1])
	var target: Dictionary = runtime.call(
		"_effective_map_action_point",
		level_kind,
		map_level,
		record_index
	)
	if target.is_empty():
		return _halt(
			"Missing %s map action point %d:%d"
			% [level_kind, map_level, record_index]
		)
	target["actions"] = source.get("actions", []).duplicate(true)
	runtime.runtime_state.set_action_point_override(
		str(target.get("id", "")),
		target
	)
	return _continue()


func _patch_encounter_result(
	encounter_kind: String,
	encounter_id: int,
	result_index: int,
	source: Dictionary
) -> Dictionary:
	if result_index < 0 or result_index > 3:
		return _halt(
			"Classic encounter result index must be between 0 and 3"
		)
	var encounter: Dictionary = runtime.bundle.get_encounter(
		encounter_kind,
		encounter_id
	)
	if encounter.is_empty():
		return _halt(
			"Missing %s encounter record %d"
			% [encounter_kind, encounter_id]
		)
	if encounter_kind == "simple":
		encounter = \
			runtime.runtime_state.get_effective_simple_encounter(
				encounter
			)
	else:
		encounter = \
			runtime.runtime_state.get_effective_complex_encounter(
				encounter
			)
	var encounter_actions: Variant = encounter.get("actions", [])
	var source_actions: Variant = source.get("actions", [])
	if not (encounter_actions is Array) \
			or not (source_actions is Array):
		return _halt(
			"Action data patch source or target has no action array"
		)
	encounter["actions"] = _replace_encounter_result_actions(
		encounter_actions,
		source_actions,
		result_index
	)
	if encounter_kind == "simple":
		runtime.runtime_state.set_simple_encounter_override(
			encounter_id,
			encounter
		)
	else:
		runtime.runtime_state.set_complex_encounter_override(
			encounter_id,
			encounter
		)
	return _continue()


func _replace_encounter_result_actions(
	encounter_actions: Array,
	source_actions: Array,
	result_index: int
) -> Array:
	var first_slot := result_index * 8
	var actions: Array = []
	for action_value: Variant in encounter_actions:
		if not (action_value is Dictionary):
			continue
		var slot := int(action_value.get("slot", -1))
		if slot < first_slot or slot >= first_slot + 8:
			actions.append(action_value.duplicate(true))
	for action_value: Variant in source_actions:
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value.duplicate(true)
		action["slot"] = first_slot + int(action.get("slot", 0))
		actions.append(action)
	actions.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("slot", -1)) \
				< int(b.get("slot", -1))
	)
	return actions


func _execute_same_as_other_action_point(
	record_index: int
) -> Dictionary:
	var target: Dictionary = runtime.call(
		"_effective_map_action_point",
		runtime.runtime_state.level_type,
		runtime.runtime_state.level_index,
		record_index
	)
	if target.is_empty():
		return _halt(
			"Missing same-map action point %d" % record_index
		)
	var percent := int(runtime.active_action_point_header.get(
		"percent",
		runtime.current_trigger.get("percent", 0)
	))
	var replacement: Dictionary = runtime.current_trigger.duplicate(
		true
	)
	replacement["actions"] = target.get(
		"actions",
		[]
	).duplicate(true)
	runtime.call("_set_cursor", replacement, 0)
	if percent < 1 or int(runtime.call("_roll_percent")) > percent:
		runtime.call("_clear_control_flow")
		return _invoke(
			"_completed_result",
			["same-door-percent-miss"]
		)
	return _continue()


func _values(extra_code_id: int) -> Array:
	return runtime.call("_extra_code_values", extra_code_id)


func _continue() -> Dictionary:
	return _invoke("_continue_result")


func _halt(message: String) -> Dictionary:
	return _invoke("_halt_with_error", [message])


func _invoke(method_name: String, arguments := []) -> Dictionary:
	if runtime == null or not runtime.has_method(method_name):
		return {
			"status": "error",
			"message": "Classic rules/state runtime requires '%s'"
				% method_name,
		}
	var result: Variant = runtime.callv(method_name, arguments)
	if result is Dictionary:
		return result
	return {
		"status": "error",
		"message": "Classic rules/state operation '%s' returned invalid state"
			% method_name,
	}
