class_name ScenarioGodotPresentationServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const RogueResolverScript = preload(
	"res://scripts/classic_runtime/classic_rogue_encounter_resolver.gd"
)
const SoundResolutionScript = preload(
	"res://scripts/classic_runtime/classic_sound_resolution.gd"
)
const STOP_CHOICE_TOKEN := "STOP"


func _show_text(payload: Dictionary) -> Dictionary:
	var override: Variant = service_owner.call(
		"scenario_presentation_override",
		"show_text",
		payload
	)
	if override is Dictionary:
		return override
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	var message: Variant = payload.get("message", {})
	var text := str(message.get("text", "")) \
		if message is Dictionary else ""
	await text_rect.set_text(text, true)
	return {}


func _show_yes_no_choice(payload: Dictionary) -> Dictionary:
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	var answer: Variant = await service_owner.call(
		"_show_choices",
		text_rect,
		[
			service_owner.call(
				"_choice_label_text",
				payload.get("yesLabel", {}),
				"Yes"
			),
			service_owner.call(
				"_choice_label_text",
				payload.get("noLabel", {}),
				"No"
			),
		],
		["YES", "NO"]
	)
	return {"accepted": str(answer) == "YES"}


func _wait_for_click(payload: Dictionary) -> Dictionary:
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	_play_sound(payload)
	await text_rect.set_text(str(payload.get("prompt", "Click Mouse")), true)
	return {}


func _show_classic_picture(payload: Dictionary) -> Dictionary:
	var picture: Variant = payload.get("picture", {})
	var catalog_lookup_performed := false
	if (not (picture is Dictionary) or picture.is_empty()) \
			and service_owner.classic_bundle != null \
			and service_owner.classic_bundle.has_method("get_picture"):
		catalog_lookup_performed = true
		picture = service_owner.classic_bundle.get_picture(
			int(payload.get("pictureId", 0))
		)
	if catalog_lookup_performed \
			and picture is Dictionary \
			and picture.is_empty():
		return {
			"status": "unresolved-noop",
			"remakeBehavior": "unchanged-picture",
			"classicBehaviorIfAbsent": "unchanged-picture",
			"resourceId": absi(int(payload.get("pictureId", 0))),
		}
	var picture_rect: Object = service_owner.call("_picture_rect")
	if picture_rect == null:
		return {
			"status": "skipped",
			"message": "Realmz HUD PictureRect is unavailable",
		}
	if picture is Dictionary:
		var runtime_path := str(service_owner.call(
			"runtime_media_path",
			picture,
			"image/"
		))
		if not runtime_path.is_empty():
			if not picture_rect.has_method("display_image_path") \
					or not bool(picture_rect.display_image_path(runtime_path)):
				return {
					"status": "skipped",
					"message": "Classic picture runtime media could not be decoded",
				}
			return {
				"runtimeMediaPath": str(picture["runtimeMedia"].get("path", "")),
			}
	var paths: Object = _autoload("Paths")
	var game_global: Object = _autoload("GameGlobal")
	if paths == null or game_global == null:
		return {
			"status": "skipped",
			"message": "Realmz campaign paths are unavailable",
		}
	var splash_directory := str(paths.campaignsfolderpath)
	splash_directory = splash_directory.path_join(
		str(game_global.currentcampaign)
	)
	splash_directory = splash_directory.path_join("Splash Images")
	var file_candidates: Array = service_owner.call(
		"picture_file_candidates",
		payload
	)
	for file_name: String in file_candidates:
		if FileAccess.file_exists(splash_directory.path_join(file_name)):
			picture_rect.display_image(file_name)
			return {"fileName": file_name}
	return {
		"status": "skipped",
		"message": "Classic picture %d has no exported Remake image" \
			% int(payload.get("pictureId", 0)),
	}


func _show_scrolling_text(payload: Dictionary) -> Dictionary:
	var scrolling_text: Variant = payload.get("scrollingText", {})
	if not (scrolling_text is Dictionary) \
			or not (scrolling_text.get("text") is String):
		return _error("Classic scrolling text is unavailable")
	var ui: Object = _autoload("UI")
	if ui == null \
			or ui.ow_hud == null \
			or ui.ow_hud.classicPlayerMapRect == null:
		return _error("Realmz Classic scrolling-text UI is unavailable")
	var player_map_rect: Object = ui.ow_hud.classicPlayerMapRect
	var resource_id: int = abs(int(payload.get("resourceId", 0)))
	if not player_map_rect.display_map(
		{
			"id": resource_id,
			"show": -resource_id,
			"name": "Scrolling Text %d" % resource_id,
			"scrollingText": scrolling_text,
		},
		""
	):
		return _error("Classic scrolling text could not be displayed")
	var state_machine: Object = _autoload("StateMachine")
	if state_machine != null:
		state_machine.enter_ex_menu_state({
			"menu_name": "ClassicPlayerMapMenu",
		})
	await player_map_rect.closed
	if state_machine != null and state_machine._state_name == "ExMenus":
		state_machine.exit_ex_menu_state({})
	return {"resourceId": resource_id}


