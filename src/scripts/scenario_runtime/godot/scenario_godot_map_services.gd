class_name ScenarioGodotMapServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const MAP_GAINED_MESSAGE := \
	"You gain a map, to view the map use Maps/Notes in the Menu."


func _query_location(_payload: Dictionary = {}) -> Dictionary:
	var runtime_state := _classic_runtime_state()
	if runtime_state == null:
		return _error("Classic scenario location is unavailable")
	return {
		"levelType": str(runtime_state.get("level_type")),
		"levelIndex": int(runtime_state.get("level_index")),
		"x": int(runtime_state.get("x")),
		"y": int(runtime_state.get("y")),
	}


func _query_time(_payload: Dictionary = {}) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game clock is unavailable")
	var total_seconds := maxi(0, int(game_global.get("time")))
	var day_seconds := posmod(total_seconds, 86400)
	return {
		"day": floori(float(total_seconds) / 86400.0) + 1,
		"hour": floori(float(day_seconds) / 3600.0),
		"minute": floori(float(day_seconds % 3600) / 60.0),
		"second": day_seconds % 60,
		"totalSeconds": total_seconds,
	}


func _query_exploration(_payload: Dictionary = {}) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	var runtime_state := _classic_runtime_state()
	if game_global == null or runtime_state == null:
		return _error("Scenario exploration state is unavailable")
	return {
		"camping": bool(game_global.get("camping")),
		"campingAllowed": not bool(
			game_global.get("classic_camping_disabled")
		),
		"sailing": bool(game_global.get("is_sailing_boat")),
		"heading": int(runtime_state.get("heading")),
		"viewMode": (
			"map"
			if int(runtime_state.get("view_type")) \
				== runtime_state.VIEW_MAP
			else "3d"
		),
		"compassEnabled": bool(runtime_state.get("compass_enabled")),
		"randomEncountersEnabled": bool(
			runtime_state.get("random_encounters_enabled")
		),
	}


