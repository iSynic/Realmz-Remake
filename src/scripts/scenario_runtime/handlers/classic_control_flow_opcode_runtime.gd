class_name ClassicControlFlowOpcodeRuntime
extends RefCounted

const MapBridgeScript = preload(
	"res://scripts/classic_runtime/classic_map_bridge.gd"
)

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_random_branch() -> Dictionary:
	if runtime.pending_random_branch.is_empty():
		return _error(
			"No classic random branch is waiting for presentation"
		)
	var random_branch: Dictionary = runtime.pending_random_branch
	runtime.pending_random_branch = {}
	return _apply_random_branch(random_branch)


func _execute_random_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Random branch references missing Extra Code row %d"
			% extra_code_id
		)
	var target_mode := int(values[0])
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Random branch has invalid target mode %d" % target_mode
		)
	var first_target := int(values[1])
	var last_target := int(values[2])
	if last_target < first_target:
		return _halt(
			"Random branch target range %d-%d is reversed"
			% [first_target, last_target]
		)
	var random_branch := {
		"targetMode": target_mode,
		"targetId": randi_range(first_target, last_target),
		"gosub": gosub,
	}
	var sound_id := int(values[3])
	var message_id := int(values[4])
	if sound_id == 0 and message_id == 0:
		return _apply_random_branch(random_branch)
	runtime.pending_random_branch = random_branch
	return _invoke("_yield_result", [
		"present_random_branch",
		{
			"extraCodeId": extra_code_id,
			"targetMode": target_mode,
			"targetRange": [first_target, last_target],
			"targetId": int(random_branch["targetId"]),
			"soundId": sound_id,
			"messageId": message_id,
			"message": runtime.bundle.get_message(message_id),
		},
	])


func _apply_random_branch(random_branch: Dictionary) -> Dictionary:
	var branch_result := _branch_to_action_or_encounter(
		int(random_branch["targetMode"]),
		int(random_branch["targetId"]),
		bool(random_branch.get("gosub", false))
	)
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return runtime.run_until_yield()


func _branch_to_action_or_encounter(
	target_mode: int,
	target_id: int,
	gosub: bool
) -> Dictionary:
	match target_mode:
		0:
			return _invoke(
				"_branch_to_extra_action_point",
				[target_id, gosub, 0]
			)
		1, 2:
			if gosub:
				var push_result := _invoke("_push_call_frame")
				if str(push_result.get("status", "")) != "continue":
					return push_result
			return _invoke(
				"_execute_encounter",
				[
					"simple" if target_mode == 1 else "complex",
					target_id,
				]
			)
	return _halt(
		"Unsupported classic branch target mode %d" % target_mode
	)


func _execute_quest_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Quest branch references missing Extra Code row %d"
			% extra_code_id
		)
	var quest_is_set: bool = runtime.runtime_state.is_quest_set(
		int(values[0])
	)
	var condition := int(values[1])
	var should_branch: bool = condition == 2 \
		or (condition == 1 and quest_is_set) \
		or (condition == 0 and not quest_is_set)
	if not should_branch:
		return _continue()
	return _branch_from_extra_code(values, gosub)


func _execute_quest_value_mutation(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Quest-value mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var quest_id := int(values[0])
	if quest_id < 0 or quest_id >= 100:
		return _halt(
			"Classic quest index %d is outside 0 through 99" % quest_id
		)
	var quest_value: int = runtime.runtime_state.adjust_quest_value(
		quest_id,
		int(values[1])
	)
	var threshold := int(values[3])
	if threshold == 0 or quest_value < threshold:
		return _continue()
	var target_mode := int(values[2]) - 1
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Quest-value mutation has invalid branch mode %d"
			% int(values[2])
		)
	return _branch_to_action_or_encounter(
		target_mode,
		int(values[4]),
		gosub
	)


