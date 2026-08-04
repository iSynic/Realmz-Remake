class_name ClassicMonsterSpecialAttack
extends RefCounted

const SpellSavesScript = preload("res://scripts/classic_runtime/classic_spell_saves.gd")
const StatusAttackScript = preload(
	"res://scripts/classic_runtime/classic_monster_status_attack.gd"
)
const PermanentAfflictionScript = preload(
	"res://scripts/classic_runtime/classic_permanent_affliction.gd"
)
const CharacterRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_rules.gd"
)
const CharmedTrait = preload("res://shared_assets/traits/t_classic_charmed.gd")

const SAVE_BY_SPECIAL := {
	8: 6,
	9: 5,
	10: 0,
	17: 7,
	18: 7,
	19: 7,
}
const ELEMENTAL_SPECIALS := {
	11: {
		"element": "Fire",
		"saveIndex": 1,
		"protectionTraits": [
			"t_prot_fire.gd", "p_prot_fire.gd", "t_classic_prot_fire.gd",
		],
	},
	12: {
		"element": "Ice",
		"saveIndex": 2,
		"protectionTraits": [
			"t_prot_ice.gd", "p_prot_ice.gd", "t_classic_prot_ice.gd",
		],
	},
	13: {
		"element": "Electric",
		"saveIndex": 3,
		"protectionTraits": [
			"t_prot_elect.gd", "p_prot_elect.gd", "t_classic_prot_elect.gd",
		],
	},
	14: {
		"element": "Chemical",
		"saveIndex": 4,
		"protectionTraits": [
			"t_prot_chem.gd", "p_prot_chem.gd", "t_classic_prot_chem.gd",
		],
	},
	15: {
		"element": "Mental",
		"saveIndex": 5,
		"protectionTraits": [
			"t_prot_mental.gd", "p_prot_mental.gd", "t_classic_prot_mental.gd",
		],
	},
}


static func supports(special_code: int) -> bool:
	return StatusAttackScript.supports(special_code) \
		or SAVE_BY_SPECIAL.has(special_code) \
		or ELEMENTAL_SPECIALS.has(special_code)


static func is_elemental(special_code: int) -> bool:
	return ELEMENTAL_SPECIALS.has(special_code)


static func apply_from_weapon(
	attacker: Object,
	target: Object,
	weapon: Dictionary,
	save_roll := -1,
	party_charm_bonus := 0,
	chance_modifier := Callable(),
	damage_roll := -1
) -> Dictionary:
	var extra_data: Variant = weapon.get("extra_data", {})
	if not (extra_data is Dictionary):
		return {"handled": false}
	var special_code := int(extra_data.get("classicSpecialAttack", 0))
	if not supports(special_code):
		return {"handled": false}
	return apply(
		attacker,
		target,
		special_code,
		save_roll,
		party_charm_bonus,
		chance_modifier,
		int(extra_data.get(
			"classicSpecialDamageMax",
			extra_data.get("classicSpecialPower", 0)
		)),
		damage_roll
	)