func _query_map_definition(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario map definitions are unavailable")
	var level_type := str(payload.get("levelType", "")).to_lower()
	var level_index := int(payload.get("levelIndex", -1))
	if level_type not in ["land", "dungeon"] or level_index < 0:
		return _error("Scenario map definition reference is invalid")
	var record: Dictionary = service_owner.classic_bundle.get_map(
		"%s:%d" % [level_type, level_index]
	)
	if record.is_empty():
		return _error(
			"Scenario %s map %d is unavailable" % [level_type, level_index]
		)
	return {
		"id": str(record.get("id", "%s:%d" % [level_type, level_index])),
		"name": str(record.get("name", "")),
		"levelType": str(record.get("levelType", level_type)),
		"levelIndex": int(record.get("index", level_index)),
		"width": int(record.get("width", 0)),
		"height": int(record.get("height", 0)),
	}


func _set_map_tile(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.set-tile":
		routed_payload["tileValue"] = int(routed_payload.get("tile", -1))
	var result: Dictionary = service_owner.classic_map_bridge.set_tile(
		routed_payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and str(routed_payload.get("_scenarioApiOperation", "")) \
				== "core.map.set-tile":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_tile(
				str(routed_payload.get("levelType", "")),
				int(routed_payload.get("levelIndex", -1)),
				int(routed_payload.get("x", -1)),
				int(routed_payload.get("y", -1)),
				int(routed_payload.get("tileValue", -1))
			)
	return result


func _set_trigger_percent(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.classic_map_bridge.set_trigger_percent(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and str(payload.get("_scenarioApiOperation", "")) \
				== "core.map.trigger-chance":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			for trigger_id_value: Variant in payload.get("triggerIds", []):
				runtime_state.set_trigger_percent(
					str(payload.get("levelType", "")),
					int(payload.get("levelIndex", -1)),
					int(trigger_id_value),
					int(payload.get("percent", 0))
				)
	return result


func _shift_party_position(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	var runtime_state := _classic_runtime_state()
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.shift-party":
		if runtime_state == null:
			return _error("Scenario location state is unavailable")
		routed_payload["levelType"] = str(runtime_state.level_type)
		routed_payload["levelIndex"] = int(runtime_state.level_index)
		routed_payload["x"] = int(runtime_state.x) + int(
			routed_payload.get("dx", 0)
		)
		routed_payload["y"] = int(runtime_state.y) + int(
			routed_payload.get("dy", 0)
		)
	var result: Dictionary = service_owner.classic_map_bridge.transition(
		routed_payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and runtime_state != null \
			and str(routed_payload.get("_scenarioApiOperation", "")) \
				== "core.map.shift-party":
		runtime_state.set_position(
			int(routed_payload.get("levelIndex", 0)),
			int(routed_payload.get("x", 0)),
			int(routed_payload.get("y", 0))
		)
		result["location"] = _query_location()
	return result


func _set_view_direction(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.view-direction":
		var runtime_state := _classic_runtime_state()
		var heading := int(routed_payload.get("heading", 0))
		if runtime_state == null:
			return _error("Scenario view state is unavailable")
		if heading < 1 or heading > 4:
			return _error("Scenario view direction must be north, east, south, or west")
		runtime_state.set_heading(heading)
		routed_payload["multiView"] = bool(runtime_state.multi_view)
		routed_payload["viewType"] = int(runtime_state.view_type)
		routed_payload["compassEnabled"] = bool(runtime_state.compass_enabled)
	return service_owner.classic_map_bridge.redraw_view(
		routed_payload,
		_autoload("GameGlobal")
	)


func _set_map_darkness(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.classic_map_bridge.set_darkness(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and str(payload.get("_scenarioApiOperation", "")) \
				== "core.map.darkness":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_darkland(
				str(payload.get("levelType", "")),
				int(payload.get("levelIndex", -1)),
				int(payload.get("darkness", 0))
			)
	return result


func _set_random_encounter_rect(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.random-rectangle":
		var runtime_state := _classic_runtime_state()
		if runtime_state == null or service_owner.classic_bundle == null:
			return _error("Scenario random-encounter state is unavailable")
		var level_type := str(routed_payload.get("levelType", "land"))
		var level_index := int(routed_payload.get("levelIndex", 0))
		var rect_index := int(routed_payload.get("rectIndex", 0))
		var rectangle: Dictionary = service_owner.classic_bundle.get_random_rectangle(
			level_type,
			level_index,
			rect_index
		)
		if rectangle.is_empty():
			rectangle = {
				"rectIndex": rect_index,
				"percent": 0,
				"battleRange": [0, 0],
			}
		rectangle = rectangle.duplicate(true)
		rectangle["percent"] = clampi(
			int(routed_payload.get("percent", rectangle.get("percent", 0))),
			0,
			100
		)
		var previous_range: Variant = rectangle.get("battleRange", [0, 0])
		if not (previous_range is Array) or previous_range.size() < 2:
			previous_range = [0, 0]
		rectangle["battleRange"] = [
			int(routed_payload.get(
				"firstBattleId",
				previous_range[0]
			)),
			int(routed_payload.get(
				"lastBattleId",
				previous_range[1]
			)),
		]
		routed_payload["rectangle"] = rectangle
		runtime_state.set_random_rectangle(
			level_type,
			level_index,
			rect_index,
			rectangle
		)
	return service_owner.classic_map_bridge.set_random_rectangle(
		routed_payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _set_land_look(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	var result: Dictionary = service_owner.classic_map_bridge.set_land_look(
		routed_payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and str(routed_payload.get("_scenarioApiOperation", "")) \
				== "core.map.land-look":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_landlook(
				"land",
				int(routed_payload.get("levelIndex", 0)),
				int(routed_payload.get("landlook", 0))
			)
			runtime_state.set_darkland(
				"land",
				int(routed_payload.get("levelIndex", 0)),
				int(routed_payload.get("darkness", 0))
			)
	return result


func _back_up_party(payload: Dictionary) -> Dictionary:
	return service_owner.call(
		"retreat_classic_party",
		_autoload("GameGlobal"),
		payload.get("entryMovement")
	)


func _set_view_mode(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.view-mode":
		var runtime_state := _classic_runtime_state()
		if runtime_state == null:
			return _error("Scenario view state is unavailable")
		if routed_payload.has("compassEnabled"):
			runtime_state.set_compass_enabled(
				bool(routed_payload.get("compassEnabled", true))
			)
		if routed_payload.has("fullMap"):
			if bool(routed_payload.get("fullMap", false)):
				runtime_state.allow_full_map()
			else:
				runtime_state.require_3d_view()
		routed_payload["multiView"] = bool(runtime_state.multi_view)
		routed_payload["viewType"] = int(runtime_state.view_type)
		routed_payload["compassEnabled"] = bool(runtime_state.compass_enabled)
		routed_payload["warningId"] = 0
	var result: Dictionary = service_owner.classic_map_bridge.redraw_view(
		routed_payload,
		_autoload("GameGlobal")
	)
	if str(result.get("status", "")) == "error":
		return result
	var warning_result: Dictionary = await service_owner.call(
		"_show_classic_warning",
		int(routed_payload.get("warningId", 0))
	)
	result["warningPresentation"] = warning_result
	return result


func _redraw_map(_payload: Dictionary = {}) -> Dictionary:
	var changed := false
	var picture_rect: Object = _picture_rect()
	if picture_rect != null:
		picture_rect.hide()
		changed = true
	var game_global: Object = _autoload("GameGlobal")
	var current_map: Variant = game_global.get("map") if game_global != null else null
	if current_map is Object and current_map.has_method("queue_redraw"):
		current_map.queue_redraw()
		changed = true
	if not changed:
		return {"status": "skipped", "message": "Realmz map display is unavailable"}
	return {}


func _teleport_classic_party(payload: Dictionary) -> Dictionary:
	service_owner.call("_play_sound", payload)
	if teleport_message_present(payload):
		var message_result: Dictionary = await service_owner.call(
			"_show_text",
			payload
		)
		if str(message_result.get("status", "")) == "error":
			return message_result
	var previous_location: Dictionary = _query_location()
	var destination: Dictionary = {
		"levelType": str(payload.get("levelType", "")),
		"levelIndex": int(payload.get("levelIndex", -1)),
		"x": int(payload.get("x", -1)),
		"y": int(payload.get("y", -1)),
	}
	var changes_map: bool = (
		str(previous_location.get("levelType", "")) != destination["levelType"]
		or int(previous_location.get("levelIndex", -1)) != destination["levelIndex"]
	)
	if changes_map:
		var leave_result := await _emit_lifecycle_event("map-leave", {
			"event": "map-leave",
			"location": previous_location.duplicate(true),
			"destination": destination.duplicate(true),
		})
		if str(leave_result.get("status", "")) == "error":
			return leave_result
	var result: Dictionary = service_owner.classic_map_bridge.transition(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)
	if str(result.get("status", "")) != "error" \
			and str(payload.get("_scenarioApiOperation", "")) \
				== "core.map.teleport":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_location(
				str(payload.get("levelType", "")),
				int(payload.get("levelIndex", -1)),
				int(payload.get("x", -1)),
				int(payload.get("y", -1))
			)
	if str(result.get("status", "")) != "error":
		if changes_map:
			var enter_result := await _emit_lifecycle_event("map-enter", {
				"event": "map-enter",
				"location": destination.duplicate(true),
				"previousLocation": previous_location.duplicate(true),
			})
			if str(enter_result.get("status", "")) == "error":
				return enter_result
		var moved_result := await _emit_lifecycle_event("party-moved", {
			"event": "party-moved",
			"from": previous_location.duplicate(true),
			"to": destination.duplicate(true),
			"teleport": true,
		})
		if str(moved_result.get("status", "")) == "error":
			return moved_result
	return result


static func teleport_message_present(payload: Dictionary) -> bool:
	if int(payload.get("messageId", 0)) == 0:
		return false
	var message: Variant = payload.get("message", {})
	return (
		message is Dictionary
			and not str(message.get("text", "")).strip_edges().is_empty()
	)


func _alter_game_time(payload: Dictionary) -> Dictionary:
	if payload.has("seconds"):
		var game_global: Object = _autoload("GameGlobal")
		if game_global == null or not game_global.has_method("pass_time"):
			return _error("Realmz game clock is unavailable")
		var seconds := int(payload.get("seconds", 0))
		if seconds < 0:
			return _error("Scenario behavior cannot move the clock backwards")
		game_global.call("pass_time", seconds)
		var advanced := _query_time()
		advanced["advancedSeconds"] = seconds
		return advanced
	var result: Dictionary = service_owner.call(
		"alter_classic_game_time",
		_autoload("GameGlobal"),
		payload
	)
	if str(result.get("status", "")) == "error":
		return result
	var ui: Object = _autoload("UI")
	var hud: Variant = ui.get("ow_hud") if ui != null else null
	if hud is Object and hud.has_method("updateTimeDisplay"):
		hud.call("updateTimeDisplay")
	return result


func _set_camping_permission(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call(
		"set_classic_camping_permission",
		_autoload("GameGlobal"),
		bool(payload.get("disabled", false))
	)
	if str(result.get("status", "")) == "error":
		return result
	var ui: Object = _autoload("UI")
	var hud: Variant = ui.get("ow_hud") if ui != null else null
	if hud is Object and hud.has_method("update_classic_camping_permission"):
		hud.call("update_classic_camping_permission")
	if bool(result.get("changed", false)):
		service_owner.call("_play_sound", payload)
		var text_rect := _text_rect()
		if text_rect != null:
			text_rect.set_text(
				"You may not camp at the present time."
				if bool(result.get("disabled", false))
				else "You may now camp again.",
				false
			)
	return result


func _update_exploration_status(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	var result: Dictionary = service_owner.call(
		"update_classic_exploration_status",
		game_global,
		payload
	)
	if str(result.get("status", "")) == "error":
		return result
	if bool(result.get("boatChanged", false)):
		service_owner.call("_refresh_exploration_icon", game_global)
	return result


func _give_player_map(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	var map_id := int(routed_payload.get("mapId", -1))
	if map_id < 0:
		return _error("Classic map command is missing its map ID")
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.map.give-player-map":
		if service_owner.classic_bundle == null:
			return _error("Scenario player-map catalog is unavailable")
		var authored_map: Dictionary = (
			service_owner.classic_bundle.get_player_map(map_id)
		)
		if authored_map.is_empty():
			return _error("Scenario player map %d is unavailable" % map_id)
		routed_payload["mapRecord"] = authored_map
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_map_owned(map_id)
			routed_payload["currentPosition"] = {
				"levelType": runtime_state.level_type,
				"levelIndex": runtime_state.level_index,
				"x": runtime_state.x,
				"y": runtime_state.y,
			}
	var map_record: Dictionary = routed_payload.get("mapRecord", {})
	var game_global: Object = _autoload("GameGlobal")
	var native_map: Array = []
	if game_global != null and game_global.minimaps is Array \
			and map_id < game_global.minimaps.size():
		var map_value: Variant = game_global.minimaps[map_id]
		if map_value is Array and map_value.size() >= 7:
			native_map = map_value
			native_map[6] = 1

	service_owner.call("_play_sound", {"soundId": 30005})
	if bool(routed_payload.get("display", false)):
		var runtime_path := str(service_owner.call(
			"runtime_media_path",
			map_record,
			"image/"
		))
		var can_render_from_level := int(map_record.get("show", 0)) >= 0 \
			and int(map_record.get("pictId", 0)) == 0
		if not runtime_path.is_empty() or can_render_from_level:
			var ui: Object = _autoload("UI")
			if ui == null or ui.ow_hud == null \
					or ui.ow_hud.classicPlayerMapRect == null:
				return _error("Realmz Classic player-map UI is unavailable")
			var player_map_rect: Object = ui.ow_hud.classicPlayerMapRect
			var native_map_name := "%s_%d" % [
				"mapd" if bool(map_record.get("isDungeon", false)) else "map",
				int(map_record.get("level", 0)),
			]
			if not player_map_rect.display_map(
				map_record,
				runtime_path,
				native_map_name,
				routed_payload.get("currentPosition", {})
			):
				return _error("Classic player-map media could not be displayed")
			var state_machine: Object = _autoload("StateMachine")
			if state_machine != null:
				state_machine.enter_ex_menu_state({"menu_name": "ClassicPlayerMapMenu"})
			await player_map_rect.closed
			if state_machine != null and state_machine._state_name == "ExMenus":
				state_machine.exit_ex_menu_state({})
			return {
				"runtimeMediaPath": str(map_record.get("runtimeMedia", {}).get("path", "")),
				"generatedFromLevel": runtime_path.is_empty(),
			}
	if bool(routed_payload.get("display", false)) \
			and _can_display_native_map(native_map):
		var ui: Object = _autoload("UI")
		if ui == null or ui.ow_hud == null or ui.ow_hud.minimapRect == null:
			return _error("Realmz minimap UI is unavailable")
		var minimap_rect: Object = ui.ow_hud.minimapRect
		minimap_rect.cur_map = native_map
		minimap_rect.show()
		minimap_rect.on_display()
		var state_machine: Object = _autoload("StateMachine")
		if state_machine != null:
			state_machine.enter_ex_menu_state({"menu_name": "MiniMapsMenu"})
		await minimap_rect.visibility_changed
		return {}

	var text_rect: Object = _text_rect()
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable for the Classic map notice")
	var message := MAP_GAINED_MESSAGE
	if bool(routed_payload.get("display", false)):
		var map_note := str(map_record.get("note", "")).strip_edges()
		if not map_note.is_empty():
			message = map_note
	await text_rect.set_text(message, true)
	return {}


func _can_display_native_map(native_map: Array) -> bool:
	return native_map.size() >= 7 and native_map[2] is String
