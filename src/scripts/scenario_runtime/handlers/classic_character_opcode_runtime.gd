class_name ClassicCharacterOpcodeRuntime
extends RefCounted

const KnownDataCorrectionsScript = preload(
	"res://scripts/classic_runtime/classic_known_data_corrections.gd"
)
const PARTY_CONDITION_NAMES := [
	"Torch Lit",
	"Waterworld",
	"Dragon Hide",
	"Discover Secret",
	"Wizard Eye",
	"Search",
	"Free Fall",
	"Sentry",
	"Charm Resistance",
	"Unused",
]

var runtime: Object


func configure(owner: Object) -> void:
	runtime = owner


func resume_party_condition_check(active: bool) -> Dictionary:
	if runtime.pending_party_condition_check.is_empty():
		return _result(
			"_error_result",
			["No classic party-condition check is waiting for a response"]
		)
	var condition_check: Dictionary = runtime.pending_party_condition_check
	runtime.pending_party_condition_check = {}
	var values: Array = condition_check["values"]
	var required_state := int(values[0])
	var should_branch := (required_state == 1 and active) \
		or (required_state == 2 and not active)
	if not should_branch:
		return _run()
	var branch_mode := int(values[1])
	if branch_mode < 1 or branch_mode > 3:
		runtime.call("_set_cursor", runtime.current_trigger, 8)
		return _run()
	var branch_result := _result("_branch_to_action_or_encounter", [
		branch_mode - 1,
		int(values[2]),
		bool(condition_check.get("gosub", false)),
	])
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func resume_character_ability_check(passed: bool) -> Dictionary:
	if runtime.pending_character_ability_check.is_empty():
		return _result(
			"_error_result",
			["No classic character-ability check is waiting for a response"]
		)
	var ability_check: Dictionary = runtime.pending_character_ability_check
	runtime.pending_character_ability_check = {}
	var values: Array = ability_check["values"]
	var target_id := int(values[3]) if passed else int(values[4])
	var branch_result := _result("_branch_to_extra_action_point", [
		target_id,
		bool(ability_check.get("gosub", false)),
		0,
	])
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func resume_misc_branch(matched: bool) -> Dictionary:
	if runtime.pending_misc_branch.is_empty():
		return _result(
			"_error_result",
			["No classic party identity check is waiting for a response"]
		)
	var branch: Dictionary = runtime.pending_misc_branch
	runtime.pending_misc_branch = {}
	var values: Array = branch["values"]
	if str(branch.get("kind", "")) == "selection_count":
		if matched:
			var success_result := _result(
				"_branch_to_extra_action_point",
				[
					int(values[3]),
					bool(branch.get("gosub", false)),
					0,
				]
			)
			if str(success_result.get("status", "")) != "continue":
				return success_result
			return _run()
		match int(values[1]):
			1:
				var failure_result := _result(
					"_branch_to_extra_action_point",
					[
						int(values[4]),
						bool(branch.get("gosub", false)),
						0,
					]
				)
				if str(failure_result.get("status", "")) != "continue":
					return failure_result
				return _run()
			2:
				runtime.call("_set_cursor", runtime.current_trigger, 8)
				var message_id := int(values[4])
				return _result("_yield_result", [
					"show_text",
					{
						"messageId": message_id,
						"message": _bundle().get_message(message_id),
					},
				])
			_:
				runtime.call("_set_cursor", runtime.current_trigger, 8)
				return _run()
	if str(branch.get("kind", "")) == "character_condition":
		var condition_target := int(values[3]) \
			if matched else int(values[4])
		var condition_result := _result(
			"_branch_to_extra_action_point",
			[
				condition_target,
				bool(branch.get("gosub", false)),
				0,
			]
		)
		if str(condition_result.get("status", "")) != "continue":
			return condition_result
		return _run()
	var target_id := int(values[3]) if matched else int(values[4])
	if target_id == 0:
		return _run()
	var branch_result := _result("_branch_to_action_or_encounter", [
		int(values[2]),
		target_id,
		bool(branch.get("gosub", false)),
	])
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func resume_ally_check(present: bool) -> Dictionary:
	if runtime.pending_ally_check.is_empty():
		return _result(
			"_error_result",
			["No classic ally check is waiting for a response"]
		)
	var ally_check: Dictionary = runtime.pending_ally_check
	runtime.pending_ally_check = {}
	var values: Array = ally_check["values"]
	if present:
		return _resume_ally_branch(values, int(values[3]), ally_check)
	match int(values[2]):
		0:
			return _resume_ally_branch(
				values,
				int(values[4]),
				ally_check
			)
		1:
			return _run()
		2:
			runtime.call("_clear_control_flow")
			return _result("_yield_result", [
				"show_text",
				{
					"messageId": int(values[4]),
					"message": _bundle().get_message(int(values[4])),
				},
			])
		_:
			return _halt(
				"Ally branch has invalid absent mode %d" % int(values[2])
			)