static func apply(
	attacker: Object,
	target: Object,
	special_code: int,
	save_roll := -1,
	party_charm_bonus := 0,
	chance_modifier := Callable(),
	damage_max := 0,
	damage_roll := -1
) -> Dictionary:
	if StatusAttackScript.supports(special_code):
		return StatusAttackScript.apply(
			attacker,
			target,
			special_code,
			-1,
			save_roll,
			chance_modifier
		)
	if not SAVE_BY_SPECIAL.has(special_code) \
			and not ELEMENTAL_SPECIALS.has(special_code):
		return {"handled": false}
	if attacker == null or target == null \
			or not attacker.has_method("get_stat") \
			or not target.has_method("get_stat"):
		return _error("Classic monster special attack has an invalid combatant")

	var is_monster_target := target.has_meta("classic_hit_dice")
	var elemental: Variant = ELEMENTAL_SPECIALS.get(special_code, {})
	var save_index := int(elemental.get("saveIndex", -1)) \
		if elemental is Dictionary and not elemental.is_empty() \
		else int(SAVE_BY_SPECIAL[special_code])
	var result := {
		"handled": true,
		"status": "ok",
		"specialCode": special_code,
		"saveIndex": save_index,
		"applied": false,
	}
	if is_monster_target \
			and int(target.get_meta("classic_magic_resistance", 0)) > 100:
		result["blockedByMagicResistance"] = true
		return result
	# Drain Victory and Age have no monster-target case in attack.c.
	if special_code in [9, 17] and is_monster_target:
		result["partyTargetOnly"] = true
		return result

	var actual_save_roll := save_roll if save_roll >= 0 else randi_range(1, 100)
	var save_chance := SpellSavesScript.monster_attack_save_chance_for(
		target,
		int(result["saveIndex"]),
		party_charm_bonus if special_code == 10 else 0
	)
	if chance_modifier.is_valid():
		save_chance = clampf(
			float(chance_modifier.call(
				"condition-resistance",
				save_chance,
				{
					"source": "monster-special-attack",
					"specialCode": special_code,
					"attacker": _rule_subject(attacker),
					"target": _rule_subject(target),
					"minimum": 0.0,
					"maximum": 100.0,
				}
			)),
			0.0,
			100.0
		)
	result["saveChance"] = save_chance
	result["saveRoll"] = actual_save_roll
	result["saved"] = actual_save_roll <= save_chance
	if elemental is Dictionary and not elemental.is_empty():
		return _elemental_damage(
			target,
			result,
			elemental,
			damage_max,
			damage_roll,
			is_monster_target
		)
	if bool(result["saved"]):
		return result

	match special_code:
		8:
			return _drain_spell_points(attacker, target, result)
		9:
			return _drain_experience(attacker, target, result)
		10:
			return _charm(attacker, target, result)
		17:
			return _age(attacker, target, result, damage_max)
		18:
			return _blind(target, result)
		19:
			return _petrify(target, result)
	return result


static func _elemental_damage(
	target: Object,
	result: Dictionary,
	elemental: Dictionary,
	damage_max: int,
	damage_roll: int,
	is_monster_target: bool
) -> Dictionary:
	if damage_max < 1:
		return _error("Classic elemental special attack has no damage maximum")
	var actual_damage_roll := clampi(
		damage_roll if damage_roll >= 0 else randi_range(1, damage_max),
		1,
		damage_max
	)
	var damage := actual_damage_roll
	if bool(result.get("saved", false)):
		damage = floori(float(damage) / 2.0)
	var protected := _has_elemental_protection(
		target,
		elemental.get("protectionTraits", [])
	)
	var displayed_damage := damage
	if protected:
		displayed_damage = floori(float(displayed_damage) / 2.0)
		# attack.c adds Cold, Shock, Chemical, and Mental damage to the
		# monster-target total before checking protection. Preserve that quirk;
		# Fire and every party-target branch apply both reductions normally.
		if not is_monster_target or int(result.get("specialCode", 0)) == 11:
			damage = displayed_damage
		else:
			result["monsterProtectionDisplayOnly"] = true
	result["element"] = str(elemental.get("element", ""))
	result["damageMax"] = damage_max
	result["damageRoll"] = actual_damage_roll
	result["damage"] = damage
	result["displayedDamage"] = displayed_damage
	result["protected"] = protected
	result["applied"] = damage > 0
	return result


static func _has_elemental_protection(
	target: Object,
	protection_names: Variant
) -> bool:
	if target == null or not (protection_names is Array):
		return false
	var traits: Variant = _property_value(target, "traits")
	if not (traits is Array):
		return false
	for trait_value: Variant in traits:
		var trait_name := ""
		if trait_value is Dictionary:
			trait_name = str(trait_value.get("name", ""))
		elif trait_value is Object:
			trait_name = str(_property_value(trait_value, "name"))
		if protection_names.has(trait_name):
			return true
	return false


static func _drain_spell_points(
	attacker: Object,
	target: Object,
	result: Dictionary
) -> Dictionary:
	var attacker_stats: Variant = _property_value(attacker, "stats")
	var target_stats: Variant = _property_value(target, "stats")
	if not (attacker_stats is Dictionary) or not (target_stats is Dictionary):
		return _error("Classic spell-point drain requires mutable combat stats")
	var target_spell_points := maxi(0, int(target_stats.get("curSP", 0)))
	if target_spell_points == 0:
		result["drainedSpellPoints"] = 0
		return result
	var hit_dice := maxi(0, int(attacker.get_meta("classic_hit_dice", 0)))
	var drained := mini(target_spell_points, hit_dice * 3)
	target_stats["curSP"] = target_spell_points - drained
	# Classic lets the attacker retain drained points above its normal maximum.
	attacker_stats["curSP"] = int(attacker_stats.get("curSP", 0)) + drained
	result["drainedSpellPoints"] = drained
	result["applied"] = drained > 0
	return result


