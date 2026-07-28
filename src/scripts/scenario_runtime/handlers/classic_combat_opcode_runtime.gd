class_name ClassicCombatOpcodeRuntime
extends RefCounted

const PRIEST_TURNING_ENABLED_MESSAGE := \
	"You regain your ability to turn undead and nether spawn."
const PRIEST_TURNING_DISABLED_MESSAGE := \
	"You may not use your ability to turn undead or nether spawn."
const NO_SELECTIVE_BATTLE_SURVIVORS_MESSAGE := \
	"There is nobody left to collect any treasure."

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_battle(coward: bool) -> Dictionary:
	if runtime.pending_battle.is_empty():
		return _result(
			"_error_result",
			["No classic battle is waiting for an outcome"]
		)
	var battle_context: Dictionary = runtime.pending_battle
	runtime.pending_battle = {}
	if not coward:
		return _result("_yield_result", [
			"give_battle_loot",
			{
				"extraCodeId": int(battle_context["extraCodeId"]),
				"lootMode": 0,
			},
		])

	var coward_macro_id := int(battle_context["cowardMacroId"])
	if coward_macro_id == -1:
		runtime.call("_clear_control_flow")
		var state: ClassicRuntimeState = runtime.runtime_state
		return _result("_yield_result", [
			"apply_coward_penalty",
			{
				"experiencePerLevel": 2000,
				"soundId": 26260,
				"warningIds": [118, 124],
				"levelType": state.level_type,
				"backUpParty": state.level_type == "land",
			},
		])
	var branch_result := _result("_branch_to_extra_action_point", [
		coward_macro_id,
		bool(battle_context.get("gosub", false)),
		0,
	])
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func resume_selective_battle(survivor_count: int) -> Dictionary:
	if runtime.pending_selective_battle.is_empty():
		return _result(
			"_error_result",
			["No classic selective battle is waiting for an outcome"]
		)
	if survivor_count < 0:
		return _result(
			"_error_result",
			["Classic selective battle returned an invalid survivor count"]
		)
	var battle_context: Dictionary = runtime.pending_selective_battle
	runtime.pending_selective_battle = {}
	if survivor_count == 0:
		return _result("_yield_result", [
			"show_text",
			{
				"messageId": 0,
				"message": {
					"id": 0,
					"text": NO_SELECTIVE_BATTLE_SURVIVORS_MESSAGE,
				},
			},
		])
	var treasure_id := int(battle_context.get("treasureId", 0))
	if treasure_id != 0:
		return _result("_execute_treasure", [treasure_id])
	return _run()


func resume_forced_battle_end() -> Dictionary:
	runtime.call("_clear_control_flow")
	return _result("_completed_result", ["battle-ended"])


func resume_forced_battle_at_slot(resume_slot: int) -> Dictionary:
	if resume_slot != 8:
		return _result(
			"_error_result",
			["Classic forced battle resume slot must be 8"]
		)
	runtime.pending_battle = {}
	runtime.pending_selective_battle = {}
	runtime.call("_set_cursor", runtime.current_trigger, resume_slot)
	return _run()


func resume_combat_monster_check(present: bool) -> Dictionary:
	if runtime.pending_combat_monster_check.is_empty():
		return _result(
			"_error_result",
			["No classic combat-monster check is waiting for a response"]
		)
	runtime.pending_combat_monster_check = {}
	if present:
		return _run()
	runtime.call("_clear_control_flow")
	return _result(
		"_completed_result",
		["required-combat-monster-absent"]
	)


func resume_combat_revival(party_revived: bool) -> Dictionary:
	if runtime.pending_combat_revival.is_empty():
		return _result(
			"_error_result",
			["No classic combat revival is waiting for a response"]
		)
	runtime.pending_combat_revival = {}
	if party_revived:
		runtime.call("_clear_control_flow")
		return _result("_completed_result", ["party-revived"])
	return _run()