func _execute_give_condition(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Give Condition action references missing Extra Code row %d"
			% extra_code_id
		)
	var target_mode := int(values[0])
	if target_mode < 0 or target_mode > 2:
		return _halt(
			"Give Condition action has invalid target mode %d" % target_mode
		)
	var condition_index := int(values[1])
	if condition_index < 0 or condition_index >= 40:
		return _halt(
			"Give Condition action has invalid condition index %d"
			% condition_index
		)
	return _result("_yield_result", [
		"give_character_condition",
		{
			"extraCodeId": extra_code_id,
			"targetMode": ["party", "selected", "living"][target_mode],
			"conditionIndex": condition_index,
			"duration": int(values[2]),
			"soundId": int(values[3]),
		},
	])


func _execute_spellcasting_flags(extra_code_id: int) -> Dictionary:
	if extra_code_id == 0:
		return _result("_continue_result")
	var values := _values(extra_code_id)
	if values.size() < 3:
		return _halt(
			"Spellcasting-flags action references malformed Extra Code row %d"
			% extra_code_id
		)
	runtime.runtime_state.set_spellcasting_flags(
		int(values[0]) != 0,
		int(values[1]) != 0,
		int(values[2]) != 0
	)
	return _result("_continue_result")


func _execute_selected_character_mutation(
	extra_code_id: int
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 2:
		return _halt(
			"Selected-character mutation references malformed Extra Code row %d"
			% extra_code_id
		)
	var mode := int(values[0])
	if mode < 1 or mode > 12:
		return _halt(
			"Selected-character mutation has invalid mode %d" % mode
		)
	return _result("_yield_result", [
		"alter_selected_characters",
		{
			"extraCodeId": extra_code_id,
			"mode": mode,
			"change": int(values[1]),
		},
	])


func _execute_fatigue_mutation(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 3:
		return _halt(
			"Fatigue action references malformed Extra Code row %d"
			% extra_code_id
		)
	var mode := int(values[0])
	if mode < 1 or mode > 3:
		return _halt("Fatigue action has invalid mode %d" % mode)
	return _result("_yield_result", [
		"alter_party_fatigue",
		{
			"extraCodeId": extra_code_id,
			"mode": mode,
			"percent": int(values[2]),
		},
	])


func _execute_character_pick(record_id: int, invert: bool) -> Dictionary:
	var count: int = abs(record_id)
	if count < 1:
		return _halt("Character-pick action requests no characters")
	return _result("_yield_result", [
		"pick_characters",
		{
			"count": count,
			"allowDead": record_id < 0,
			"invert": invert,
		},
	])


func _execute_character_check_selection(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Character-check action references missing Extra Code row %d"
			% extra_code_id
		)
	var candidate_mode := "selected"
	if int(values[2]) == 1:
		candidate_mode = "party"
	elif int(values[2]) == 2:
		candidate_mode = "alive"
	return _result("_yield_result", [
		"filter_selected_characters",
		{
			"extraCodeId": extra_code_id,
			"checkIndex": abs(int(values[0])),
			"modifier": int(values[1]),
			"candidateMode": candidate_mode,
			"checkType": "attribute" \
				if int(values[3]) != 0 else "special",
			"selectOnFailure": int(values[0]) < 0,
		},
	])


func _execute_character_ability_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 5:
		return _halt(
			"Character-ability branch references malformed Extra Code row %d"
			% extra_code_id
		)
	var check_index := int(values[0])
	var check_type := "attribute" if int(values[2]) != 0 else "special"
	if check_type == "attribute" \
			and check_index not in [0, 1, 2, 3, 4, 6]:
		return _halt(
			"Character-ability branch uses unsupported attribute %d"
			% check_index
		)
	if check_type == "special" \
			and (check_index < 0 or check_index >= 15):
		return _halt(
			"Character-ability branch uses invalid special ability %d"
			% check_index
		)
	runtime.pending_character_ability_check = {
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_character_ability",
		{
			"extraCodeId": extra_code_id,
			"checkIndex": check_index,
			"modifier": int(values[1]),
			"checkType": check_type,
		},
	])


func _execute_identity_character_selection(
	extra_code_id: int
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Race/caste character selector references missing Extra Code row %d"
			% extra_code_id
		)
	var selector_index := int(values[0])
	var selector := ""
	var value_index := 2
	match selector_index:
		0:
			selector = "race"
		1:
			selector = "gender"
			value_index = 1
		2:
			selector = "caste"
		3:
			selector = "race_class"
		4:
			selector = "caste_class"
		_:
			return _halt(
				"Race/caste character selector %d is not supported"
				% selector_index
			)
	return _result("_yield_result", [
		"select_characters_by_identity",
		{
			"extraCodeId": extra_code_id,
			"selector": selector,
			"selectorIndex": selector_index,
			"value": abs(int(values[value_index])),
			"livingOnly": int(values[4]) != 0,
		},
	])


func _execute_caste_character_selection(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 3:
		return _halt(
			"Caste character selector references malformed Extra Code row %d"
			% extra_code_id
		)
	var caste_group := int(values[1])
	var source_mode := int(values[2])
	if caste_group < 0 or caste_group > 3:
		return _halt(
			"Caste character selector has invalid caste group %d"
			% caste_group
		)
	if source_mode < 0 or source_mode > 2:
		return _halt(
			"Caste character selector has invalid source mode %d"
			% source_mode
		)
	return _result("_yield_result", [
		"select_characters_by_identity",
		{
			"extraCodeId": extra_code_id,
			"selector": "caste_group",
			"value": int(values[0]),
			"group": caste_group,
			"sourceMode": source_mode,
			"livingOnly": source_mode == 1,
		},
	])


func _execute_misc_character_selection(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Miscellaneous character selector references missing Extra Code row %d"
			% extra_code_id
		)
	var selector_index := int(values[0])
	var selector := ""
	match selector_index:
		0:
			selector = "movement_below"
		1:
			selector = "position_before"
		2:
			selector = "has_item"
		3:
			selector = "percent"
		4:
			selector = "attribute_save_failure"
		5:
			selector = "spell_save_failure"
		6:
			selector = "focused_character"
		7:
			selector = "wearing_item"
		8:
			selector = "exact_position"
		_:
			return _halt(
				"Miscellaneous character selector %d is not supported"
				% selector_index
			)
	var candidate_mode := "party"
	match int(values[2]):
		0:
			pass
		1:
			candidate_mode = "alive"
		2:
			candidate_mode = "selected"
		_:
			return _halt(
				"Miscellaneous character selector has invalid source set %d"
				% int(values[2])
			)
	var value := int(values[1])
	var item_texts: Array = []
	if selector == "has_item" or selector == "wearing_item":
		var item_text := _bundle().get_item_text(abs(value))
		if not item_text.is_empty():
			item_texts.append(item_text)
	return _result("_yield_result", [
		"select_characters_by_misc",
		{
			"extraCodeId": extra_code_id,
			"selector": selector,
			"selectorIndex": selector_index,
			"value": value,
			"candidateMode": candidate_mode,
			"itemTexts": item_texts,
		},
	])


func _execute_selected_health_effect(extra_code_id: int) -> Dictionary:
	return _execute_health_effect(
		extra_code_id,
		"change_selected_health"
	)


func _execute_party_health_effect(extra_code_id: int) -> Dictionary:
	return _execute_health_effect(extra_code_id, "change_party_health")


func _execute_spell_effect(
	extra_code_id: int,
	target_party: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Spell action references missing Extra Code row %d" % extra_code_id
		)
	var authored_spell_id := int(values[0])
	var trigger: Dictionary = runtime.current_trigger
	var correction: Dictionary = KnownDataCorrectionsScript.spell_reference(
		str(_bundle().manifest.get("id", "")),
		str(trigger.get("source", "")),
		int(trigger.get("recordIndex", -1)),
		authored_spell_id
	)
	var payload := {
		"extraCodeId": extra_code_id,
		"spellId": int(correction.get("spellId", authored_spell_id)),
		"power": int(values[1]),
		"saveAdjustment": int(values[2]),
		"forceAffect": int(values[3]) != 0,
		"targetMode": "party" if target_party else "selected",
	}
	if bool(correction.get("corrected", false)):
		payload["authoredSpellId"] = authored_spell_id
		payload["correctionReason"] = str(correction.get("reason", ""))
	return _result("_yield_result", ["cast_classic_spell", payload])


func _execute_health_effect(
	extra_code_id: int,
	command: String
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Health action references missing Extra Code row %d" % extra_code_id
		)
	var low_roll := int(values[1])
	var high_roll := int(values[2])
	if high_roll < low_roll:
		return _halt("Health action has an invalid roll range")
	var message_id := int(values[4])
	return _result("_yield_result", [
		command,
		{
			"extraCodeId": extra_code_id,
			"multiplier": int(values[0]),
			"rollRange": [low_roll, high_roll],
			"soundId": int(values[3]),
			"messageId": message_id,
			"message": _bundle().get_message(message_id) \
				if message_id != 0 else {},
		},
	])


func _execute_party_condition_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Party-condition branch references missing Extra Code row %d"
			% extra_code_id
		)
	var required_state := int(values[0])
	if required_state not in [1, 2]:
		return _halt(
			"Party-condition branch has invalid state test %d"
			% required_state
		)
	var condition_index := int(values[3])
	if condition_index < 0 \
			or condition_index >= PARTY_CONDITION_NAMES.size():
		return _halt(
			"Party-condition branch has invalid condition index %d"
			% condition_index
		)
	runtime.pending_party_condition_check = {
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_condition",
		{
			"extraCodeId": extra_code_id,
			"conditionIndex": condition_index,
			"conditionName": PARTY_CONDITION_NAMES[condition_index],
			"requiredActive": required_state == 1,
			"branchMode": int(values[1]),
			"targetId": int(values[2]),
		},
	])