static func _drain_experience(
	attacker: Object,
	target: Object,
	result: Dictionary
) -> Dictionary:
	if not _has_property(target, "exp_tnl"):
		return _error("Classic experience drain requires player experience state")
	var penalty := maxi(0, int(attacker.get_stat("maxHP"))) * 20
	# Remake stores experience remaining to the next level, so losing earned
	# experience increases this value.
	target.set("exp_tnl", int(target.get("exp_tnl")) + penalty)
	result["experienceRemoved"] = penalty
	result["applied"] = penalty > 0
	return result


static func _charm(
	attacker: Object,
	target: Object,
	result: Dictionary
) -> Dictionary:
	if not target.has_method("add_trait"):
		return _error("Classic Charm requires mutable target traits")
	target.add_trait(CharmedTrait, [attacker])
	if target.has_meta("classic_hit_dice"):
		var attacker_memory: Variant = _property_value(
			attacker,
			"creature_script_memory"
		)
		if attacker_memory is Dictionary:
			attacker_memory.erase("target_crea")
			result["attackerTargetCleared"] = true
	result["applied"] = true
	result["targetFaction"] = int(target.get("curFaction"))
	return result


static func _age(
	attacker: Object,
	target: Object,
	result: Dictionary,
	special_power: int
) -> Dictionary:
	if special_power < 1:
		return _error("Classic aging attack has no positive magnitude")
	var profile: Variant = _property_value(target, "classic_rule_profile")
	if not (profile is Dictionary):
		return _error("Classic aging attack requires target race rules")
	var creation: Variant = profile.get("creation", {})
	if not (creation is Dictionary) or not creation.has("maximumAge"):
		return _error("Classic aging attack requires target maximum age")
	var maximum_age := int(creation.get("maximumAge", 0))
	var hit_dice := maxi(0, int(attacker.get_meta("classic_hit_dice", 0)))
	if maximum_age < 1 or hit_dice < 1:
		return _error("Classic aging attack has invalid race or attacker rules")
	# attack.c stores this floating-point result in a short and adds it directly
	# to the character's day counter. Preserve that unit quirk exactly.
	var age_days := floori(
		float(maximum_age) * 0.01 * float(special_power * hit_dice)
	)
	var aging_result: Dictionary = CharacterRulesScript.advance_character_age_days(
		target,
		age_days
	)
	if str(aging_result.get("status", "")) == "error":
		return _error(str(aging_result.get("message", "Classic aging failed")))
	result["ageDays"] = age_days
	result["ageYears"] = int(aging_result.get("ageYears", 0))
	result["ageGroup"] = int(aging_result.get("ageGroup", 0))
	result["ageTransition"] = int(aging_result.get("transition", 0))
	result["applied"] = age_days > 0
	return result


static func _blind(target: Object, result: Dictionary) -> Dictionary:
	if not PermanentAfflictionScript.apply_blindness(target):
		return _error("Classic blindness requires mutable target traits")
	result["applied"] = true
	return result


static func _petrify(target: Object, result: Dictionary) -> Dictionary:
	if not PermanentAfflictionScript.apply_petrification(target):
		return _error("Classic petrification requires mutable combat health")
	result["applied"] = true
	result["targetKilled"] = true
	return result


static func _property_value(value: Object, property_name: String) -> Variant:
	for property: Dictionary in value.get_property_list():
		if str(property.get("name", "")) == property_name:
			return value.get(property_name)
	return null


static func _has_property(value: Object, property_name: String) -> bool:
	return _property_value(value, property_name) != null


static func _rule_subject(value: Object) -> Dictionary:
	if value == null:
		return {}
	var result := {}
	for property: Dictionary in value.get_property_list():
		var property_name := str(property.get("name", ""))
		if property_name == "name":
			result["name"] = str(value.get(property_name))
		elif property_name == "level":
			result["level"] = int(value.get(property_name))
	if value.has_meta("classic_monster_id"):
		result["classicMonsterId"] = int(value.get_meta("classic_monster_id"))
	return result


static func _error(message: String) -> Dictionary:
	return {
		"handled": true,
		"status": "error",
		"message": message,
	}
