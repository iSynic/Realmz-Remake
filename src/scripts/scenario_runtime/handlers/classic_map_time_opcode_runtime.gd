class_name ClassicMapTimeOpcodeRuntime
extends RefCounted

const MAX_RANDOM_RECTANGLES := 20

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_teleport() -> Dictionary:
	if runtime.pending_teleport.is_empty():
		return _result(
			"_error_result",
			["No classic teleport is waiting to finish"]
		)
	var teleport: Dictionary = runtime.pending_teleport
	runtime.pending_teleport = {}
	if not bool(teleport.get("recheckDestination", false)):
		return _run()

	var state: ClassicRuntimeState = runtime.runtime_state
	var destination_triggers := state.get_effective_triggers_at(
		_bundle(),
		state.level_type,
		state.level_index,
		state.x,
		state.y
	)
	if destination_triggers.is_empty():
		if teleport.has("completionReason"):
			var completion_reason := str(teleport["completionReason"])
			runtime.call("_clear_control_flow")
			return _result("_completed_result", [completion_reason])
		return _run()
	var destination: Variant = destination_triggers[0]
	if not (destination is Dictionary):
		return _halt(
			"Classic teleport destination has an invalid action point"
		)
	var percent := int(destination.get("percent", 0))
	if percent < 1 or int(runtime.call("_roll_percent")) > percent:
		runtime.call("_clear_control_flow")
		return _result(
			"_completed_result",
			["teleport-destination-percent-miss"]
		)

	runtime.origin_action_point = destination.duplicate(true)
	runtime.active_action_point_header = destination.duplicate(true)
	runtime.active_action_point_header.erase("actions")
	runtime.suppress_action_point_destination = true
	runtime.call("_set_cursor", destination, 0)
	return _run()


func resume_back_up_party() -> Dictionary:
	runtime.call("_clear_control_flow")
	return _result("_completed_result", ["back-up-party"])


func resume_time_mutation(response: Dictionary) -> Dictionary:
	if runtime.pending_time_mutation.is_empty():
		return _result(
			"_error_result",
			["No classic time mutation is waiting for a response"]
		)
	for field_name: String in [
		"scenarioDay",
		"scenarioHour",
		"scenarioMinute",
	]:
		if not response.has(field_name):
			return _result(
				"_error_result",
				["Classic time mutation response is missing %s" % field_name]
			)
		runtime.execution_context[field_name] = int(response[field_name])
	runtime.pending_time_mutation = {}
	return _run()


func resume_exploration_status(response: Dictionary) -> Dictionary:
	if runtime.pending_exploration_status.is_empty():
		return _result(
			"_error_result",
			["No classic exploration-status action is waiting for a response"]
		)
	if not response.has("skipRemaining"):
		return _result(
			"_error_result",
			[
				"Classic exploration-status response is missing skipRemaining",
			]
		)
	runtime.pending_exploration_status = {}
	if bool(response["skipRemaining"]):
		var actions: Variant = runtime.current_trigger.get("actions", [])
		if actions is Array:
			runtime.current_action_index = actions.size()
	return _run()


func _execute_player_map(signed_map_id: int) -> Dictionary:
	var map_id: int = abs(signed_map_id)
	var map_record := _bundle().get_player_map(map_id)
	if map_record.is_empty():
		return _halt("Missing player map record %d" % map_id)
	var state: ClassicRuntimeState = runtime.runtime_state
	state.set_map_owned(map_id)
	return _result("_yield_result", [
		"give_map",
		{
			"mapId": map_id,
			"display": signed_map_id < 0,
			"mapRecord": map_record,
			"currentPosition": {
				"levelType": state.level_type,
				"levelIndex": state.level_index,
				"x": state.x,
				"y": state.y,
			},
		},
	])