func _present_random_branch(payload: Dictionary) -> Dictionary:
	_play_sound(payload)
	if int(payload.get("messageId", 0)) == 0:
		return {}
	return await _show_text(payload)


func _show_encounter(payload: Dictionary) -> Dictionary:
	if str(payload.get("encounterKind", "")) == "complex":
		return await _show_complex_encounter(payload)
	if str(payload.get("encounterKind", "")) != "simple":
		return _error("Classic encounter kind is not supported")
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	var encounter: Variant = payload.get("encounter", {})
	if not (encounter is Dictionary):
		return _error("Classic encounter payload is missing its record")
	var prompt_message: Variant = payload.get("promptMessage", {})
	if prompt_message is Dictionary:
		text_rect.set_text(str(prompt_message.get("text", "")), false)
	var choice_model: Dictionary = service_owner.call(
		"build_simple_encounter_choices",
		encounter
	)
	var choices: Array = choice_model["choices"]
	var choice_tokens: Array = choice_model["outcomes"]
	if bool(choice_model.get("canBackOut", false)):
		service_owner.call("_append_stop_choice", choices, choice_tokens)
	if choices.is_empty():
		return _error("Classic simple encounter has no available choices")

	var selected_outcome: Variant = await service_owner.call(
		"_show_choices",
		text_rect,
		choices,
		choice_tokens
	)
	if str(selected_outcome) == STOP_CHOICE_TOKEN:
		return {"outcome": 0}
	return {"outcome": int(selected_outcome)}


