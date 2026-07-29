class_name ScenarioGodotCharacterServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const CharacterConditionRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_condition_rules.gd"
)


func scenario_spell_behavior_context(
	spell: Object,
	caster: Object,
	targets: Array,
	power: int,
	cast_context: Dictionary
) -> Dictionary:
	if spell == null:
		return _error("Scenario spell behavior requires a spell")
	var target_ids: Array = []
	var classic_ids: Variant = spell.get("classic_spell_ids")
	if classic_ids is Array:
		for id_value: Variant in classic_ids:
			var id_text := str(id_value)
			if not id_text.is_empty() and id_text not in target_ids:
				target_ids.append(id_text)
	for key: String in ["spellId", "authoredSpellId"]:
		var context_id := str(cast_context.get(key, ""))
		if not context_id.is_empty() and context_id not in target_ids:
			target_ids.push_front(context_id)
	var spell_name := str(spell.get("name"))
	if target_ids.is_empty() and spell_name.is_empty():
		return _error("Scenario spell behavior cannot resolve spell identity")
	var target_snapshots: Array = []
	for target_value: Variant in targets:
		if target_value is Object:
			target_snapshots.append(_spell_creature_snapshot(target_value))
	var request := {
		"spell": {
			"ids": target_ids.duplicate(),
			"name": spell_name,
			"power": power,
		},
		"caster": _spell_creature_snapshot(caster),
		"targets": target_snapshots,
		"cast": cast_context.duplicate(true),
	}
	return {
		"status": "ok",
		"targetIds": target_ids,
		"request": request,
	}


func _spell_creature_snapshot(creature: Object) -> Dictionary:
	if creature == null:
		return {}
	var health := _character_stat(creature, "curHP")
	var maximum_health := _character_stat(creature, "maxHP")
	return {
		"id": _spell_creature_id(creature),
		"name": str(creature.get("name")),
		"health": health,
		"maximumHealth": maximum_health,
		"spellPoints": _character_stat(creature, "curSP"),
		"maximumSpellPoints": _character_stat(creature, "maxSP"),
		"alive": health > 0 and int(creature.get("life_status")) < 3,
	}


func _spell_creature_id(creature: Object) -> String:
	if service_owner != null \
			and service_owner.has_method("_combat_context") \
			and service_owner.has_method("_combatant_creature"):
		var combat_context: Variant = service_owner.call("_combat_context")
		if combat_context is Dictionary and not combat_context.has("error"):
			var combatants: Variant = combat_context.get("combatants", [])
			if combatants is Array:
				for index: int in range(combatants.size()):
					if service_owner.call(
						"_combatant_creature",
						combatants[index]
					) == creature:
						return "combat:%d" % index
	if service_owner != null and service_owner.has_method("_party_characters"):
		var party: Variant = service_owner.call("_party_characters")
		if party is Array:
			for index: int in range(party.size()):
				if party[index] == creature:
					return "party:%d" % index
	return "runtime:%d" % creature.get_instance_id()


