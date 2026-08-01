class_name ScenarioGodotPresentationServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const RogueResolverScript = preload(
	"res://scripts/classic_runtime/classic_rogue_encounter_resolver.gd"
)
const SoundResolutionScript = preload(
	"res://scripts/classic_runtime/classic_sound_resolution.gd"
)
const STOP_CHOICE_TOKEN := "STOP"

signal scenario_debugger_resumed(action: String)

var _scenario_debugger_waiting := false


func _scenario_debug_pause(_payload: Dictionary) -> Dictionary:
	_scenario_debugger_waiting = true
	var action: String = await scenario_debugger_resumed
	_scenario_debugger_waiting = false
	return {"action": action}


func resume_scenario_debugger(action: String) -> Dictionary:
	if not _scenario_debugger_waiting:
		return {
			"status": "error",
			"message": "Scenario debugger is not waiting",
		}
	scenario_debugger_resumed.emit(action)
	return {"status": "ok"}


func _query_encounter_definition(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario encounter definitions are unavailable")
	var encounter_kind := str(
		payload.get("encounterKind", "")
	).to_lower()
	var encounter_id := int(payload.get("encounterId", -1))
	if encounter_kind not in ["simple", "complex"] or encounter_id < 0:
		return _error("Scenario encounter definition reference is invalid")
	var record: Dictionary = service_owner.classic_bundle.get_encounter(
		encounter_kind,
		encounter_id
	)
	if record.is_empty():
		return _error(
			"Scenario %s encounter %d is unavailable"
			% [encounter_kind, encounter_id]
		)
	var option_count := 0
	var texts: Variant = record.get("texts", [])
	if texts is Array:
		for text_value: Variant in texts:
			if not str(text_value).strip_edges().is_empty():
				option_count += 1
	return {
		"id": str(record.get("id", encounter_id)),
		"name": str(record.get(
			"name",
			"%s Encounter %d" % [
				encounter_kind.capitalize(),
				encounter_id,
			]
		)),
		"encounterKind": encounter_kind,
		"optionCount": option_count,
		"canBackOut": bool(record.get("canBackOut", false)),
		"maximumRuns": int(record.get("maxTimes", 0)),
	}


func _query_media_definition(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario media definitions are unavailable")
	var media_kind := str(payload.get("mediaKind", "")).to_lower()
	var resource_id := int(payload.get("resourceId", -1))
	if media_kind not in ["picture", "sound", "text"] or resource_id < 0:
		return _error("Scenario media definition reference is invalid")
	var record: Dictionary
	match media_kind:
		"picture":
			record = service_owner.classic_bundle.get_picture(resource_id)
		"sound":
			record = service_owner.classic_bundle.get_sound(resource_id)
		"text":
			record = service_owner.classic_bundle.get_scrolling_text(
				resource_id
			)
	if record.is_empty():
		return _error(
			"Scenario %s resource %d is unavailable"
			% [media_kind, resource_id]
		)
	var runtime_media: Variant = record.get("runtimeMedia", {})
	if not (runtime_media is Dictionary):
		runtime_media = {}
	return {
		"id": str(record.get("id", resource_id)),
		"name": str(record.get(
			"label",
			record.get("name", "%s %d" % [media_kind, resource_id])
		)),
		"mediaKind": media_kind,
		"resourceId": int(record.get("resourceId", resource_id)),
		"runtimePath": str(runtime_media.get(
			"path",
			record.get("runtimePath", "")
		)),
		"mediaType": str(runtime_media.get(
			"mediaType",
			record.get("resourceType", "")
		)),
	}


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


func _scenario_choice(payload: Dictionary) -> Dictionary:
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	var options_value: Variant = payload.get("options", [])
	if not (options_value is Array) \
			or options_value.is_empty() \
			or options_value.size() > 256:
		return _error("Scenario choice requires between 1 and 256 options")
	var choices: Array = []
	var tokens: Array = []
	for index: int in range(options_value.size()):
		var label: Variant = options_value[index]
		if not (label is String) or str(label).strip_edges().is_empty():
			return _error("Scenario choice labels must be non-empty strings")
		choices.append(str(label))
		tokens.append(index)
	var prompt := str(payload.get("prompt", ""))
	if not prompt.is_empty():
		text_rect.set_text(prompt, false)
	var selected: Variant = await service_owner.call(
		"_show_choices",
		text_rect,
		choices,
		tokens
	)
	if not (selected is int):
		return _error("Scenario choice returned an invalid option")
	return {"choice": int(selected)}


func _scenario_encounter_response(payload: Dictionary) -> Dictionary:
	var picture_id: Variant = payload.get("pictureId")
	if picture_id != null and not str(picture_id).is_empty():
		await _show_classic_picture({"pictureId": int(picture_id)})
	var sound_id: Variant = payload.get("soundId")
	if sound_id != null and not str(sound_id).is_empty():
		await _play_sound_command({"soundId": int(sound_id)})
	var responses: Variant = payload.get("responses", [])
	if not (responses is Array) or responses.is_empty():
		return _error("Scenario Encounter has no available responses")
	var choice_model := _scenario_response_choice_model(responses)
	if str(choice_model.get("status", "")) == "error":
		return choice_model
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	while true:
		var prompt := str(payload.get("text", ""))
		if not prompt.is_empty():
			text_rect.set_text(prompt, false)
		var selected_token := str(await service_owner.call(
			"_show_choices",
			text_rect,
			choice_model.get("labels", []),
			choice_model.get("tokens", [])
		))
		if selected_token.begins_with("response:"):
			var direct := _scenario_response_by_id(
				responses,
				selected_token.trim_prefix("response:")
			)
			if direct.is_empty():
				return _error("Scenario Encounter returned an invalid response")
			var direct_context: Dictionary = {}
			if str(direct.get("kind", "")) == "rogue":
				direct_context["rogueOutcome"] = "attempt"
			return _scenario_response_result(direct, direct_context)

		var selection: Dictionary
		var matched: Dictionary
		match selected_token:
			"mode:typed-reply":
				selection = await service_owner.call(
					"_select_scenario_word_response"
				)
				matched = matching_scenario_typed_response(
					responses,
					str(selection.get("spokenText", ""))
				)
			"mode:spell":
				selection = await service_owner.call(
					"_select_scenario_spell_response"
				)
				matched = matching_scenario_record_response(
					responses,
					"spell",
					selection.get("recordIds", [])
				)
			"mode:item":
				selection = await service_owner.call(
					"_select_scenario_item_response"
				)
				matched = matching_scenario_record_response(
					responses,
					"item",
					selection.get("recordIds", [])
				)
			_:
				return _error("Scenario Encounter returned an invalid response mode")
		if str(selection.get("status", "")) == "error":
			return selection
		if str(selection.get("status", "")) == "cancelled":
			continue
		if matched.is_empty():
			continue
		return _scenario_response_result(matched, selection)
	return _error("Scenario Encounter response selection ended unexpectedly")


func _scenario_response_choice_model(responses: Array) -> Dictionary:
	var labels: Array = []
	var tokens: Array = []
	var modes := {
		"typed-reply": false,
		"spell": false,
		"item": false,
	}
	for response_value: Variant in responses:
		if not (response_value is Dictionary):
			return _error("Scenario Encounter response is invalid")
		var response: Dictionary = response_value
		var response_id := str(response.get("id", "")).strip_edges()
		if response_id.is_empty():
			return _error("Scenario Encounter response has no stable ID")
		var kind := str(response.get("kind", "choice"))
		if kind in modes:
			if not bool(modes[kind]) and _scenario_response_mode_available(kind):
				modes[kind] = true
				labels.append({
					"typed-reply": "Speak",
					"spell": "Cast a spell",
					"item": "Use an item",
				}.get(kind, kind.capitalize()))
				tokens.append("mode:%s" % kind)
			continue
		if kind == "rogue" \
				and str(response.get("match", {}).get("outcome", "attempt")) \
				!= "attempt":
			continue
		if kind not in ["choice", "rogue", "back-out"]:
			return _error("Scenario Encounter response kind '%s' is invalid" % kind)
		var label := str(response.get("label", "")).strip_edges()
		if label.is_empty():
			label = "Back out" if kind == "back-out" else kind.capitalize()
		labels.append(label)
		tokens.append("response:%s" % response_id)
	if labels.is_empty():
		return _error(
			"Scenario Encounter has no selectable responses; rogue success and "
			+ "failure routes require a selectable attempt"
		)
	return {"labels": labels, "tokens": tokens}


func _scenario_response_mode_available(kind: String) -> bool:
	if service_owner == null:
		return true
	if kind == "spell":
		return service_owner.call("_first_spellcaster") != null
	if kind == "item":
		return service_owner.call("_first_item_holder") != null
	return true


static func matching_scenario_typed_response(
	responses: Array,
	entered_text: String
) -> Dictionary:
	var entered := entered_text.strip_edges().to_lower()
	for response_value: Variant in responses:
		if response_value is Dictionary \
				and str(response_value.get("kind", "")) == "typed-reply" \
				and str(response_value.get("match", {}).get("text", "")) \
				.strip_edges().to_lower() == entered:
			return response_value
	return {}


static func matching_scenario_record_response(
	responses: Array,
	kind: String,
	selected_record_ids: Variant
) -> Dictionary:
	if not (selected_record_ids is Array):
		return {}
	var selected: Array[String] = []
	for id_value: Variant in selected_record_ids:
		var normalized := str(id_value).strip_edges().to_lower()
		if not normalized.is_empty() and not selected.has(normalized):
			selected.append(normalized)
	for response_value: Variant in responses:
		if not (response_value is Dictionary) \
				or str(response_value.get("kind", "")) != kind:
			continue
		var expected := str(
			response_value.get("match", {}).get("recordId", "")
		).strip_edges().to_lower()
		if not expected.is_empty() and selected.has(expected):
			return response_value
	return {}


static func _scenario_response_by_id(
	responses: Array,
	response_id: String
) -> Dictionary:
	for response_value: Variant in responses:
		if response_value is Dictionary \
				and str(response_value.get("id", "")) == response_id:
			return response_value
	return {}


static func _scenario_response_result(
	response: Dictionary,
	selection: Dictionary
) -> Dictionary:
	var result := selection.duplicate(true)
	result.erase("outcome")
	result["responseRef"] = {
		"kind": str(response.get("kind", "choice")),
		"responseId": str(response.get("id", "")),
	}
	return result


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


func _hydrate_scenario_scrolling_text(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario scrolling-text catalog is unavailable")
	var resource_id := int(payload.get("resourceId", -1))
	var scrolling_text: Dictionary = (
		service_owner.classic_bundle.get_scrolling_text(resource_id)
	)
	if scrolling_text.is_empty():
		return _error(
			"Scenario scrolling-text resource %d is unavailable" % resource_id
		)
	var result := payload.duplicate(true)
	result["scrollingText"] = scrolling_text
	return {"status": "ok", "payload": result}


func _present_random_branch(payload: Dictionary) -> Dictionary:
	_play_sound(payload)
	if int(payload.get("messageId", 0)) == 0:
		return {}
	return await _show_text(payload)


func _show_encounter(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.encounter.start":
		var hydration := _hydrate_scenario_encounter(routed_payload)
		if str(hydration.get("status", "")) == "error":
			return hydration
		routed_payload = hydration.get("payload", {})
	if str(routed_payload.get("encounterKind", "")) == "complex":
		return await _show_complex_encounter(routed_payload)
	if str(routed_payload.get("encounterKind", "")) != "simple":
		return _error("Classic encounter kind is not supported")
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error("Realmz HUD TextRect is unavailable")
	var encounter: Variant = routed_payload.get("encounter", {})
	if not (encounter is Dictionary):
		return _error("Classic encounter payload is missing its record")
	var prompt_message: Variant = routed_payload.get("promptMessage", {})
	if prompt_message is Dictionary:
		text_rect.set_text(str(prompt_message.get("text", "")), false)
	var choice_model: Dictionary = service_owner.call(
		"build_simple_encounter_choices",
		encounter
	)
	var choices: Array = choice_model["choices"]
	var outcomes: Array = choice_model["outcomes"]
	var slots: Array = choice_model.get("slots", [])
	var choice_tokens: Array = []
	for index: int in range(outcomes.size()):
		choice_tokens.append("option:%d:%s" % [
			int(slots[index]) if index < slots.size() else index,
			str(outcomes[index]),
		])
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
		return {
			"outcome": 0,
			"responseRef": {"kind": "back-out"},
		}
	var simple_parts := str(selected_outcome).split(":", false)
	if simple_parts.size() != 3 or simple_parts[0] != "option":
		return _error("Classic simple encounter returned an invalid option")
	return {
		"outcome": int(simple_parts[2]),
		"optionSlot": int(simple_parts[1]),
		"responseRef": {
			"kind": "simple-choice",
			"index": int(simple_parts[1]),
		},
	}


func _hydrate_scenario_encounter(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario encounter catalog is unavailable")
	var encounter_kind := str(payload.get("encounterKind", "")).to_lower()
	if encounter_kind not in ["simple", "complex"]:
		return _error("Scenario encounter kind must be simple or complex")
	var encounter_id := int(payload.get("encounterId", -1))
	var encounter: Dictionary = service_owner.classic_bundle.get_encounter(
		encounter_kind,
		encounter_id
	)
	if encounter.is_empty():
		return _error(
			"Scenario %s encounter %d is unavailable"
			% [encounter_kind, encounter_id]
		)
	var runtime_state := _classic_runtime_state()
	if runtime_state != null:
		if encounter_kind == "simple":
			encounter = runtime_state.get_effective_simple_encounter(encounter)
		else:
			encounter = runtime_state.get_effective_complex_encounter(encounter)
	var result := payload.duplicate(true)
	result["encounter"] = encounter
	result["promptMessage"] = service_owner.classic_bundle.get_message(
		int(encounter.get("prompt", 0))
	)
	if encounter_kind == "complex":
		var item_texts: Array = []
		for item_id_value: Variant in encounter.get("itemIds", []):
			var item_id := absi(int(item_id_value))
			if item_id == 0:
				continue
			var item_text: Dictionary = (
				service_owner.classic_bundle.get_item_text(item_id)
			)
			if not item_text.is_empty():
				item_texts.append(item_text)
		result["itemTexts"] = item_texts
		var scenario_items: Array = []
		var item_ids: Array = (
			service_owner.classic_bundle.scenario_items_by_id.keys()
		)
		item_ids.sort()
		for item_id_value: Variant in item_ids:
			scenario_items.append(
				service_owner.classic_bundle.scenario_items_by_id[item_id_value]
			)
		result["scenarioItems"] = scenario_items
		if bool(encounter.get("thief", false)):
			var thief_id := int(encounter.get("thiefSuccess", 0))
			var thief_encounter: Dictionary = (
				service_owner.classic_bundle.get_thief_encounter(thief_id)
			)
			if thief_encounter.is_empty():
				return _error(
					"Scenario rogue encounter %d is unavailable" % thief_id
				)
			if runtime_state != null:
				thief_encounter = (
					runtime_state.get_effective_thief_encounter(thief_encounter)
				)
			result["thiefEncounter"] = thief_encounter
	return {"status": "ok", "payload": result}


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
			var classic_tokens: Array = choice_model["tokens"]
			var action_slots: Array = choice_model.get("slots", [])
			var choice_tokens: Array = []
			for action_index: int in range(classic_tokens.size()):
				choice_tokens.append("action:%d:%s" % [
					int(action_slots[action_index])
						if action_index < action_slots.size() else action_index,
					str(classic_tokens[action_index]).trim_prefix("action:"),
				])
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
					"responseRef": {"kind": "back-out"},
				}
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
			var token_parts := selected.split(":", false)
			if token_parts.size() != 3 or token_parts[0] != "action":
				return _error(
					"Classic complex encounter returned an invalid action"
				)
			return {
				"outcome": int(token_parts[2]),
				"optionSlot": int(token_parts[1]),
				"responseRef": {
					"kind": "action-choice",
					"index": int(token_parts[1]),
				},
			}

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
		var action_tokens: Array = action_choices["tokens"]
		var action_slots: Array = action_choices.get("slots", [])
		for action_index: int in range(action_tokens.size()):
			choice_tokens.append("action:%d:%s" % [
				int(action_slots[action_index])
					if action_index < action_slots.size() else action_index,
				str(action_tokens[action_index]).trim_prefix("action:"),
			])
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
				"responseRef": {"kind": "back-out"},
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
		var token_parts := selected.split(":", false)
		if token_parts.size() == 3 and token_parts[0] == "action":
			return {
				"outcome": int(token_parts[2]),
				"optionSlot": int(token_parts[1]),
				"responseRef": {
					"kind": "action-choice",
					"index": int(token_parts[1]),
				},
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
						"responseRef": {
							"kind": "rogue",
							"outcome": (
								"success"
								if bool(resolution.get("success", false))
								else "failure"
							),
						},
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


func _play_scenario_music(payload: Dictionary) -> Dictionary:
	var music_player: Object = _autoload("MusicStreamPlayer")
	if music_player == null:
		return _error("Realmz music player is unavailable")
	var track_name := str(payload.get("trackName", "")).strip_edges()
	if not track_name.is_empty():
		if not music_player.has_method("play_music_specific"):
			return _error("Realmz specific-music API is unavailable")
		music_player.call("play_music_specific", track_name)
		return {"trackName": track_name}
	var music_type := str(payload.get("musicType", "")).strip_edges()
	if music_type.is_empty():
		return _error("Scenario music requires a music type or track name")
	if not music_player.has_method("play_music_type"):
		return _error("Realmz music-category API is unavailable")
	var result: Variant = music_player.call("play_music_type", music_type)
	return {
		"musicType": music_type,
		"selection": (
			result.duplicate(true) if result is Dictionary else {}
		),
	}