func resume_battle_round_macro() -> Dictionary:
	if runtime.pending_battle_round_macro.is_empty():
		return _result(
			"_error_result",
			["No classic battle-round macro is waiting for activation"]
		)
	var target_macro_id := int(
		runtime.pending_battle_round_macro["targetMacroId"]
	)
	runtime.pending_battle_round_macro = {}
	var branch_result := _result(
		"_branch_to_extra_action_point",
		[target_macro_id, false, 0]
	)
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func _execute_combat_monster_check(monster_name_id: int) -> Dictionary:
	runtime.pending_combat_monster_check = {
		"monsterNameId": abs(monster_name_id),
	}
	return _result("_yield_result", [
		"check_combat_monster",
		{"monsterNameId": abs(monster_name_id)},
	])


func _execute_combat_revival() -> Dictionary:
	runtime.pending_combat_revival = {"active": true}
	var context: Dictionary = runtime.execution_context
	var actor_monster_id := int(context.get("actorMonsterId", -1))
	var payload := {
		"actorMonsterId": actor_monster_id,
		"actorMonsterNameId": int(context.get("actorMonsterNameId", -1)),
		"actorPosition": context.get("actorPosition"),
		"actorFaction": int(context.get("actorFaction", 0)),
	}
	if actor_monster_id >= 0:
		payload["monster"] = _bundle().get_monster(actor_monster_id)
	return _result("_yield_result", [
		"revive_classic_combatants",
		payload,
	])


func _execute_combatant_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Combatant mutation references missing Extra Code row %d"
			% extra_code_id
		)
	var target_type := int(values[0])
	if target_type not in [1, 2]:
		return _halt(
			"Combatant mutation has invalid target type %d" % target_type
		)
	return _result("_yield_result", [
		"alter_classic_combatants",
		{
			"extraCodeId": extra_code_id,
			"targetType": "ally" if target_type == 1 else "monster",
			"monsterNameId": int(values[1]),
			"maxMatches": maxi(0, int(values[2])),
			"iconId": int(values[3]),
			"faction": int(values[4]),
		},
	])


func _execute_combat_fumble(extra_code_id: int) -> Dictionary:
	var values: Array = [0, 0, 0, 0, 0]
	if extra_code_id != 0:
		values = _values(extra_code_id)
		if values.is_empty():
			return _halt(
				"Combat fumble references missing Extra Code row %d"
				% extra_code_id
			)
	var message_id := int(values[0])
	return _result("_yield_result", [
		"fumble_active_combatant",
		{
			"extraCodeId": extra_code_id,
			"messageId": message_id,
			"message": _bundle().get_message(message_id) \
				if message_id != 0 else {},
			"soundId": int(values[1]),
		},
	])


func _execute_destroy_combat_monsters(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Destroy-combat-monsters action references missing Extra Code row %d"
			% extra_code_id
		)
	var monster_name_id := int(values[0])
	var max_matches := int(values[1])
	if max_matches == 0:
		max_matches = 100
	return _result("_yield_result", [
		"destroy_combat_monsters",
		{
			"extraCodeId": extra_code_id,
			"monsterNameId": monster_name_id,
			"maxMatches": max_matches,
			"includeAllFactions": int(values[4]) != 0,
		},
	])


func _execute_deanimate_lower_undead(extra_code_id: int) -> Dictionary:
	var monster_ids: Array = []
	for monster_value: Variant in _bundle().monsters_by_id.values():
		if not (monster_value is Dictionary):
			continue
		var type_flags: Variant = monster_value.get("typeFlags", [])
		if not (type_flags is Array) or type_flags.size() <= 5:
			continue
		if int(type_flags[1]) == 0 or int(type_flags[5]) != 0:
			continue
		monster_ids.append(int(monster_value.get("id", -1)))
	monster_ids.sort()
	return _result("_yield_result", [
		"deanimate_lower_undead",
		{
			"extraCodeId": extra_code_id,
			"monsterIds": monster_ids,
		},
	])


func _execute_combat_rout(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Combat-rout action references missing Extra Code row %d"
			% extra_code_id
		)
	var monster_ids: Array = []
	var monsters: Array = []
	for value: Variant in values:
		var monster_id := int(value)
		if monster_id == 0 or monster_ids.has(monster_id):
			continue
		monster_ids.append(monster_id)
		monsters.append(_bundle().get_monster(monster_id))
	var payload := {
		"extraCodeId": extra_code_id,
		"monsterIds": monster_ids,
		"monsters": monsters,
		"sameFactionAsActor": true,
		"permanent": true,
		"surrenderPercent": 50,
	}
	var context: Dictionary = runtime.execution_context
	if context.has("actorFaction"):
		payload["actorFaction"] = context["actorFaction"]
	return _result("_yield_result", ["rout_combat_monsters", payload])