func _query_party_members(_payload: Dictionary = {}) -> Dictionary:
	var snapshots: Array = []
	var party: Array = service_owner.call("_party_characters")
	var rule_names: Dictionary = service_owner.call("_classic_rule_names")
	for index: int in range(party.size()):
		var character_value: Variant = party[index]
		if not (character_value is Object):
			continue
		var stats: Variant = character_value.get("stats")
		if not (stats is Dictionary):
			stats = {}
		var current_health := int(stats.get("curHP", 0))
		var race_id := int(service_owner.call(
			"_classic_identity_value",
			character_value,
			"race",
			rule_names
		))
		var caste_id := int(service_owner.call(
			"_classic_identity_value",
			character_value,
			"caste",
			rule_names
		))
		var race_names: Variant = rule_names.get("raceNames", [])
		var caste_names: Variant = rule_names.get("casteNames", [])
		var condition_values: Array = []
		for condition_index: int in range(40):
			condition_values.append(
				CharacterConditionRulesScript.condition_value(
					character_value,
					condition_index
				)
			)
		var item_ids: Array = []
		for item_value: Variant in service_owner.call(
			"_character_inventory_items",
			character_value
		):
			for item_id_value: Variant in service_owner.call(
				"_classic_item_ids",
				item_value
			):
				var item_id := int(item_id_value)
				if item_id != 0 and item_id not in item_ids:
					item_ids.append(item_id)
		item_ids.sort()
		snapshots.append({
			"id": "party:%d" % index,
			"name": str(character_value.get("name")),
			"level": int(character_value.get("level")),
			"raceId": race_id,
			"raceName": (
				str(race_names[race_id - 1])
				if race_names is Array
					and race_id > 0
					and race_id <= race_names.size()
				else ""
			),
			"casteId": caste_id,
			"casteName": (
				str(caste_names[caste_id - 1])
				if caste_names is Array
					and caste_id > 0
					and caste_id <= caste_names.size()
				else ""
			),
			"gender": int(service_owner.call(
				"_classic_identity_value",
				character_value,
				"gender",
				rule_names
			)),
			"health": current_health,
			"maximumHealth": int(stats.get("maxHP", current_health)),
			"spellPoints": int(stats.get("curSP", 0)),
			"maximumSpellPoints": int(stats.get("maxSP", 0)),
			"strength": _character_stat(character_value, "Strength"),
			"intellect": _character_stat(character_value, "Intellect"),
			"wisdom": _character_stat(character_value, "Wisdom"),
			"dexterity": _character_stat(character_value, "Dexterity"),
			"vitality": _character_stat(character_value, "Vitality"),
			"luck": _character_stat(character_value, "Luck"),
			"movement": (
				int(character_value.call("get_movement_left"))
				if character_value.has_method("get_movement_left")
				else 0
			),
			"conditions": condition_values,
			"itemIds": item_ids,
			"alive": current_health > 0 and int(character_value.get("life_status")) < 3,
		})
	return {"members": snapshots, "value": snapshots}


static func _character_stat(character: Object, stat_name: String) -> int:
	if character != null and character.has_method("get_stat"):
		return int(character.call("get_stat", stat_name))
	return 0