func _execute_random_rectangle_mutation(
	extra_code_id: int,
	dungeon: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Random rectangle mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var level_kind := "dungeon" if dungeon else "land"
	var map_level := int(values[0])
	var rect_index := int(values[1])
	if rect_index < 0 or rect_index >= MAX_RANDOM_RECTANGLES:
		return _halt("Random rectangle index must be between 0 and 19")
	if _bundle().get_random_level(level_kind, map_level).is_empty():
		return _halt(
			"Missing %s random-level record %d" % [level_kind, map_level]
		)
	var baseline := _bundle().get_random_rectangle(
		level_kind,
		map_level,
		rect_index
	)
	if baseline.is_empty():
		baseline = {
			"rectIndex": rect_index,
			"percent": 0,
			"battleRange": [0, 0],
		}
	var state: ClassicRuntimeState = runtime.runtime_state
	var previous := state.get_random_rectangle(
		level_kind,
		map_level,
		rect_index,
		baseline
	)
	var rectangle: Dictionary = previous.duplicate(true)
	rectangle["rectIndex"] = rect_index
	rectangle["percent"] = int(values[2])
	var battle_range := [0, 0]
	var previous_range: Variant = previous.get("battleRange", [])
	if previous_range is Array:
		if previous_range.size() > 0:
			battle_range[0] = int(previous_range[0])
		if previous_range.size() > 1:
			battle_range[1] = int(previous_range[1])
	if int(values[3]) > -1:
		battle_range[0] = int(values[3])
	if int(values[4]) > -1:
		battle_range[1] = int(values[4])
	rectangle["battleRange"] = battle_range
	state.set_random_rectangle(
		level_kind,
		map_level,
		rect_index,
		rectangle
	)
	return _result("_yield_result", [
		"set_random_encounter_rect",
		{
			"extraCodeId": extra_code_id,
			"levelType": level_kind,
			"levelIndex": map_level,
			"rectIndex": rect_index,
			"previousRectangle": previous,
			"rectangle": rectangle,
		},
	])


func _execute_random_rectangle_bounds(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	var bounds_values := _values(extra_code_id + 1)
	if values.size() < 5 or bounds_values.size() < 4:
		return _halt(
			"Random rectangle bounds action requires consecutive Extra Code rows %d and %d"
			% [extra_code_id, extra_code_id + 1]
		)
	var level_kind := "dungeon" if int(values[2]) != 0 else "land"
	var map_level := int(values[0])
	var rect_index := int(values[1])
	var bounds_mode := int(values[4])
	if rect_index < 0 or rect_index >= MAX_RANDOM_RECTANGLES:
		return _halt("Random rectangle index must be between 0 and 19")
	if bounds_mode < -1 or bounds_mode > 2:
		return _halt(
			"Random rectangle bounds action has invalid mode %d"
			% bounds_mode
		)
	if _bundle().get_random_level(level_kind, map_level).is_empty():
		return _halt(
			"Missing %s random-level record %d" % [level_kind, map_level]
		)
	var baseline := _bundle().get_random_rectangle(
		level_kind,
		map_level,
		rect_index
	)
	if baseline.is_empty():
		baseline = {
			"rectIndex": rect_index,
			"percent": 0,
			"battleRange": [0, 0],
			"left": 0,
			"right": 0,
			"top": 0,
			"bottom": 0,
		}
	var state: ClassicRuntimeState = runtime.runtime_state
	var previous := state.get_random_rectangle(
		level_kind,
		map_level,
		rect_index,
		baseline
	)
	var rectangle: Dictionary = previous.duplicate(true)
	rectangle["rectIndex"] = rect_index
	rectangle["percent"] = \
		int(rectangle.get("percent", 0)) + int(values[3])
	match bounds_mode:
		0:
			rectangle["left"] = int(bounds_values[0])
			rectangle["right"] = int(bounds_values[1])
			rectangle["top"] = int(bounds_values[2])
			rectangle["bottom"] = int(bounds_values[3])
		1:
			rectangle["left"] = (
				int(rectangle.get("left", 0)) + int(bounds_values[0])
			)
			rectangle["right"] = (
				int(rectangle.get("right", 0)) + int(bounds_values[0])
			)
			rectangle["top"] = (
				int(rectangle.get("top", 0)) + int(bounds_values[1])
			)
			rectangle["bottom"] = (
				int(rectangle.get("bottom", 0)) + int(bounds_values[1])
			)
		2:
			rectangle["left"] = (
				int(rectangle.get("left", 0)) + int(bounds_values[0])
			)
			rectangle["right"] = (
				int(rectangle.get("right", 0)) + int(bounds_values[1])
			)
			rectangle["top"] = (
				int(rectangle.get("top", 0)) + int(bounds_values[2])
			)
			rectangle["bottom"] = (
				int(rectangle.get("bottom", 0)) + int(bounds_values[3])
			)
	state.set_random_rectangle(
		level_kind,
		map_level,
		rect_index,
		rectangle
	)
	return _result("_yield_result", [
		"set_random_encounter_rect",
		{
			"extraCodeId": extra_code_id,
			"boundsExtraCodeId": extra_code_id + 1,
			"levelType": level_kind,
			"levelIndex": map_level,
			"rectIndex": rect_index,
			"previousRectangle": previous,
			"rectangle": rectangle,
			"boundsMode": bounds_mode,
		},
	])


func _execute_timed_encounter_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Timed encounter mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var encounter_id := int(values[0])
	var encounter := _bundle().get_timed_encounter(encounter_id)
	if encounter.is_empty():
		return _halt(
			"Timed encounter mutation references missing encounter %d"
			% encounter_id
		)
	encounter = runtime.runtime_state.get_effective_timed_encounter(encounter)
	if int(values[1]) > -1:
		encounter["percent"] = int(values[1])
	if int(values[2]) > -1:
		encounter["increment"] = int(values[2])
	if int(values[3]) != 0:
		var scenario_day: Variant = runtime.execution_context.get(
			"scenarioDay"
		)
		if not (scenario_day is int or scenario_day is float) \
				or not is_equal_approx(
					float(scenario_day),
					float(int(scenario_day))
				) \
				or int(scenario_day) < 0:
			return _halt(
				"Timed encounter reset requires a non-negative scenarioDay execution context"
			)
		encounter["day"] = int(scenario_day)
	if int(values[4]) > -1:
		encounter["day"] = \
			int(encounter.get("day", 0)) + int(values[4])
	runtime.runtime_state.set_timed_encounter_override(
		encounter_id,
		encounter
	)
	return _result("_continue_result")


func _execute_tile_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Tile mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var level_kind := "dungeon" if int(values[4]) != 0 else "land"
	var tile_x := int(values[2]) if level_kind == "dungeon" \
		else int(values[1])
	var tile_y := int(values[1]) if level_kind == "dungeon" \
		else int(values[2])
	var map_level := int(values[0])
	var tile_value := int(values[3])
	runtime.runtime_state.set_tile(
		level_kind,
		map_level,
		tile_x,
		tile_y,
		tile_value
	)
	return _result("_yield_result", [
		"set_map_tile",
		{
			"extraCodeId": extra_code_id,
			"levelType": level_kind,
			"levelIndex": map_level,
			"x": tile_x,
			"y": tile_y,
			"tileValue": tile_value,
		},
	])


func _execute_trigger_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Trigger mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var range_start_with_sign := int(values[3])
	var level_kind: String = runtime.runtime_state.level_type
	if range_start_with_sign < 0:
		level_kind = "dungeon"
	elif range_start_with_sign > 0:
		level_kind = "land"
	var map_level := int(values[0])
	var percent := int(values[2])
	var trigger_ids: Array = []
	var single_trigger_id := int(values[1])
	if single_trigger_id != 0:
		trigger_ids.append(single_trigger_id)
	if range_start_with_sign != 0:
		var range_start: int = abs(range_start_with_sign)
		var range_end: int = abs(int(values[4]))
		for trigger_id: int in range(range_start, range_end + 1):
			if not trigger_ids.has(trigger_id):
				trigger_ids.append(trigger_id)
	for trigger_id: int in trigger_ids:
		runtime.runtime_state.set_trigger_percent(
			level_kind,
			map_level,
			trigger_id,
			percent
		)
	return _result("_yield_result", [
		"set_trigger_percent",
		{
			"extraCodeId": extra_code_id,
			"levelType": level_kind,
			"levelIndex": map_level,
			"triggerIds": trigger_ids,
			"percent": percent,
		},
	])


func _execute_teleport(
	extra_code_id: int,
	recheck_destination: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Teleport action references missing Extra Code row %d"
			% extra_code_id
		)
	var state: ClassicRuntimeState = runtime.runtime_state
	state.set_position(int(values[0]), int(values[1]), int(values[2]))
	runtime.active_action_point_header["landid"] = state.level_index
	runtime.active_action_point_header["targetX"] = state.x
	runtime.active_action_point_header["targetY"] = state.y
	runtime.pending_teleport = {
		"recheckDestination": recheck_destination,
	}
	return _result("_yield_result", [
		"teleport",
		{
			"extraCodeId": extra_code_id,
			"levelType": state.level_type,
			"levelIndex": state.level_index,
			"x": state.x,
			"y": state.y,
			"soundId": int(values[3]),
			"messageId": int(values[4]),
			"message": _bundle().get_message(int(values[4])),
			"recheckDestination": recheck_destination,
		},
	])


func _execute_dungeon_move(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Dungeon Move action references missing Extra Code row %d"
			% extra_code_id
		)
	var destination_type := "dungeon" if int(values[0]) == 0 else "land"
	var state: ClassicRuntimeState = runtime.runtime_state
	state.set_location(
		destination_type,
		int(values[1]),
		int(values[2]),
		int(values[3])
	)
	var payload := {
		"extraCodeId": extra_code_id,
		"levelType": state.level_type,
		"levelIndex": state.level_index,
		"x": state.x,
		"y": state.y,
		"recheckDestination": false,
		"dungeonMove": true,
	}
	if destination_type == "dungeon":
		state.set_dungeon_view(int(values[4]), int(values[4]) >= 0)
		payload["heading"] = state.heading
		payload["multiView"] = state.multi_view
		payload["viewType"] = state.view_type

	runtime.set_pending_continuation(
		"dungeon-move",
		{"dungeonMove": true}
	)
	var result := _result("_yield_result", ["teleport", payload])
	runtime.call("_clear_control_flow")
	return result


func _execute_look_direction(requested_heading: int) -> Dictionary:
	var randomized := requested_heading < 1 or requested_heading > 4
	var new_heading := randi_range(1, 4) \
		if randomized else requested_heading
	runtime.runtime_state.set_heading(new_heading)
	return _result("_yield_result", [
		"set_view_direction",
		{
			"heading": runtime.runtime_state.heading,
			"requestedHeading": requested_heading,
			"randomized": randomized,
		},
	])


func _execute_compass(enabled: bool) -> Dictionary:
	var previous: bool = runtime.runtime_state.compass_enabled
	runtime.runtime_state.set_compass_enabled(enabled)
	return _result("_yield_result", [
		"set_view_mode",
		{
			"compassEnabled": enabled,
			"multiView": runtime.runtime_state.multi_view,
			"viewType": runtime.runtime_state.view_type,
			"warningId": (
				(98 if enabled else 99) if previous != enabled else 0
			),
			"redraw": "walls",
		},
	])


func _execute_map_view_mode(allow_map: bool) -> Dictionary:
	var state: ClassicRuntimeState = runtime.runtime_state
	var previous_multi_view := state.multi_view
	var previous_view_type := state.view_type
	if allow_map:
		state.allow_full_map()
	else:
		state.require_3d_view()
	return _result("_yield_result", [
		"set_view_mode",
		{
			"compassEnabled": state.compass_enabled,
			"multiView": state.multi_view,
			"viewType": state.view_type,
			"previousViewType": previous_view_type,
			"warningId": (
				96 if allow_map and not previous_multi_view
				else 97 if not allow_map and previous_multi_view
				else 0
			),
			"redraw": "window" \
				if not allow_map or state.view_type == 1 else "none",
		},
	])


func _execute_darkland(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Set Darkland action references missing Extra Code row %d"
			% extra_code_id
		)
	var state: ClassicRuntimeState = runtime.runtime_state
	var random_level := _bundle().get_random_level(
		state.level_type,
		state.level_index
	)
	var fallback := 1 if bool(random_level.get("isDark", false)) else 0
	var previous := state.get_darkland(
		state.level_type,
		state.level_index,
		fallback
	)
	var darkness := int(values[0]) - 1
	if int(values[1]) != 0 and previous == darkness:
		runtime.call("_clear_control_flow")
		return _result("_completed_result", ["darkland-unchanged"])
	state.set_darkland(
		state.level_type,
		state.level_index,
		darkness
	)
	return _result("_yield_result", [
		"set_map_darkness",
		{
			"extraCodeId": extra_code_id,
			"levelType": state.level_type,
			"levelIndex": state.level_index,
			"previousDarkness": previous,
			"darkness": darkness,
			"dark": darkness != 0,
		},
	])


func _execute_landlook(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Change Land Look action references missing Extra Code row %d"
			% extra_code_id
		)
	var map_level := int(values[2])
	var random_level := _bundle().get_random_level("land", map_level)
	if random_level.is_empty():
		return _halt(
			"Missing land random-level record %d" % map_level
		)
	var state: ClassicRuntimeState = runtime.runtime_state
	var previous_landlook := state.get_landlook(
		"land",
		map_level,
		int(random_level.get("landlook", 0))
	)
	var previous_darkness := state.get_darkland(
		"land",
		map_level,
		1 if bool(random_level.get("isDark", false)) else 0
	)
	var landlook := int(values[0])
	var darkness := int(values[1])
	state.set_landlook("land", map_level, landlook)
	state.set_darkland("land", map_level, darkness)
	return _result("_yield_result", [
		"set_land_look",
		{
			"extraCodeId": extra_code_id,
			"levelType": "land",
			"levelIndex": map_level,
			"previousLandlook": previous_landlook,
			"landlook": landlook,
			"previousDarkness": previous_darkness,
			"darkness": darkness,
			"dark": darkness != 0,
			"redraw": "center" if state.level_type == "land" else "none",
		},
	])


func _execute_position_shift(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Position shift references missing Extra Code row %d"
			% extra_code_id
		)
	var delta_x := int(values[1])
	var delta_y := int(values[2])
	var randomized := int(values[3]) != 0
	if randomized:
		if delta_x <= 0 or delta_y <= 0:
			return _halt(
				"Random position shift %d requires positive X and Y ranges"
				% extra_code_id
			)
		delta_x = randi_range(1, delta_x) \
			* (-1 if randi_range(0, 1) == 0 else 1)
		delta_y = randi_range(1, delta_y) \
			* (-1 if randi_range(0, 1) == 0 else 1)

	var state: ClassicRuntimeState = runtime.runtime_state
	var map_id := "%s:%d" % [state.level_type, state.level_index]
	var map_record := _bundle().get_map(map_id)
	var width := int(map_record.get("width", 0))
	var height := int(map_record.get("height", 0))
	var target_x := state.x + delta_x
	var target_y := state.y + delta_y
	if map_record.is_empty() \
			or width <= 0 \
			or height <= 0 \
			or target_x < 0 \
			or target_y < 0 \
			or target_x >= width \
			or target_y >= height:
		return _halt(
			"Position shift %d leaves Classic map %s at %d,%d" % [
				extra_code_id,
				map_id,
				target_x,
				target_y,
			]
		)
	var previous_position := Vector2i(state.x, state.y)
	state.set_position(state.level_index, target_x, target_y)
	return _result("_yield_result", [
		"shift_party_position",
		{
			"extraCodeId": extra_code_id,
			"levelType": state.level_type,
			"levelIndex": state.level_index,
			"x": target_x,
			"y": target_y,
			"delta": Vector2i(delta_x, delta_y),
			"fromPosition": previous_position,
			"randomized": randomized,
		},
	])


func _execute_saved_position(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Saved-position action references missing Extra Code row %d"
			% extra_code_id
		)
	var state: ClassicRuntimeState = runtime.runtime_state
	match int(values[0]):
		1:
			state.save_party_position()
			return _result("_continue_result")
		2:
			var restored: Dictionary = state.restore_party_position()
			if restored.is_empty():
				return _result("_continue_result")
			runtime.active_action_point_header["landid"] = state.level_index
			runtime.active_action_point_header["targetX"] = state.x
			runtime.active_action_point_header["targetY"] = state.y
			runtime.suppress_action_point_destination = true
			runtime.pending_teleport = {"recheckDestination": false}
			return _result("_yield_result", [
				"teleport",
				{
					"extraCodeId": extra_code_id,
					"levelType": state.level_type,
					"levelIndex": state.level_index,
					"x": state.x,
					"y": state.y,
					"soundId": 0,
					"messageId": 0,
					"message": {},
					"recheckDestination": false,
					"savedPositionRestore": true,
				},
			])
		_:
			return _halt(
				"Saved-position action has invalid mode %d" % int(values[0])
			)


func _execute_time_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Game-time mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var mode := int(values[0])
	if mode not in [1, 2]:
		return _halt(
			"Game-time mutation %d has invalid mode %d"
			% [extra_code_id, mode]
		)
	if mode == 1 \
			and (
				int(values[1]) < -1
				or int(values[2]) < -1
				or int(values[2]) > 23
				or int(values[3]) < -1
				or int(values[3]) > 59
			):
		return _halt(
			"Set game-time row %d has an invalid day, hour, or minute"
			% extra_code_id
		)
	runtime.pending_time_mutation = {"extraCodeId": extra_code_id}
	return _result("_yield_result", [
		"alter_game_time",
		{
			"extraCodeId": extra_code_id,
			"mode": "set" if mode == 1 else "offset",
			"day": int(values[1]),
			"hour": int(values[2]),
			"minute": int(values[3]),
		},
	])


func _execute_exploration_status(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Exploration-status action references missing Extra Code row %d"
			% extra_code_id
		)
	for value_index: int in 3:
		if int(values[value_index]) not in [0, 1, 2]:
			return _halt(
				"Exploration-status row %d has invalid field %d"
				% [extra_code_id, value_index]
			)
	runtime.pending_exploration_status = {
		"extraCodeId": extra_code_id,
	}
	return _result("_yield_result", [
		"update_exploration_status",
		{
			"extraCodeId": extra_code_id,
			"boatTest": int(values[0]),
			"campTest": int(values[1]),
			"boatChange": int(values[2]),
		},
	])


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
			"message": "Classic map/time runtime requires '%s'" % method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic map/time operation '%s' returned invalid state" \
			% method_name,
	}