func _execute_spawn_combat_monsters(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Combat spawn action references missing Extra Code row %d"
			% extra_code_id
		)
	var authored_count := int(values[2])
	var spawn_count := randi_range(1, abs(authored_count)) \
		if authored_count < 0 else authored_count
	if spawn_count <= 0:
		return _result("_continue_result")
	var monster_id := int(values[1])
	var monster := _bundle().get_monster(monster_id)
	if monster.is_empty():
		return _halt("Missing combat spawn monster %d" % monster_id)
	# Classic cannot create a viable combatant from an empty Data MD slot.
	if monster.has("hitDice") and int(monster.get("hitDice", 0)) <= 0:
		return _result("_continue_result")
	var faction_override := int(values[4])
	var context: Dictionary = runtime.execution_context
	var queued_macro := bool(context.get("queuedMacro", false))
	var battle_macro := int(context.get("battleMacro", 0))
	var payload := {
		"extraCodeId": extra_code_id,
		"monsterId": monster_id,
		"monster": monster,
		"authoredCount": authored_count,
		"spawnCount": spawn_count,
		"soundId": int(values[3]),
		"factionOverride": faction_override,
		"inheritActorFaction": (
			faction_override == 0
			and (queued_macro or battle_macro == 0)
		),
	}
	for context_key: String in ["actorPosition", "actorFaction"]:
		if context.has(context_key):
			payload[context_key] = context[context_key]
	return _result("_yield_result", ["spawn_combat_monsters", payload])


func _execute_battle_round_macro(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Battle-round macro action references missing Extra Code row %d"
			% extra_code_id
		)
	var context: Dictionary = runtime.execution_context
	if int(context.get("battleMacro", -1)) > 0:
		runtime.call("_clear_control_flow")
		return _result(
			"_completed_result",
			["legacy-battle-macro-disabled"]
		)
	if not context.has("combatRound"):
		return _halt("Battle-round macro requires the current combat round")
	var combat_round := int(context["combatRound"])
	if combat_round < 1:
		return _halt(
			"Battle-round macro requires a one-based combat round"
		)
	var round_index := combat_round - 1
	var trigger_mode := int(values[0])
	var trigger_value := int(values[1])
	var chance_roll := -1
	var activates := true
	if trigger_mode == 1:
		chance_roll = int(runtime.call("_roll_percent"))
		activates = chance_roll <= trigger_value
	elif trigger_mode == 0:
		activates = round_index == trigger_value
	if not activates:
		runtime.call("_clear_control_flow")
		return _result(
			"_completed_result",
			["battle-round-macro-skipped"]
		)

	var target_mode := int(values[2])
	var first_target := int(values[3])
	var last_target := int(values[4]) if target_mode == 2 else first_target
	if last_target < first_target:
		return _halt(
			"Battle-round macro target range %d-%d is reversed"
			% [first_target, last_target]
		)
	var target_macro_id := randi_range(first_target, last_target)
	if _bundle().get_extra_action_point(target_macro_id).is_empty():
		return _halt(
			"Missing battle-round target macro %d" % target_macro_id
		)
	runtime.pending_battle_round_macro = {
		"targetMacroId": target_macro_id,
	}
	return _result("_yield_result", [
		"activate_battle_round_macro",
		{
			"extraCodeId": extra_code_id,
			"combatRound": combat_round,
			"roundIndex": round_index,
			"triggerMode": trigger_mode,
			"triggerValue": trigger_value,
			"chanceRoll": chance_roll,
			"repeat": target_mode == 1,
			"randomTarget": target_mode == 2,
			"targetRange": [first_target, last_target],
			"targetMacroId": target_macro_id,
			"disableSchedule": target_mode != 1,
		},
	])