func _show_complex_encounter(payload: Dictionary) -> Dictionary:
	var encounter: Variant = payload.get("encounter", {})
	if not (encounter is Dictionary):
		return _error("Classic complex encounter payload is missing its record")
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	if not bool(encounter.get("thief", false)):
		while true:
			service_owner.call("_show_encounter_prompt", text_rect, payload)
			var choice_model: Dictionary = service_owner.call(
				"build_complex_action_choices",
				encounter,
				false
			)
			var choices: Array = choice_model["choices"]
			var choice_tokens: Array = choice_model["tokens"]
			service_owner.call(
				"_append_complex_word_choice",
				encounter,
				choices,
				choice_tokens
			)
			service_owner.call(
				"_append_complex_spell_choice",
				encounter,
				choices,
				choice_tokens
			)
			service_owner.call(
				"_append_complex_scroll_choice",
				encounter,
				payload.get("scenarioItems", []),
				choices,
				choice_tokens
			)
			service_owner.call(
				"_append_complex_item_choice",
				encounter,
				choices,
				choice_tokens
			)
			if bool(encounter.get("canBackOut", false)):
				service_owner.call(
					"_append_stop_choice",
					choices,
					choice_tokens
				)
			if choices.is_empty():
				return _error(
					"Classic complex encounter has no available actions"
				)
			var selected := str(await service_owner.call(
				"_show_choices",
				text_rect,
				choices,
				choice_tokens
			))
			if selected == STOP_CHOICE_TOKEN:
				return {"outcome": 0}
			if selected == "word":
				var word_result: Dictionary = await service_owner.call(
					"_select_complex_word",
					encounter
				)
				if str(word_result.get("status", "")) == "cancelled":
					continue
				return word_result
			if selected == "spell":
				var spell_result: Dictionary = await service_owner.call(
					"_select_complex_spell",
					encounter
				)
				if str(spell_result.get("status", "")) == "cancelled":
					continue
				return spell_result
			if selected == "scroll":
				var scroll_result: Dictionary = await service_owner.call(
					"_select_complex_item",
					encounter,
					payload.get("itemTexts", []),
					payload.get("scenarioItems", []),
					"scroll"
				)
				if str(scroll_result.get("status", "")) == "cancelled":
					continue
				return scroll_result
			if selected == "item":
				var item_result: Dictionary = await service_owner.call(
					"_select_complex_item",
					encounter,
					payload.get("itemTexts", []),
					payload.get("scenarioItems", [])
				)
				if str(item_result.get("status", "")) == "cancelled":
					continue
				return item_result
			var token_parts := selected.split(":", false, 1)
			if token_parts.size() != 2 or token_parts[0] != "action":
				return _error(
					"Classic complex encounter returned an invalid action"
				)
			return {"outcome": int(token_parts[1])}

	var thief_encounter: Variant = payload.get("thiefEncounter", {})
	if not (thief_encounter is Dictionary) or thief_encounter.is_empty():
		return _error(
			"Classic rogue encounter payload is missing its Data TD2 record"
		)
	var resolver: Object = RogueResolverScript.new()
	if not resolver.configure(encounter, thief_encounter):
		return _error(resolver.last_error)
	var character: Object = service_owner.call("_selected_character")
	if character == null or not character.has_method("get_stat"):
		return _error(
			"Classic rogue encounters require a selected party member"
		)

	while true:
		character = service_owner.call("_living_rogue_character", character)
		if character == null:
			return _error(
				"Classic rogue encounter has no conscious party member"
			)
		service_owner.call("_show_encounter_prompt", text_rect, payload)
		var choice_model: Dictionary = service_owner.call(
			"build_rogue_encounter_choices",
			resolver,
			character,
			false
		)
		var choices: Array = choice_model["choices"]
		var choice_tokens: Array = choice_model["tokens"]
		var action_choices: Dictionary = service_owner.call(
			"build_complex_action_choices",
			encounter,
			false
		)
		choices.append_array(action_choices["choices"])
		choice_tokens.append_array(action_choices["tokens"])
		service_owner.call(
			"_append_complex_word_choice",
			encounter,
			choices,
			choice_tokens
		)
		service_owner.call(
			"_append_complex_spell_choice",
			encounter,
			choices,
			choice_tokens
		)
		service_owner.call(
			"_append_complex_scroll_choice",
			encounter,
			payload.get("scenarioItems", []),
			choices,
			choice_tokens
		)
		service_owner.call(
			"_append_complex_item_choice",
			encounter,
			choices,
			choice_tokens
		)
		if bool(encounter.get("canBackOut", false)):
			service_owner.call(
				"_append_stop_choice",
				choices,
				choice_tokens
			)
		if choices.is_empty():
			return _error(
				"Classic complex encounter has no available actions"
			)
		var selected := str(await service_owner.call(
			"_show_choices",
			text_rect,
			choices,
			choice_tokens
		))
		if selected == STOP_CHOICE_TOKEN:
			return {
				"outcome": 0,
				"thiefEncounter": resolver.rogue_encounter.duplicate(true),
			}
		if selected == "word":
			var word_result: Dictionary = await service_owner.call(
				"_select_complex_word",
				encounter
			)
			if str(word_result.get("status", "")) == "cancelled":
				continue
			word_result["thiefEncounter"] = \
				resolver.rogue_encounter.duplicate(true)
			return word_result
		if selected == "spell":
			var spell_result: Dictionary = await service_owner.call(
				"_select_complex_spell",
				encounter,
				true
			)
			if str(spell_result.get("status", "")) == "cancelled":
				continue
			spell_result = await service_owner.call(
				"_apply_rogue_spell_response",
				payload,
				resolver,
				spell_result,
				character
			)
			if str(spell_result.get("status", "")) == "error":
				return spell_result
			return spell_result
		if selected == "scroll":
			var scroll_result: Dictionary = await service_owner.call(
				"_select_complex_item",
				encounter,
				payload.get("itemTexts", []),
				payload.get("scenarioItems", []),
				"scroll",
				true
			)
			if str(scroll_result.get("status", "")) == "cancelled":
				continue
			scroll_result = await service_owner.call(
				"_apply_rogue_spell_response",
				payload,
				resolver,
				scroll_result,
				character
			)
			if str(scroll_result.get("status", "")) == "error":
				return scroll_result
			return scroll_result
		if selected == "item":
			var item_result: Dictionary = await service_owner.call(
				"_select_complex_item",
				encounter,
				payload.get("itemTexts", []),
				payload.get("scenarioItems", []),
				"",
				true
			)
			if str(item_result.get("status", "")) == "cancelled":
				continue
			item_result = await service_owner.call(
				"_apply_rogue_spell_response",
				payload,
				resolver,
				item_result,
				character
			)
			if str(item_result.get("status", "")) == "error":
				return item_result
			return item_result
		var token_parts := selected.split(":", false, 1)
		if token_parts.size() == 2 and token_parts[0] == "action":
			return {
				"outcome": int(token_parts[1]),
				"thiefEncounter": resolver.rogue_encounter.duplicate(true),
			}
		if token_parts.size() != 2 or token_parts[0] != "rogue":
			return _error(
				"Classic complex encounter returned an invalid action"
			)
		var action_index := int(token_parts[1])
		# Rogue resolution mutates TD2 state and may immediately damage the
		# party. From here onward the encounter must finish before it is saved.
		service_owner.set("_active_command_save_safe", false)
		var stat_value := float(
			character.get_stat(resolver.stat_name(action_index))
		)
		var resolution: Dictionary = resolver.resolve_action(
			action_index,
			resolver.roll_succeeds(
				action_index,
				stat_value,
				randi_range(1, 100)
			)
		)
		match str(resolution.get("status", "")):
			"error":
				return _error(str(resolution.get(
					"message",
					"Classic rogue action failed"
				)))
			"trap":
				var trap_result: Dictionary = await service_owner.call(
					"_show_rogue_trap",
					resolution,
					character
				)
				if str(trap_result.get("status", "")) == "error":
					return trap_result
			"resolved":
				await service_owner.call(
					"_show_rogue_feedback",
					payload,
					resolution
				)
				var outcome := int(resolution.get("outcome", 0))
				if outcome != 0:
					return {
						"outcome": outcome,
						"thiefEncounter": resolution["thiefEncounter"],
					}
			_:
				return _error(
					"Classic rogue action returned an invalid result"
				)
	return _error("Classic rogue encounter ended unexpectedly")