func _execute_selected_count_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 5:
		return _halt(
			"Selected-count branch references malformed Extra Code row %d"
			% extra_code_id
		)
	runtime.pending_misc_branch = {
		"kind": "selection_count",
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_misc",
		{
			"extraCodeId": extra_code_id,
			"selector": "selected_count",
			"mode": int(values[0]),
			"failureMode": int(values[1]),
			"matchTargetId": int(values[3]),
			"missTargetId": int(values[4]),
		},
	])


func _execute_character_condition_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.size() < 5:
		return _halt(
			"Character-condition branch references malformed Extra Code row %d"
			% extra_code_id
		)
	var condition_index := int(values[0])
	if condition_index < 0 or condition_index >= 40:
		return _halt(
			"Character-condition branch has invalid condition index %d"
			% condition_index
		)
	runtime.pending_misc_branch = {
		"kind": "character_condition",
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_misc",
		{
			"extraCodeId": extra_code_id,
			"selector": "character_condition_all",
			"conditionIndex": condition_index,
			"candidateMode": int(values[1]),
			"matchTargetId": int(values[3]),
			"missTargetId": int(values[4]),
		},
	])


func _execute_misc_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Party identity branch references missing Extra Code row %d"
			% extra_code_id
		)
	var selector_index := int(values[0])
	var selectors := [
		"caste",
		"race",
		"gender",
		"in_boat",
		"in_camp",
		"caste_class",
		"race_class",
		"party_level_above",
		"selected_level_above",
	]
	if selector_index < 0 or selector_index >= selectors.size():
		return _halt(
			"Party identity branch selector %d is not supported"
			% selector_index
		)
	var branch_mode := int(values[2])
	if branch_mode < 0 or branch_mode > 2:
		return _halt(
			"Party identity branch has invalid target mode %d" % branch_mode
		)
	var authored_value := int(values[1])
	runtime.pending_misc_branch = {
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_misc",
		{
			"extraCodeId": extra_code_id,
			"selector": selectors[selector_index],
			"selectorIndex": selector_index,
			"value": abs(authored_value),
			"selectedOnly": (
				authored_value < 0
				and selector_index in [0, 1, 2, 5, 6]
			),
			"branchMode": branch_mode,
			"matchTargetId": int(values[3]),
			"missTargetId": int(values[4]),
		},
	])


