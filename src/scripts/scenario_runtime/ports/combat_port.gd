class_name CombatPort
extends DelegatingScenarioPort

const COMMANDS := [
	"query_combat",
	"query_monster_definition",
	"query_battle_definition",
	"apply_combat_damage",
	"apply_combat_healing",
	"apply_combat_condition",
	"start_battle",
	"check_combat_monster",
	"destroy_combat_monsters",
	"deanimate_lower_undead",
	"rout_combat_monsters",
	"spawn_combat_monsters",
	"revive_classic_combatants",
	"alter_classic_combatants",
	"fumble_active_combatant",
	"activate_battle_round_macro",
	"end_classic_battle",
	"set_priest_turning",
	"give_battle_loot",
	"apply_coward_penalty",
]
const OPERATIONS := {
	"query_combat": "_query_combat",
	"query_monster_definition": "_query_monster_definition",
	"query_battle_definition": "_query_battle_definition",
	"apply_combat_damage": "_apply_combat_damage",
	"apply_combat_healing": "_apply_combat_healing",
	"apply_combat_condition": "_apply_combat_condition",
	"start_battle": "_start_classic_battle",
	"check_combat_monster": "_check_combat_monster",
	"destroy_combat_monsters": "_destroy_combat_monsters",
	"deanimate_lower_undead": "_deanimate_lower_undead",
	"rout_combat_monsters": "_rout_combat_monsters",
	"spawn_combat_monsters": "_spawn_combat_monsters",
	"revive_classic_combatants": "_revive_classic_combatants",
	"alter_classic_combatants": "_alter_classic_combatants",
	"fumble_active_combatant": "_fumble_active_combatant",
	"activate_battle_round_macro": "_activate_battle_round_macro",
	"end_classic_battle": "_end_classic_battle",
	"set_priest_turning": "_present_priest_turning",
	"give_battle_loot": "_give_battle_loot",
	"apply_coward_penalty": "_apply_coward_penalty",
}


func port_id() -> String:
	return "core.combat"


func service_operation(command_id: String) -> String:
	return str(OPERATIONS.get(command_id, ""))


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func has_monster_ai_behavior(monster: Object) -> bool:
	var target_ids := _monster_target_ids(monster)
	if target_ids.is_empty() or behavior_runner == null \
			or not behavior_runner.has_method("has_behavior_attachments"):
		return false
	return bool(behavior_runner.call(
		"has_behavior_attachments",
		"monster-ai",
		"decision",
		"monster",
		target_ids
	))


func run_monster_ai_behavior(monster: Object) -> Dictionary:
	var target_ids := _monster_target_ids(monster)
	if target_ids.is_empty():
		return {"handled": false}
	var combat_snapshot: Dictionary = {}
	if _port_runtime != null and _port_runtime.has_method("_query_combat"):
		var snapshot_value: Variant = _port_runtime.call("_query_combat", {})
		if snapshot_value is Dictionary:
			combat_snapshot = snapshot_value.duplicate(true)
	var request := {
		"monster": _monster_snapshot(monster),
		"combat": combat_snapshot,
	}
	var attachment_result := await invoke_behavior_attachments(
		"monster-ai",
		"decision",
		"monster",
		target_ids,
		request
	)
	if str(attachment_result.get("status", "")) == "error" \
			or bool(attachment_result.get("handled", false)):
		return attachment_result
	return await invoke_runtime_binding(
		"monsterAi",
		"monsterAiProviders",
		target_ids,
		request
	)


static func _monster_target_ids(monster: Object) -> Array:
	if monster == null:
		return []
	var target_ids: Array = []
	for value: Variant in [
		monster.get("classic_monster_id"),
		monster.get("classic_monster_name_id"),
		monster.get("bestiary_key"),
		monster.get("name"),
	]:
		var id_text := str(value)
		if not id_text.is_empty() and id_text != "-1" and not target_ids.has(id_text):
			target_ids.append(id_text)
	return target_ids


