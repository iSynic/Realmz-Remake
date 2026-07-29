class_name ScenarioGodotCombatServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

var last_classic_spawn_presentation: Dictionary = {}
# Opcode 100 runs in a nested host while start_battle waits on this service.
# This one-shot carries its slot-8 result back to the suspended outer command.
var _forced_battle_resume_slot := -1


func _query_combat(_payload: Dictionary = {}) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return {
			"active": false,
			"round": 0,
			"combatants": [],
		}
	var snapshots: Array = []
	var combatants: Array = context["combatants"]
	for index: int in range(combatants.size()):
		var creature: Variant = service_owner.call(
			"_combatant_creature",
			combatants[index]
		)
		if not (creature is Object):
			continue
		var stats: Variant = creature.get("stats")
		if not (stats is Dictionary):
			stats = {}
		var current_health := int(stats.get("curHP", 0))
		snapshots.append({
			"id": "combat:%d" % index,
			"name": str(creature.get("name")),
			"level": int(creature.get("level")),
			"health": current_health,
			"maximumHealth": int(stats.get("maxHP", current_health)),
			"spellPoints": int(stats.get("curSP", 0)),
			"maximumSpellPoints": int(stats.get("maxSP", 0)),
			"alive": current_health > 0 and int(creature.get("life_status")) < 3,
		})
	return {
		"active": true,
		"round": int(context["state"].get("cur_battle_round")),
		"combatants": snapshots,
	}


func _apply_combat_damage(payload: Dictionary) -> Dictionary:
	return _change_combat_health(payload, -absi(int(payload.get("amount", 0))))


func _apply_combat_healing(payload: Dictionary) -> Dictionary:
	return _change_combat_health(payload, absi(int(payload.get("amount", 0))))


func _change_combat_health(payload: Dictionary, amount: int) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var target_id := str(payload.get("targetId", ""))
	if not target_id.begins_with("combat:") or not target_id.substr(7).is_valid_int():
		return _error("Scenario combat target reference is invalid")
	var target_index := int(target_id.substr(7))
	var combatants: Array = context["combatants"]
	if target_index < 0 or target_index >= combatants.size():
		return _error("Scenario combat target is unavailable")
	var creature: Variant = service_owner.call(
		"_combatant_creature",
		combatants[target_index]
	)
	if not (creature is Object) or not creature.has_method("change_cur_hp"):
		return _error("Scenario combat target cannot change health")
	var stats: Variant = creature.get("stats")
	var previous := int(stats.get("curHP", 0)) if stats is Dictionary else 0
	creature.call("change_cur_hp", amount)
	var current_stats: Variant = creature.get("stats")
	var current := int(current_stats.get("curHP", previous)) \
		if current_stats is Dictionary else previous
	return {
		"targetId": target_id,
		"amount": absi(current - previous),
		"previousHealth": previous,
		"health": current,
	}


func reset_campaign_state() -> void:
	last_classic_spawn_presentation.clear()
	_forced_battle_resume_slot = -1


func _give_battle_loot(_payload: Dictionary) -> Dictionary:
	# Native battle cleanup has already presented defeated-enemy rewards.
	return {}