func _play_sound(payload: Dictionary) -> Dictionary:
	var override: Variant = service_owner.call(
		"scenario_presentation_override",
		"play_sound",
		payload
	)
	if override is Dictionary:
		return override
	var sound_id := int(payload.get("soundId", 0))
	var sound: Variant = payload.get("sound", {})
	if (not (sound is Dictionary) or sound.is_empty()) \
			and service_owner.classic_bundle != null \
			and service_owner.classic_bundle.has_method("get_sound"):
		sound = service_owner.classic_bundle.get_sound(sound_id)
	var sound_ids: Object = _autoload("SfxIdDivinity")
	var native_mapping: Dictionary = sound_ids.mapping \
		if sound_ids != null and sound_ids.mapping is Dictionary else {}
	var resolution: Dictionary = SoundResolutionScript.resolve(
		sound_id,
		sound if sound is Dictionary else {},
		native_mapping
	)
	var resolution_status := str(resolution.get("status", ""))
	if resolution_status == "silent-sentinel":
		resolution["status"] = "source-noop"
		return resolution
	if resolution_status == "unresolved-external-classic-resource":
		resolution["status"] = "unresolved-noop"
		resolution["message"] = (
			"Classic sound %d is unavailable in Remake's resource chain"
			% absi(sound_id)
		)
		return resolution
	if resolution_status == "missing-runtime-media":
		resolution["status"] = "skipped"
		resolution["message"] = (
			"Classic sound %d has no decoded runtime media" % absi(sound_id)
		)
		return resolution
	if resolution_status == "unsupported-runtime-media":
		resolution["status"] = "skipped"
		resolution["message"] = (
			"Classic sound %d uses unsupported runtime media '%s'" % [
				absi(sound_id),
				str(resolution.get("runtimeMediaType", "")),
			]
		)
		return resolution
	var stream: AudioStream = null
	if resolution_status == "runtime-media":
		stream = service_owner.call("runtime_audio_stream", sound)
		if stream == null:
			resolution["status"] = "skipped"
			resolution["message"] = (
				"Classic sound %d runtime media could not be loaded"
				% absi(sound_id)
			)
			return resolution
	else:
		var node_access: Object = _autoload("NodeAccess")
		var resources: Object = node_access.__Resources() \
			if node_access != null else null
		var sound_name := str(resolution.get("nativeName", ""))
		if resources == null or not resources.sounds_book.has(sound_name):
			resolution["status"] = "skipped"
			resolution["message"] = \
				"Mapped sound '%s' is not loaded" % sound_name
			return resolution
		stream = resources.sounds_book[sound_name]
	var sfx_player: Object = _autoload("SfxPlayer")
	if sfx_player == null:
		resolution["status"] = "skipped"
		resolution["message"] = "Realmz SFX player is unavailable"
		return resolution
	sfx_player.stream = stream
	sfx_player.play()
	resolution["status"] = "played"
	return resolution


func _play_sound_command(payload: Dictionary) -> Dictionary:
	var result := _play_sound(payload)
	if str(result.get("status", "")) != "played" \
			or not bool(result.get("waitForCompletion", false)):
		return result
	var sfx_player: Object = _autoload("SfxPlayer")
	if sfx_player != null and bool(sfx_player.get("playing")):
		await sfx_player.finished
	result["waitedForCompletion"] = true
	return result