static func _monster_snapshot(monster: Object) -> Dictionary:
	if monster == null:
		return {}
	var stats: Variant = monster.get("stats")
	if not (stats is Dictionary):
		stats = {}
	var position_value: Variant = monster.get("position")
	var position: Vector2 = position_value if position_value is Vector2 else Vector2.ZERO
	return {
		"id": str(monster.get("classic_monster_id")),
		"name": str(monster.get("name")),
		"health": int(stats.get("curHP", 0)),
		"maximumHealth": int(stats.get("maxHP", 0)),
		"spellPoints": int(stats.get("curSP", 0)),
		"maximumSpellPoints": int(stats.get("maxSP", 0)),
		"position": {"x": int(position.x), "y": int(position.y)},
		"faction": int(monster.get("curFaction")),
		"alive": int(stats.get("curHP", 0)) > 0,
	}


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	var scenario_operation := str(
		routed_request.get("_scenarioApiOperation", "")
	)
	if scenario_operation == "core.encounter.start-battle":
		var battle_id := int(routed_request.get("battleId", 0))
		routed_request["battleIdRange"] = [battle_id, battle_id]
		routed_request["participantMode"] = "party"
		routed_request["surprise"] = false
		routed_request["lootMode"] = 0
		routed_request["soundId"] = 0
		routed_request["priestTurningEnabled"] = true
	if scenario_operation == "core.combat.destroy-monsters":
		routed_request["maxMatches"] = maxi(
			1,
			int(routed_request.get("maximum", 100))
		)
	if scenario_operation == "core.combat.rout-monsters":
		routed_request["maxMatches"] = maxi(
			1,
			int(routed_request.get("maximum", 100))
		)
		routed_request["surrenderPercent"] = clampi(
			int(routed_request.get("surrenderPercent", 50)),
			0,
			100
		)
	if scenario_operation == "core.combat.revive":
		if _port_runtime == null \
				or not _port_runtime.has_method("_revive_scenario_party"):
			return {
				"status": "error",
				"message": "Scenario combat revival service is unavailable",
			}
		return await _port_runtime.call(
			"_revive_scenario_party",
			routed_request
		)
	if scenario_operation == "core.combat.priest-turning":
		routed_request["soundId"] = 0
		routed_request["messageId"] = 0
		routed_request["message"] = {
			"id": 0,
			"text": (
				"Priest turning is now enabled."
				if bool(routed_request.get("enabled", true))
				else "Priest turning is now disabled."
			),
		}
	if scenario_operation == "core.combat.end-battle":
		routed_request["rewardMode"] = str(
			routed_request.get("rewardMode", "normal")
		)
		routed_request["resumeSlot"] = 8
	if scenario_operation == "core.combat.fumble":
		routed_request["message"] = {
			"id": 0,
			"text": str(routed_request.get("message", "")),
		}
		routed_request["soundId"] = int(routed_request.get("soundId", 0))
	if scenario_operation == "core.combat.change-monsters":
		var target_type := str(routed_request.get("targetType", ""))
		if target_type not in ["ally", "monster"]:
			return {
				"status": "error",
				"message": "Scenario combatant change target must be ally or monster",
			}
		if not routed_request.has("faction") \
				and not routed_request.has("iconId"):
			return {
				"status": "error",
				"message": "Scenario combatant change requires a faction or icon",
			}
		routed_request["maxMatches"] = clampi(
			int(routed_request.get("maximum", 1)),
			1,
			20
		)
		routed_request["faction"] = int(routed_request.get("faction", -1))
		routed_request["iconId"] = int(routed_request.get("iconId", -1))
	if command_id in ["apply_combat_damage", "apply_combat_healing"]:
		var family := (
			"damage" if command_id == "apply_combat_damage" else "healing"
		)
		var modifier_result := await apply_rule_modifiers(
			family,
			float(routed_request.get("amount", 0)),
			{
				"minimum": 0.0,
				"commandId": command_id,
				"request": routed_request.duplicate(true),
			}
		)
		if str(modifier_result.get("status", "")) != "ok":
			return modifier_result
		routed_request["amount"] = maxi(
			0,
			roundi(float(modifier_result.get("value", 0)))
		)
	if command_id == "activate_battle_round_macro" \
			and not bool(rule_option("combat", "battleMacros", true)):
		return {
			"status": "ok",
			"skipped": true,
			"reason": "gameplay-rules",
		}
	if command_id == "rout_combat_monsters" \
			and not bool(rule_option("combat", "classicMorale", true)):
		return {
			"status": "ok",
			"skipped": true,
			"reason": "gameplay-rules",
		}
	var extension_result := await invoke_runtime_binding(
		"monsterAi",
		"monsterAiProviders",
		[
			request.get("monsterDefinitionId", ""),
			routed_request.get("monsterId", ""),
			routed_request.get("monsterNameId", ""),
		],
		routed_request
	)
	if bool(extension_result.get("handled", false)):
		return extension_result
	return await super.execute(command_id, routed_request)
