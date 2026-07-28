class_name ScenarioGodotMapServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const MAP_GAINED_MESSAGE := \
	"You gain a map, to view the map use Maps/Notes in the Menu."


func _set_map_tile(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.set_tile(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _set_trigger_percent(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.set_trigger_percent(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _shift_party_position(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.transition(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _set_view_direction(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.redraw_view(
		payload,
		_autoload("GameGlobal")
	)


func _set_map_darkness(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.set_darkness(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _set_random_encounter_rect(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.set_random_rectangle(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _set_land_look(payload: Dictionary) -> Dictionary:
	return service_owner.classic_map_bridge.set_land_look(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


func _back_up_party(payload: Dictionary) -> Dictionary:
	return service_owner.call(
		"retreat_classic_party",
		_autoload("GameGlobal"),
		payload.get("entryMovement")
	)


func _set_view_mode(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.classic_map_bridge.redraw_view(
		payload,
		_autoload("GameGlobal")
	)
	if str(result.get("status", "")) == "error":
		return result
	var warning_result: Dictionary = await service_owner.call(
		"_show_classic_warning",
		int(payload.get("warningId", 0))
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
	return service_owner.classic_map_bridge.transition(
		payload,
		_autoload("GameGlobal"),
		_campaign_resources()
	)


static func teleport_message_present(payload: Dictionary) -> bool:
	if int(payload.get("messageId", 0)) == 0:
		return false
	var message: Variant = payload.get("message", {})
	return (
		message is Dictionary
			and not str(message.get("text", "")).strip_edges().is_empty()
	)


func _alter_game_time(payload: Dictionary) -> Dictionary:
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
	var map_id := int(payload.get("mapId", -1))
	if map_id < 0:
		return _error("Classic map command is missing its map ID")
	var map_record: Dictionary = payload.get("mapRecord", {})
	var game_global: Object = _autoload("GameGlobal")
	var native_map: Array = []
	if game_global != null and game_global.minimaps is Array \
			and map_id < game_global.minimaps.size():
		var map_value: Variant = game_global.minimaps[map_id]
		if map_value is Array and map_value.size() >= 7:
			native_map = map_value
			native_map[6] = 1

	service_owner.call("_play_sound", {"soundId": 30005})
	if bool(payload.get("display", false)):
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
				payload.get("currentPosition", {})
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
	if bool(payload.get("display", false)) and _can_display_native_map(native_map):
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
	if bool(payload.get("display", false)):
		var map_note := str(map_record.get("note", "")).strip_edges()
		if not map_note.is_empty():
			message = map_note
	await text_rect.set_text(message, true)
	return {}


func _can_display_native_map(native_map: Array) -> bool:
	return native_map.size() >= 7 and native_map[2] is String