func _alter_party_fatigue(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null \
			or not bool(service_owner.call(
				"_object_has_property",
				game_global,
				"fatigue"
			)) \
			or not game_global.has_method("set_party_fatigue"):
		return _error("Realmz party fatigue is unavailable")
	var previous := float(game_global.get("fatigue"))
	var current := float(service_owner.call(
		"classic_fatigue_after_action",
		previous,
		payload
	))
	game_global.call("set_party_fatigue", current)
	return {
		"previousFatigue": previous,
		"fatigue": current,
	}


func _change_scenario_party_fatigue(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null \
			or not game_global.has_method("set_party_fatigue"):
		return _error("Realmz party fatigue is unavailable")
	var previous := float(game_global.get("fatigue"))
	var current := previous + float(payload.get("amount", 0.0))
	game_global.call("set_party_fatigue", current)
	return {
		"previousFatigue": previous,
		"fatigue": float(game_global.get("fatigue")),
	}


func _check_party_condition(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz party state is unavailable")
	var global_effects: Variant = game_global.get("global_effects")
	if not (global_effects is Dictionary):
		return _error("Realmz global-effect state is unavailable")
	var result: Dictionary = service_owner.call(
		"party_condition_status",
		int(payload.get("conditionIndex", -1)),
		global_effects,
		int(game_global.get("classic_light_condition")),
		game_global.get("classic_party_conditions")
	)
	if not bool(result.get("supported", false)):
		return _error(
			"Classic party condition %d has no Remake state mapping" \
				% int(payload.get("conditionIndex", -1))
		)
	return {"active": bool(result.get("active", false))}


func _check_party_ally(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	var player_allies: Variant = game_global.get("player_allies") \
		if game_global != null else null
	if not (player_allies is Array):
		return _error("Realmz ally state is unavailable")
	return {
		"present": bool(service_owner.call(
			"party_has_classic_ally",
			payload,
			player_allies
		)),
	}


func _add_classic_ally(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.character.add-ally":
		if service_owner.classic_bundle == null:
			return _error("Scenario monster catalog is unavailable")
		var authored_monster: Dictionary = (
			service_owner.classic_bundle.get_monster(
				int(routed_payload.get("monsterId", -1))
			)
		)
		if authored_monster.is_empty():
			return _error(
				"Scenario ally monster %d is unavailable"
				% int(routed_payload.get("monsterId", -1))
			)
		routed_payload["monster"] = authored_monster
	var game_global: Object = _autoload("GameGlobal")
	var player_allies: Variant = game_global.get("player_allies") \
		if game_global != null else null
	if not (player_allies is Array):
		return _error("Realmz ally state is unavailable")
	if player_allies.size() >= 20:
		return {"status": "skipped", "message": "Classic ally limit of 20 has been reached"}
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	var creature_book: Variant = resources.get("crea_book") if resources != null else null
	if not (creature_book is Dictionary):
		return _error("Realmz bestiary resources are unavailable")
	var monster: Variant = routed_payload.get("monster", {})
	if not (monster is Dictionary):
		return _error("Classic ally command is missing its monster record")
	var monster_id := int(routed_payload.get("monsterId", -1))
	var bestiary_name := str(service_owner.call(
		"resolve_classic_monster_bestiary_name",
		monster_id,
		monster,
		creature_book
	))
	if bestiary_name.is_empty():
		return _error("Classic ally %d (%s) has no matching Remake bestiary entry" % [
			monster_id,
			monster.get("displayName", "unnamed"),
		])
	var creature_script: Variant = game_global.get("combatCreatureGD")
	if not (creature_script is Script):
		return _error("Realmz creature script is unavailable")
	var ally: Object = creature_script.new()
	if not ally.has_method("initialize_from_bestiary_dict"):
		return _error("Realmz creature cannot load a bestiary entry")
	ally.initialize_from_bestiary_dict(
		bestiary_name,
		service_owner.call(
			"_classic_monster_generation_context",
			game_global,
			"ally"
		)
	)
	service_owner.call(
		"_set_classic_monster_identity",
		ally,
		monster_id,
		monster
	)
	game_global.add_npc_ally(ally)
	return {"name": str(ally.get("name")), "monsterId": monster_id}


func _remove_classic_allies(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	var player_allies: Variant = game_global.get("player_allies") \
		if game_global != null else null
	if not (player_allies is Array):
		return _error("Realmz ally state is unavailable")
	var previous_allies: Array = player_allies.duplicate()
	var result: Dictionary = service_owner.call(
		"remove_classic_allies",
		payload,
		player_allies
	)
	for ally_value: Variant in previous_allies:
		if player_allies.has(ally_value):
			continue
		service_owner.classic_selected_characters.erase(ally_value)
		var native_selection: Variant = game_global.get("last_picked_characters")
		if native_selection is Array:
			native_selection.erase(ally_value)
	var ui: Object = _autoload("UI")
	if ui != null and ui.ow_hud != null \
			and ui.ow_hud.has_method("fillCharactersRect"):
		ui.ow_hud.fillCharactersRect()
	return result


func _give_experience(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	if str(payload.get("_scenarioApiOperation", "")) \
			== "core.character.give-experience" \
			and bool(payload.get("selectedOnly", false)):
		var selected: Array = service_owner.call(
			"_current_selected_characters"
		)
		if selected.is_empty():
			return _error(
				"Scenario experience award has no selected characters"
			)
		if not game_global.has_method("give_exp_to_pcs"):
			return _error("Realmz experience award API is unavailable")
		await game_global.call(
			"give_exp_to_pcs",
			int(payload.get("experience", 0)),
			selected
		)
		return {
			"experience": int(payload.get("experience", 0)),
			"selectedOnly": true,
			"characterCount": selected.size(),
		}
	await game_global.show_loot_menu(
		[],
		[0, 0, 0],
		int(payload.get("experience", 0))
	)
	return {}


func _remove_experience(payload: Dictionary) -> Dictionary:
	var party: Array = service_owner.call("_party_characters")
	var result: Dictionary = service_owner.call(
		"apply_classic_experience_loss",
		payload,
		party,
		service_owner.call("_current_selected_characters")
	)
	service_owner.call("_refresh_party_panels", party)
	return result


func _give_character_condition(payload: Dictionary) -> Dictionary:
	var result: Dictionary = CharacterConditionRulesScript.apply_condition(
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters"),
		str(payload.get("targetMode", "")),
		int(payload.get("conditionIndex", -1)),
		int(payload.get("duration", 0))
	)
	if str(result.get("status", "")) == "error":
		return result
	var affected_characters: Array = result.get("affectedCharacters", [])
	result["affectedCount"] = affected_characters.size()
	for character_value: Variant in affected_characters:
		service_owner.call(
			"_play_sound",
			{"soundId": int(payload.get("soundId", 0))}
		)
		service_owner.call("_refresh_character_panel", character_value)
	result.erase("affectedCharacters")
	return result


func _pick_characters(payload: Dictionary) -> Dictionary:
	var party: Array = service_owner.call("_party_characters")
	if party.is_empty():
		return _error("Classic character pick has no party members")
	var allow_dead := bool(payload.get("allowDead", false))
	var eligible: Array = []
	for character_value: Variant in party:
		if allow_dead or bool(service_owner.call("_is_living_character", character_value)):
			eligible.append(character_value)
	if eligible.is_empty():
		return _error("Classic character pick has no eligible party members")
	var count: int = min(int(payload.get("count", 0)), eligible.size())
	if count < 1:
		return _error("Classic character pick requests no characters")
	var ui: Object = _autoload("UI")
	if ui == null or ui.ow_hud == null:
		return _error("Realmz character picker is unavailable")
	ui.ow_hud.request_pc_pick(count)
	var picked_value: Variant = await ui.ow_hud.pc_picked
	if not (picked_value is Array):
		return _error("Realmz character picker returned an invalid selection")
	for character_value: Variant in picked_value:
		if not party.has(character_value) \
				or (
					not allow_dead
					and not bool(service_owner.call(
						"_is_living_character",
						character_value
					))
				):
			return _error("Realmz character picker returned an ineligible party member")
	var selected: Array = service_owner.call(
		"select_characters_after_pick",
		picked_value,
		party,
		bool(payload.get("invert", false))
	)
	service_owner.call("_store_selected_characters", selected)
	return {"selectedCount": selected.size()}


func _filter_selected_characters(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call(
		"filter_characters_by_check",
		payload,
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters")
	)
	if str(result.get("status", "")) == "error":
		return result
	var selected: Array = result.get("selected", [])
	service_owner.call("_store_selected_characters", selected)
	return {
		"selectedCount": selected.size(),
		"checks": result.get("checks", []),
	}


func _check_character_ability(payload: Dictionary) -> Dictionary:
	var pick_result := await _pick_characters({
		"count": 1,
		"allowDead": false,
		"invert": false,
	})
	if str(pick_result.get("status", "")) == "error":
		return pick_result
	var selected: Array = service_owner.call("_current_selected_characters")
	if selected.size() != 1:
		return _error("Classic character-ability check did not select one character")
	return service_owner.call("character_ability_check", payload, selected[0])


func _level_up_selected_characters(payload: Dictionary) -> Dictionary:
	var selected: Array = service_owner.call("_current_selected_characters")
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	for character_value: Variant in selected:
		if not (character_value is Object) \
				or not bool(service_owner.call(
					"_object_has_property",
					character_value,
					"exp_tnl"
				)):
			return _error("Classic level-up target cannot receive experience")
		character_value.set("exp_tnl", 0)
	await game_global.give_exp_to_pcs(
		maxi(1, int(payload.get("experience", 1))),
		selected
	)
	service_owner.call("_refresh_party_panels", selected)
	return {"leveledCharacterCount": selected.size()}


func _alter_selected_characters(payload: Dictionary) -> Dictionary:
	var selected: Array = service_owner.call("_current_selected_characters")
	var result: Dictionary = service_owner.call(
		"alter_selected_characters",
		payload,
		selected
	)
	if str(result.get("status", "")) != "error":
		service_owner.call("_refresh_party_panels", selected)
	return result


func _select_characters_by_identity(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call(
		"select_characters_by_identity",
		payload,
		service_owner.call("_party_characters"),
		service_owner.call("_classic_rule_names")
	)
	if str(result.get("status", "")) == "error":
		return result
	var selected: Array = result.get("selected", [])
	service_owner.call("_store_selected_characters", selected)
	return {
		"selectedCount": selected.size(),
		"checks": result.get("checks", []),
	}


func _check_party_misc(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	return service_owner.call(
		"party_misc_matches",
		payload,
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters"),
		service_owner.call("_classic_rule_names"),
		bool(game_global.camping) if game_global != null else false,
		bool(game_global.is_sailing_boat) if game_global != null else false
	)


func _select_characters_by_misc(payload: Dictionary) -> Dictionary:
	var resolved_payload := payload.duplicate(true)
	var selector := str(payload.get("selector", ""))
	if selector == "has_item" or selector == "wearing_item":
		var item_id: int = abs(int(payload.get("value", 0)))
		if item_id == 0:
			return _error("Classic item selector has no item ID")
		resolved_payload["itemIds"] = [item_id]
	var result: Dictionary = service_owner.call(
		"select_characters_by_misc",
		resolved_payload,
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters"),
		service_owner.call("_selected_character")
	)
	if str(result.get("status", "")) == "error":
		return result
	var selected: Array = result.get("selected", [])
	service_owner.call("_store_selected_characters", selected)
	return {
		"selectedCount": selected.size(),
		"checks": result.get("checks", []),
	}


func _change_selected_health(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call(
		"apply_selected_health_effect",
		payload,
		service_owner.call("_current_selected_characters")
	)
	return await service_owner.call("_finish_health_effect", payload, result)


func _change_party_health(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call(
		"apply_party_health_effect",
		payload,
		service_owner.call("_party_characters")
	)
	return await service_owner.call("_finish_health_effect", payload, result)


func _change_scenario_party_health(payload: Dictionary) -> Dictionary:
	var target_mode := str(payload.get("targetMode", "party"))
	if target_mode not in ["party", "selected"]:
		return _error("Scenario health change has an invalid target mode")
	var targets: Array = (
		service_owner.call("_current_selected_characters")
		if target_mode == "selected"
		else service_owner.call("_party_characters")
	)
	if targets.is_empty():
		return _error("Scenario health change has no eligible party members")
	var requested := int(payload.get("amount", 0))
	var can_kill := bool(payload.get("canKill", true))
	var hits: Array = []
	for character_value: Variant in targets:
		if not (character_value is Object) \
				or not character_value.has_method("change_cur_hp") \
				or not character_value.has_method("get_stat"):
			return _error("Scenario health target cannot receive a health change")
		var previous := int(character_value.call("get_stat", "curHP"))
		var applied := requested
		if not can_kill and applied < 0 and previous > 0:
			applied = maxi(applied, 1 - previous)
		character_value.call("change_cur_hp", applied)
		var current := int(character_value.call("get_stat", "curHP"))
		service_owner.call("_refresh_character_panel", character_value)
		hits.append({
			"id": str(character_value.get_instance_id()),
			"name": str(character_value.get("name")),
			"previousHealth": previous,
			"health": current,
			"amount": current - previous,
		})
	return {"hits": hits}


func _cast_classic_spell(payload: Dictionary) -> Dictionary:
	var target_mode := str(payload.get("targetMode", ""))
	if target_mode != "party" and target_mode != "selected":
		return _error("Classic spell command has an invalid target mode")
	var targets: Array = service_owner.call(
		"spell_effect_targets",
		target_mode,
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters")
	)
	if target_mode == "party":
		# Opcode 18 replaces Classic's transient picked set with the whole party.
		service_owner.call("_store_selected_characters", targets)
	if targets.is_empty():
		if target_mode == "selected":
			return {"targetCount": 0}
		return _error("Classic party spell command has no party members")
	return await service_owner.call(
		"_apply_classic_spell_to_targets",
		payload,
		targets
	)