func _check_combat_monster(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	return {
		"present": bool(service_owner.call(
			"combat_has_classic_monster",
			payload,
			context["combatants"]
		)),
	}


func _destroy_combat_monsters(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var selected: Array = service_owner.call(
		"select_classic_combatants",
		payload,
		context["combatants"]
	)
	var removed := int(service_owner.call(
		"remove_classic_combatants",
		context["state"],
		selected
	))
	if removed < 0:
		return _error("Realmz combat removal API is unavailable")
	return {"removed": removed}


func _deanimate_lower_undead(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var monster_ids: Variant = payload.get("monsterIds", [])
	if not (monster_ids is Array):
		return _error("Classic lower-undead command has an invalid monster list")
	var selected: Array = service_owner.call(
		"select_classic_combatants_by_ids",
		monster_ids,
		context["combatants"]
	)
	var removed := int(service_owner.call(
		"remove_classic_combatants",
		context["state"],
		selected
	))
	if removed < 0:
		return _error("Realmz combat removal API is unavailable")
	return {"removed": removed}


func _rout_combat_monsters(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.combat.rout-monsters":
		if service_owner.classic_bundle == null:
			return _error("Scenario monster catalog is unavailable")
		var monster_ids: Array = []
		var target_name_id := absi(
			int(routed_payload.get("monsterNameId", -1))
		)
		for monster_id_value: Variant in (
			service_owner.classic_bundle.monsters_by_id.keys()
		):
			var monster: Dictionary = (
				service_owner.classic_bundle.monsters_by_id[monster_id_value]
			)
			if absi(int(monster.get("monsterNameId", -1))) \
					== target_name_id:
				monster_ids.append(int(monster_id_value))
		monster_ids.sort()
		if monster_ids.size() > int(
			routed_payload.get("maxMatches", monster_ids.size())
		):
			monster_ids.resize(
				int(routed_payload.get("maxMatches", monster_ids.size()))
			)
		routed_payload["monsterIds"] = monster_ids
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var actor_faction: Variant = routed_payload.get("actorFaction")
	if actor_faction == null:
		actor_faction = service_owner.call(
			"_active_combat_faction",
			context["stateMachine"]
		)
	if actor_faction == null:
		return _error("Realmz active combat actor is unavailable")
	var monster_ids: Variant = routed_payload.get("monsterIds", [])
	if not (monster_ids is Array):
		return _error("Classic combat-rout command has an invalid monster list")
	var selected: Array = service_owner.call(
		"select_classic_combatants_by_ids_and_faction",
		monster_ids,
		int(actor_faction),
		context["combatants"]
	)
	var maximum := maxi(1, int(routed_payload.get(
		"maxMatches",
		selected.size()
	)))
	if selected.size() > maximum:
		selected.resize(maximum)
	var fleeing_trait: Variant = load(
		service_owner.PERMANENT_FLEEING_TRAIT_PATH
	)
	if not (fleeing_trait is Script):
		return _error("Realmz permanent fleeing trait is unavailable")
	var routed := int(service_owner.call(
		"apply_classic_rout",
		selected,
		fleeing_trait
	))
	if routed < 0:
		return _error("Realmz permanent fleeing trait is unavailable")
	return {"routed": routed}


func _spawn_combat_monsters(payload: Dictionary) -> Dictionary:
	last_classic_spawn_presentation.clear()
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.combat.spawn-monsters":
		if service_owner.classic_bundle == null:
			return _error("Scenario monster catalog is unavailable")
		var monster_id := int(routed_payload.get("monsterId", -1))
		var monster: Dictionary = (
			service_owner.classic_bundle.get_monster(monster_id)
		)
		if monster.is_empty():
			return _error(
				"Scenario combat monster %d is unavailable" % monster_id
			)
		routed_payload["monster"] = monster
		routed_payload["spawnCount"] = clampi(
			int(routed_payload.get("count", 1)),
			1,
			20
		)
		routed_payload["minDistance"] = 0
		routed_payload["maxDistance"] = maxi(
			0,
			int(routed_payload.get("radius", 4))
		)
		routed_payload["factionOverride"] = int(
			routed_payload.get("faction", 0)
		)
		routed_payload["inheritActorFaction"] = not routed_payload.has(
			"faction"
		)
		routed_payload["soundId"] = 0
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var game_global: Object = _autoload("GameGlobal")
	var node_access: Object = _autoload("NodeAccess")
	if game_global == null or node_access == null:
		return _error("Realmz combat spawn dependencies are unavailable")
	var resources: Object = node_access.__Resources()
	var map: Object = node_access.__Map()
	var creature_book: Variant = resources.get("crea_book") \
		if resources != null else null
	var creature_script: Variant = game_global.get("combatCreatureGD")
	var combatant_scene: Variant = service_owner.call(
		"_combatant_scene_resource"
	)
	if not (creature_book is Dictionary):
		return _error("Realmz bestiary resources are unavailable")
	var origin: Variant = service_owner.call(
		"_classic_spawn_origin",
		routed_payload,
		context["stateMachine"]
	)
	if not (origin is Vector2):
		return _error("Realmz combat spawn actor position is unavailable")
	var actor_faction: Variant = routed_payload.get("actorFaction")
	if bool(routed_payload.get(
		"inheritActorFaction",
		false
	)) and actor_faction == null:
		actor_faction = service_owner.call(
			"_active_combat_faction",
			context["stateMachine"]
		)
	if bool(routed_payload.get(
		"inheritActorFaction",
		false
	)) and actor_faction == null:
		return _error("Realmz combat spawn actor faction is unavailable")
	var result: Dictionary = service_owner.call(
		"spawn_classic_combatants",
		routed_payload,
		context["state"],
		map,
		creature_book,
		creature_script,
		combatant_scene,
		origin,
		actor_faction
	)
	if str(result.get("status", "")) == "error":
		return result
	var spawned_combatants: Variant = result.get("combatants", [])
	if not (spawned_combatants is Array):
		return _error("Classic combat spawn returned an invalid combatant list")
	if bool(routed_payload.get("skipPresentation", false)):
		result["presentation"] = {
			"style": "none",
			"animated": 0,
			"soundRepeats": 0,
			"events": [],
		}
		return result
	for combatant_value: Variant in spawned_combatants:
		if combatant_value is Object \
				and combatant_value.has_method("prepare_classic_spawn_animation"):
			combatant_value.prepare_classic_spawn_animation()
	var presentation_events: Array = []
	var animated_count := 0
	var sound_id := int(routed_payload.get("soundId", 0))
	for spawn_index: int in spawned_combatants.size():
		if sound_id != 0:
			service_owner.call("_play_sound", {"soundId": sound_id})
			presentation_events.append({
				"spawnIndex": spawn_index,
				"event": "sound",
				"soundId": sound_id,
			})
		var combatant: Variant = spawned_combatants[spawn_index]
		if combatant is Object \
				and combatant.has_method("play_classic_spawn_animation"):
			var animation_finished: Variant = \
				combatant.play_classic_spawn_animation()
			if animation_finished is Signal:
				await animation_finished
			animated_count += 1
			presentation_events.append({
				"spawnIndex": spawn_index,
				"event": "conjuration",
			})
	var presentation := {
		"style": "classic-conjuration",
		"animated": animated_count,
		"soundRepeats": int(result.get("spawned", 0)) if sound_id != 0 else 0,
		"events": presentation_events,
	}
	result["presentation"] = presentation
	last_classic_spawn_presentation = presentation.duplicate(true)
	return result


func _revive_classic_combatants(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var party: Array = service_owner.call("_party_characters")
	if party.is_empty():
		return _error("Classic combat revival has no party members")
	var living_party := 0
	for character_value: Variant in party:
		if bool(service_owner.call("_is_living_character", character_value)):
			living_party += 1
	if living_party == 0:
		var origin: Variant = payload.get("actorPosition", Vector2.ZERO)
		if origin is Vector2i:
			origin = Vector2(origin)
		elif not (origin is Vector2):
			origin = Vector2.ZERO
		var revived: Dictionary = service_owner.call(
			"revive_classic_party",
			party,
			context["state"],
			context["combatants"],
			origin
		)
		if str(revived.get("status", "")) == "error":
			return revived
		service_owner.call("_refresh_party_panels", party)
		return revived

	var actor_monster_id := int(payload.get("actorMonsterId", -1))
	var monster: Variant = payload.get("monster", {})
	if actor_monster_id < 0 \
			or not (monster is Dictionary) \
			or monster.is_empty():
		return _error("Classic NPC revival is missing its dead monster record")
	var revived_monster: Dictionary = monster.duplicate(true)
	revived_monster["traitor"] = 0
	var spawn_payload := {
		"monsterId": actor_monster_id,
		"monster": revived_monster,
		"spawnCount": 1,
		"actorPosition": payload.get("actorPosition"),
		"soundId": 0,
		"skipPresentation": true,
	}
	var spawn_result := await _spawn_combat_monsters(spawn_payload)
	if str(spawn_result.get("status", "")) == "error":
		return spawn_result
	spawn_result["npcRevived"] = int(spawn_result.get("spawned", 0))
	return spawn_result


func _revive_scenario_party(_payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var party: Array = service_owner.call("_party_characters")
	if party.is_empty():
		return _error("Scenario combat revival has no party members")
	var revived: Dictionary = service_owner.call(
		"revive_classic_party",
		party,
		context["state"],
		context["combatants"],
		Vector2.ZERO
	)
	if str(revived.get("status", "")) != "error":
		revived["revived"] = int(revived.get("partyRevived", 0))
		service_owner.call("_refresh_party_panels", party)
	return revived


func _alter_classic_combatants(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	return service_owner.call(
		"alter_classic_combatants",
		payload,
		context["combatants"]
	)


func _fumble_active_combatant(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var active_combatant: Variant = service_owner.call(
		"_active_combatant",
		context["stateMachine"]
	)
	if active_combatant == null:
		return _error("Realmz active combat actor is unavailable")
	service_owner.call("_play_sound", payload)
	var message: Variant = payload.get("message", {})
	if message is Dictionary and not str(message.get("text", "")).is_empty():
		var text_result: Dictionary = await service_owner.call(
			"_show_text",
			payload
		)
		if str(text_result.get("status", "")) == "error":
			return text_result
	var result: Dictionary = service_owner.call(
		"fumble_classic_combatant",
		context["state"],
		active_combatant
	)
	if bool(result.get("fumbled", false)):
		for sound_id: int in result.get("dropSoundIds", []):
			service_owner.call("_play_sound", {"soundId": sound_id})
	return result


func _activate_battle_round_macro(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var battle_data: Variant = context["state"].get("cur_battle_data")
	if not bool(service_owner.call(
		"apply_battle_round_macro_schedule",
		battle_data,
		bool(payload.get("disableSchedule", false))
	)):
		return _error("Realmz battle-round schedule is unavailable")
	return {"targetMacroId": int(payload.get("targetMacroId", -1))}


func _end_classic_battle(payload: Dictionary) -> Dictionary:
	var context: Dictionary = service_owner.call("_combat_context")
	if context.has("error"):
		return _error(str(context["error"]))
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null or not game_global.has_method("end_battle"):
		return _error("Realmz battle completion API is unavailable")
	var resume_slot := int(payload.get("resumeSlot", -1))
	if not _record_forced_battle_resume_slot(resume_slot):
		return _error("Classic forced battle resume slot must be 8")
	var outcome := str(payload.get("outcome", "won"))
	var reward_mode := str(payload.get("rewardMode", "normal"))
	await game_global.call("end_battle", outcome, reward_mode)
	return {"outcome": outcome, "resumeSlot": resume_slot}


func _start_classic_battle(payload: Dictionary) -> Dictionary:
	_forced_battle_resume_slot = -1
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() \
		if node_access != null else null
	var game_global: Object = _autoload("GameGlobal")
	if resources == null or game_global == null:
		return _error("Realmz battle resources are unavailable")
	var battle_id_result: Dictionary = service_owner.call(
		"resolve_classic_battle_id",
		payload
	)
	if str(battle_id_result.get("status", "")) == "error":
		return battle_id_result
	var battle_id := int(battle_id_result["battleId"])
	var resource_result: Dictionary = service_owner.call(
		"ensure_classic_battle_resource",
		battle_id,
		resources.battles_book,
		resources.crea_book
	)
	if str(resource_result.get("status", "")) == "error":
		return resource_result
	var request: Dictionary = service_owner.call(
		"build_classic_battle_request",
		payload,
		resources.battles_book,
		service_owner.call("_party_characters"),
		service_owner.call("_current_selected_characters"),
		battle_id
	)
	if str(request.get("status", "")) == "error":
		return request

	service_owner.call("_play_sound", payload)
	var message: Variant = payload.get("message", {})
	if int(payload.get("messageId", 0)) != 0 \
			and message is Dictionary \
			and not str(message.get("text", "")).is_empty():
		var text_result: Dictionary = await service_owner.call(
			"_show_text",
			payload
		)
		if str(text_result.get("status", "")) == "error":
			return text_result
	if bool(request.get("noBattle", false)):
		return {
			"battleId": int(request.get("battleId", 0)),
			"battleStarted": false,
			"outcome": "lost",
			"coward": true,
			"survivorCount": 0,
		}

	game_global.allow_next_battle_loot = bool(request["allowLoot"])
	var battle_overrides: Dictionary = service_owner.call(
		"build_existing_classic_battle_overrides",
		battle_id,
		resources.battles_book,
		resources.crea_book
	)
	battle_overrides["classicBattleId"] = battle_id
	battle_overrides["classicPriestTurningEnabled"] = bool(
		payload.get("priestTurningEnabled", true)
	)
	game_global.start_battle(
		str(request["battleName"]),
		"",
		true,
		bool(request["surprise"]),
		bool(request["allowLoss"]),
		true,
		true,
		request["participants"],
		battle_overrides
	)
	var outcome_value: Variant = await game_global.battle_end
	# GameGlobal restores the exploration actor after emitting battle_end.
	# Resume Classic afterward so a following position change is not overwritten.
	await game_global.get_tree().process_frame
	var outcome := str(outcome_value)
	var survivor_count := 0
	for character_value: Variant in request["participants"]:
		if bool(service_owner.call("_is_living_character", character_value)):
			survivor_count += 1
	var response := {
		"battleId": int(request["battleId"]),
		"battleStarted": true,
		"outcome": outcome,
		"coward": outcome != "won",
		"survivorCount": survivor_count,
	}
	var forced_resume_slot := _take_forced_battle_resume_slot()
	if forced_resume_slot >= 0:
		response["forcedResumeSlot"] = forced_resume_slot
	return response


func _present_priest_turning(payload: Dictionary) -> Dictionary:
	if str(payload.get("_scenarioApiOperation", "")) \
			== "core.combat.priest-turning":
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			runtime_state.set_priest_turning_enabled(
				bool(payload.get("enabled", true))
			)
	service_owner.call("_play_sound", payload)
	return await service_owner.call("_show_text", payload)


func _apply_coward_penalty(payload: Dictionary) -> Dictionary:
	var text_rect: Object = service_owner.call("_text_rect")
	if text_rect == null:
		return _error(
			"Realmz HUD TextRect is unavailable for the Classic coward penalty"
		)

	await text_rect.set_text(
		service_owner.CLASSIC_COWARD_RETREAT_MESSAGE,
		true
	)
	var sound_result: Dictionary = service_owner.call("_play_sound", payload)
	await text_rect.set_text(
		service_owner.CLASSIC_COWARD_EXPERIENCE_MESSAGE,
		true
	)

	var party: Array = service_owner.call("_party_characters")
	var result: Dictionary = service_owner.call(
		"apply_classic_coward_experience_penalty",
		party,
		int(payload.get("experiencePerLevel", 0))
	)
	service_owner.call("_refresh_party_panels", party)
	result["warningIds"] = payload.get("warningIds", []).duplicate()
	result["soundResult"] = sound_result
	if bool(payload.get("backUpParty", false)):
		var retreat_result: Dictionary = service_owner.call(
			"retreat_classic_party",
			_autoload("GameGlobal"),
			payload.get("entryMovement")
		)
		for retreat_key: Variant in retreat_result:
			result[retreat_key] = retreat_result[retreat_key]
	else:
		result["partyBackedUp"] = false
		result["backUpReason"] = \
			"Classic does not retreat the party in dungeons"
	return result


func _record_forced_battle_resume_slot(resume_slot: int) -> bool:
	if resume_slot != 8:
		return false
	_forced_battle_resume_slot = resume_slot
	return true


func _take_forced_battle_resume_slot() -> int:
	var resume_slot := _forced_battle_resume_slot
	_forced_battle_resume_slot = -1
	return resume_slot