func _execute_battle(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Battle action references missing Extra Code row %d" % extra_code_id
		)
	var first_battle_id := int(values[0])
	var last_battle_id := int(values[1]) \
		if int(values[1]) != 0 else first_battle_id
	var bundle := _bundle()
	return _result("_yield_result", [
		"start_battle",
		{
			"extraCodeId": extra_code_id,
			"battleIdRange": [abs(first_battle_id), abs(last_battle_id)],
			"surprise": first_battle_id < 0,
			"soundId": int(values[2]),
			"messageId": int(values[3]),
			"message": bundle.get_message(int(values[3])),
			"lootMode": int(values[4]),
			"battle": bundle.get_battle(first_battle_id),
			"priestTurningEnabled": \
				runtime.runtime_state.priest_turning_enabled,
		},
	])


func _execute_selective_battle(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Selective battle action references missing Extra Code row %d"
			% extra_code_id
		)
	var first_battle_id := int(values[0])
	var last_battle_id := int(values[1]) \
		if int(values[1]) != 0 else first_battle_id
	runtime.pending_selective_battle = {
		"extraCodeId": extra_code_id,
		"treasureId": int(values[4]),
	}
	var bundle := _bundle()
	return _result("_yield_result", [
		"start_battle",
		{
			"extraCodeId": extra_code_id,
			"battleIdRange": [abs(first_battle_id), abs(last_battle_id)],
			"surprise": first_battle_id < 0,
			"soundId": int(values[2]),
			"messageId": int(values[3]),
			"message": bundle.get_message(int(values[3])),
			"lootMode": 0,
			"treasureId": int(values[4]),
			"battle": bundle.get_battle(first_battle_id),
			"priestTurningEnabled": \
				runtime.runtime_state.priest_turning_enabled,
			"participantMode": "selected",
		},
	])


func _execute_priest_turning(enabled: bool) -> Dictionary:
	runtime.runtime_state.set_priest_turning_enabled(enabled)
	var message := PRIEST_TURNING_ENABLED_MESSAGE if enabled \
		else PRIEST_TURNING_DISABLED_MESSAGE
	return _result("_yield_result", [
		"set_priest_turning",
		{
			"enabled": enabled,
			"soundId": 20004 if enabled else 10105,
			"messageId": 0,
			"message": {"id": 0, "text": message},
		},
	])


func _execute_battle_outcome(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Battle outcome branch references missing Extra Code row %d"
			% extra_code_id
		)
	var first_battle_id := int(values[0])
	var last_battle_id := int(values[1]) \
		if int(values[1]) != 0 else first_battle_id
	runtime.pending_battle = {
		"extraCodeId": extra_code_id,
		"cowardMacroId": int(values[2]),
		"gosub": gosub,
	}
	var bundle := _bundle()
	return _result("_yield_result", [
		"start_battle",
		{
			"extraCodeId": extra_code_id,
			"battleIdRange": [abs(first_battle_id), abs(last_battle_id)],
			"soundId": int(values[3]),
			"messageId": int(values[4]),
			"message": bundle.get_message(int(values[4])),
			"lootMode": 0,
			"battle": bundle.get_battle(first_battle_id),
			"priestTurningEnabled": \
				runtime.runtime_state.priest_turning_enabled,
			"outcomeBranch": true,
			"cowardMacroId": int(values[2]),
		},
	])


func _execute_improved_selective_battle(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Improved selective battle references missing Extra Code row %d"
			% extra_code_id
		)
	var first_battle_id := int(values[0])
	var last_battle_id := int(values[1]) \
		if int(values[1]) != 0 else first_battle_id
	runtime.pending_battle = {
		"extraCodeId": extra_code_id,
		"cowardMacroId": int(values[4]),
		"gosub": gosub,
	}
	var bundle := _bundle()
	return _result("_yield_result", [
		"start_battle",
		{
			"extraCodeId": extra_code_id,
			"battleIdRange": [abs(first_battle_id), abs(last_battle_id)],
			"soundId": int(values[2]),
			"messageId": int(values[3]),
			"message": bundle.get_message(int(values[3])),
			"lootMode": 0,
			"battle": bundle.get_battle(first_battle_id),
			"priestTurningEnabled": \
				runtime.runtime_state.priest_turning_enabled,
			"participantMode": "selected",
			"outcomeBranch": true,
			"cowardMacroId": int(values[4]),
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
			"message": "Classic combat runtime requires '%s'" % method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic combat operation '%s' returned invalid state" \
			% method_name,
	}
