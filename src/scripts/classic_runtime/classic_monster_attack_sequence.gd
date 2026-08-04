class_name ClassicMonsterAttackSequence
extends RefCounted


static func weapon_for_attack(
	active_weapon: Dictionary,
	attack_rows: Array,
	attacks_used: int
) -> Dictionary:
	if attack_rows.is_empty():
		return active_weapon
	var row_value: Variant = attack_rows[posmod(attacks_used, attack_rows.size())]
	if not (row_value is Dictionary):
		return active_weapon
	var attack_row: Dictionary = row_value
	if str(active_weapon.get("name", "")) == "NO_MELEE_WEAPON":
		return attack_row

	# Classic takes ordinary damage from an equipped weapon but still applies
	# the special attached to the monster's current attack row.
	var effective_weapon: Dictionary = active_weapon.duplicate(true)
	_apply_special_metadata(effective_weapon, attack_row)
	return effective_weapon


static func _apply_special_metadata(
	effective_weapon: Dictionary,
	attack_row: Dictionary
) -> void:
	var row_extra: Variant = attack_row.get("extra_data", {})
	if not (row_extra is Dictionary) or not row_extra.has("classicSpecialAttack"):
		return
	var weapon_extra: Variant = effective_weapon.get("extra_data", {})
	if weapon_extra is Dictionary:
		weapon_extra = weapon_extra.duplicate(true)
	else:
		weapon_extra = {}
	weapon_extra["classicSpecialAttack"] = int(row_extra["classicSpecialAttack"])
	if row_extra.has("classicSpecialDamageMax"):
		weapon_extra["classicSpecialDamageMax"] = int(
			row_extra["classicSpecialDamageMax"]
		)
	effective_weapon["extra_data"] = weapon_extra
