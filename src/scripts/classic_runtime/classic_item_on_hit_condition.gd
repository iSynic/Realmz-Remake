class_name ClassicItemOnHitCondition
extends RefCounted

const ConditionRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_condition_rules.gd"
)
const SpellSavesScript = preload(
	"res://scripts/classic_runtime/classic_spell_saves.gd"
)

const SOURCE_MARKER := -10
const SAVE_MODE_DRV := 1
const SAVE_MODE_PERCENT := 2


static func descriptor(record: Dictionary) -> Dictionary:
	if int(record.get("special1", 0)) != SOURCE_MARKER:
		return {}
	var condition_code := int(record.get("special3", 0))
	var condition_index := condition_code - 20
	if not ConditionRulesScript.supports_condition(condition_index):
		return {}
	var source_mode := int(record.get("special2", 0))
	var result := {
		"conditionCode": condition_code,
		"conditionIndex": condition_index,
		"conditionName": ConditionRulesScript.condition_name(condition_index),
		"duration": int(record.get("special5", 0)),
		"mode": "automatic",
	}
	if source_mode == SAVE_MODE_DRV:
		var save_index := int(record.get("special4", 0))
		if not SpellSavesScript.supports_save_index(save_index):
			return {}
		result["mode"] = "save"
		result["saveIndex"] = save_index
	elif source_mode == SAVE_MODE_PERCENT:
		result["mode"] = "percent"
		result["chance"] = clampi(int(record.get("special4", 0)), 0, 100)
	return result


static func apply_from_weapon(
	target: Object,
	weapon: Dictionary,
	roll := -1,
	party_charm_bonus := 0,
	chance_modifier := Callable()
) -> Dictionary:
	var extra_data: Variant = weapon.get("extra_data", {})
	if not (extra_data is Dictionary):
		return {"handled": false}
	var behavior: Variant = extra_data.get("classicOnHitCondition", {})
	if not (behavior is Dictionary) or behavior.is_empty():
		return {"handled": false}
	return apply(
		target,
		behavior,
		roll,
		party_charm_bonus,
		chance_modifier
	)


static func apply(
	target: Object,
	behavior: Dictionary,
	roll := -1,
	party_charm_bonus := 0,
	chance_modifier := Callable()
) -> Dictionary:
	if target == null:
		return _error("Classic item condition target is missing")
	var condition_index := int(behavior.get("conditionIndex", -1))
	if not ConditionRulesScript.supports_condition(condition_index):
		return _error("Classic item condition has an unsupported condition slot")
	var mode := str(behavior.get("mode", "automatic"))
	if mode not in ["automatic", "save", "percent"]:
		return _error("Classic item condition has an invalid resolution mode")

	var result := {
		"handled": true,
		"status": "ok",
		"applied": false,
		"conditionIndex": condition_index,
		"conditionName": ConditionRulesScript.condition_name(condition_index),
		"duration": int(behavior.get("duration", 0)),
		"mode": mode,
	}
	var actual_roll := roll if roll >= 0 else randi_range(1, 100)
	if mode == "save":
		var save_index := int(behavior.get("saveIndex", -1))
		if not SpellSavesScript.supports_save_index(save_index):
			return _error("Classic item condition has an invalid save index")
		var save_chance := SpellSavesScript.monster_attack_save_chance_for(
			target,
			save_index,
			party_charm_bonus
		)
		if chance_modifier.is_valid():
			save_chance = clampf(float(chance_modifier.call(
				"condition-resistance",
				save_chance,
				{
					"source": "item-on-hit-condition",
					"conditionIndex": condition_index,
					"conditionName": result["conditionName"],
					"target": _rule_subject(target),
					"minimum": 0.0,
					"maximum": 100.0,
				}
			)), 0.0, 100.0)
		result["saveIndex"] = save_index
		result["saveChance"] = save_chance
		result["roll"] = actual_roll
		result["saved"] = actual_roll <= save_chance
		if bool(result["saved"]):
			return result
	elif mode == "percent":
		var chance := clampi(int(behavior.get("chance", 0)), 0, 100)
		result["chance"] = chance
		result["roll"] = actual_roll
		if actual_roll > chance:
			return result

	var previous_value := ConditionRulesScript.condition_value(
		target,
		condition_index
	)
	result["previousValue"] = previous_value
	# Classic never adds a temporary duration over a permanent condition.
	if previous_value < 0:
		result["blockedByPermanentCondition"] = true
		return result
	var new_value := previous_value + int(result["duration"])
	var set_result := ConditionRulesScript.set_condition_value(
		target,
		condition_index,
		new_value
	)
	if str(set_result.get("status", "")) == "error":
		return set_result.merged({"handled": true}, true)
	result["applied"] = true
	result["value"] = new_value
	return result


static func _rule_subject(target: Object) -> Dictionary:
	var result := {}
	for property: Dictionary in target.get_property_list():
		var property_name := str(property.get("name", ""))
		if property_name == "name":
			result["name"] = str(target.get(property_name))
		elif property_name == "level":
			result["level"] = int(target.get(property_name))
	if target.has_meta("classic_monster_id"):
		result["classicMonsterId"] = int(target.get_meta("classic_monster_id"))
	return result


static func _error(message: String) -> Dictionary:
	return {
		"handled": true,
		"status": "error",
		"message": message,
	}