func _execute_ally_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Ally branch references missing Extra Code row %d" % extra_code_id
		)
	var monster_name_id := int(values[0])
	var matching_monsters := _bundle().get_monsters_by_name_id(
		monster_name_id
	)
	var monster: Dictionary = matching_monsters[0] \
		if not matching_monsters.is_empty() else {}
	runtime.pending_ally_check = {
		"values": values,
		"gosub": gosub,
	}
	return _result("_yield_result", [
		"check_party_ally",
		{
			"extraCodeId": extra_code_id,
			"monsterNameId": monster_name_id,
			"monster": monster,
		},
	])


func _execute_remove_ally(monster_name_id: int) -> Dictionary:
	var normalized_name_id := absi(monster_name_id)
	var matching_monsters := _bundle().get_monsters_by_name_id(
		normalized_name_id
	)
	var monster: Dictionary = matching_monsters[0] \
		if not matching_monsters.is_empty() else {}
	return _result("_yield_result", [
		"remove_party_ally",
		{
			"monsterNameId": normalized_name_id,
			"monster": monster,
		},
	])


func _execute_add_ally(monster_id: int) -> Dictionary:
	var monster := _bundle().get_monster(monster_id)
	if monster.is_empty():
		return _halt(
			"Add-ally action references missing monster %d" % monster_id
		)
	return _result("_yield_result", [
		"add_party_ally",
		{
			"monsterId": abs(monster_id),
			"monster": monster,
		},
	])


func _resume_ally_branch(
	values: Array,
	target_id: int,
	ally_check: Dictionary
) -> Dictionary:
	var branch_result := _result("_branch_to_action_or_encounter", [
		int(values[1]),
		target_id,
		bool(ally_check.get("gosub", false)),
	])
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return _run()


func _execute_experience_loss(extra_code_id: int) -> Dictionary:
	var values := _values(extra_code_id)
	if values.is_empty():
		return _halt(
			"Experience-loss action references missing Extra Code row %d"
			% extra_code_id
		)
	var source_mode := int(values[1])
	var mode := "each"
	if source_mode == 1:
		mode = "selected"
	elif source_mode == 2:
		mode = "spread"
	return _result("_yield_result", [
		"remove_experience",
		{
			"extraCodeId": extra_code_id,
			"experience": int(values[0]),
			"mode": mode,
			"sourceMode": source_mode,
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
			"message": "Classic character runtime requires '%s'" % method_name,
		}
	var value: Variant = runtime.callv(method_name, arguments)
	if value is Dictionary:
		return value
	return {
		"status": "error",
		"message": "Classic character operation '%s' returned invalid state" \
			% method_name,
	}