func _execute_quest_value_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Quest-value branch references missing Extra Code row %d"
			% extra_code_id
		)
	var quest_id := int(values[0])
	if quest_id < 0 or quest_id >= 100:
		return _halt(
			"Classic quest index %d is outside 0 through 99" % quest_id
		)
	var threshold_met: bool = runtime.runtime_state.get_quest_value(
		quest_id
	) >= int(values[1])
	var target_id := int(values[4] if threshold_met else values[3])
	if target_id == 0:
		return _continue()
	var target_mode := int(values[2])
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Quest-value branch has invalid branch mode %d" % target_mode
		)
	return _branch_to_action_or_encounter(
		target_mode,
		target_id,
		gosub
	)


func _execute_quest_range_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 5:
		return _halt(
			"Quest-range branch references malformed Extra Code row %d"
			% extra_code_id
		)
	var first_quest := int(values[0])
	var last_quest := int(values[1])
	if first_quest < 0 or last_quest < first_quest or last_quest >= 100:
		return _halt(
			"Quest-range branch has invalid range %d through %d"
			% [first_quest, last_quest]
		)
	for quest_id: int in range(first_quest, last_quest + 1):
		if not runtime.runtime_state.is_quest_set(quest_id):
			return _continue()
	var target_mode := int(values[3])
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Quest-range branch has invalid target mode %d" % target_mode
		)
	return _branch_to_action_or_encounter(
		target_mode,
		int(values[4]),
		gosub
	)


func _execute_tile_parameter_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Tile-parameter branch references missing Extra Code row %d"
			% extra_code_id
		)
	var selector := int(values[0])
	var look_offset: Variant = runtime.execution_context.get(
		"lookOffset",
		{}
	)
	var look_x := (
		int(look_offset.get("x", 0))
		if look_offset is Dictionary else 0
	)
	var look_y := (
		int(look_offset.get("y", 0))
		if look_offset is Dictionary else 0
	)
	var tile_x: int = runtime.runtime_state.x + look_x
	var tile_y: int = runtime.runtime_state.y + look_y
	var tile_record: Dictionary = runtime.bundle.get_map_tile(
		runtime.runtime_state.level_type,
		runtime.runtime_state.level_index,
		tile_x,
		tile_y
	)
	if tile_record.is_empty():
		return _halt(
			"Tile-parameter branch cannot resolve the current map field"
		)
	var raw_tile: int = runtime.runtime_state.get_tile(
		runtime.runtime_state.level_type,
		runtime.runtime_state.level_index,
		tile_x,
		tile_y,
		int(tile_record.get("value", 0))
	)
	var tile_id := MapBridgeScript.normalize_tile_parameter_id(raw_tile)
	var matches := (
		tile_id == int(values[1]) if selector == 7 else false
	)
	var landlook := -1
	var attribute: Dictionary = {}
	if selector >= 1 and selector <= 6:
		var map: Dictionary = tile_record.get("map", {})
		var render: Variant = map.get("render", {})
		var baseline_landlook := (
			int(render.get("landlook", -1))
			if render is Dictionary else -1
		)
		landlook = runtime.runtime_state.get_landlook(
			runtime.runtime_state.level_type,
			runtime.runtime_state.level_index,
			baseline_landlook
		)
		attribute = runtime.bundle.get_land_tile_attribute(
			landlook,
			tile_id
		)
		if attribute.is_empty():
			return _halt(
				"Tile-parameter branch cannot resolve tile %d attributes for "
				+ "landlook %d" % [tile_id, landlook]
			)
		matches = _tile_parameter_is_set(attribute, selector)
	var target_id := int(values[4] if matches else values[3])
	if target_id == 0:
		return _continue()
	var target_mode := int(values[2])
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Tile-parameter branch has invalid branch mode %d"
			% target_mode
		)
	return _branch_to_action_or_encounter(
		target_mode,
		target_id,
		gosub
	)


func _tile_parameter_is_set(
	attribute: Dictionary,
	selector: int
) -> bool:
	match selector:
		1:
			return int(attribute.get("shore", 0)) != 0
		2:
			return int(attribute.get(
				"boatRequirement",
				attribute.get("needBoat", 0)
			)) != 0
		3:
			return int(
				attribute.get("pathFlag", attribute.get("isPath", 0))
			) != 0
		4:
			return int(
				attribute.get("blocksLos", attribute.get("los", 0))
			) != 0
		5:
			return int(attribute.get(
				"flyFloatRequired",
				attribute.get("flyFloat", 0)
			)) != 0
		6:
			return int(
				attribute.get("forestType", attribute.get("forest", 0))
			) != 0
	return false


func _execute_percent_branch(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Percent branch references missing Extra Code row %d"
			% extra_code_id
		)
	var roll := _roll_percent()
	if roll < 1 or roll > 100:
		return _halt(
			"Percent roll provider returned %d; expected 1 through 100"
			% roll
		)
	if roll > int(values[0]):
		return _continue()
	return _apply_force_branch_success(values)


func _execute_difficulty_branch(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Difficulty branch references missing Extra Code row %d"
			% extra_code_id
		)
	if runtime.runtime_state.difficulty < int(values[0]):
		return _continue()
	return _apply_force_branch_success(values)


func _apply_force_branch_success(values: Array) -> Dictionary:
	match int(values[1]):
		-2:
			return _finish_conditional_branch(
				"dropout-and-erase",
				true
			)
		1:
			return _branch_from_extra_code(values, false)
		2:
			return _finish_conditional_branch("keep-codes", false)
	return _continue()


func _roll_percent() -> int:
	if runtime.percent_roll_provider.is_valid():
		return int(runtime.percent_roll_provider.call())
	return randi_range(1, 100)


func _finish_conditional_branch(
	reason: String,
	consume_codes: bool
) -> Dictionary:
	var in_encounter: bool = not runtime.encounter_origins.is_empty()
	if consume_codes and not in_encounter:
		runtime.call("_set_origin_action_point_percent", -1)
	if in_encounter:
		var repeated_encounter := _invoke(
			"_repeat_encounter_after_fallthrough"
		)
		if not repeated_encounter.is_empty():
			return repeated_encounter
	runtime.call("_clear_control_flow")
	return _invoke("_completed_result", [reason])


func _branch_from_extra_code(
	values: Array,
	gosub: bool
) -> Dictionary:
	if gosub:
		var push_result := _invoke("_push_call_frame")
		if str(push_result.get("status", "")) != "continue":
			return push_result
	match int(values[2]):
		-1:
			runtime.call("_set_cursor", runtime.current_trigger, 7)
			return _continue()
		0:
			return _invoke(
				"_branch_to_extra_action_point",
				[int(values[3]), false, 0]
			)
		1, 2:
			return _invoke(
				"_branch_to_loaded_encounter_result",
				[
					"simple" if int(values[2]) == 1 else "complex",
					int(values[3]),
					int(values[4]),
				]
			)
		3:
			return _invoke(
				"_finish_action_point",
				["keep-codes", false]
			)
	return _halt(
		"Unsupported classic branch mode %d" % int(values[2])
	)


func _values(extra_code_id: int) -> Array:
	return runtime.call("_extra_code_values", extra_code_id)


func _continue() -> Dictionary:
	return _invoke("_continue_result")


func _error(message: String) -> Dictionary:
	return _invoke("_error_result", [message])


func _halt(message: String) -> Dictionary:
	return _invoke("_halt_with_error", [message])


func _invoke(method_name: String, arguments := []) -> Dictionary:
	if runtime == null or not runtime.has_method(method_name):
		return {
			"status": "error",
			"message": "Classic control-flow runtime requires '%s'"
				% method_name,
		}
	var result: Variant = runtime.callv(method_name, arguments)
	if result is Dictionary:
		return result
	return {
		"status": "error",
		"message": "Classic control-flow operation '%s' returned invalid state"
			% method_name,
	}
