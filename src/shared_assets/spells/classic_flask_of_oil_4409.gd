extends "res://scripts/classic_runtime/classic_core_missile_spell.gd"


func _init() -> void:
	name = "Flask of Oil"
	in_field = false
	in_combat = true
	classic_spell_class = 9
	classic_target_type = 1
	classic_spell_ids = [4409]
	classic_spell_save_index = 1
	classic_spell_save_mode = "half_damage"
	configure_stock_missile_spell({
		"packedSpellId": 4409,
		"displayName": "Flask of Oil",
		"range1": 4,
		"range2": 0,
		"queueIcon": 0,
		"toHitBonus": 0,
		"saveBonus": 0,
		"fixedTargetNum": 1,
		"canRotate": 0,
		"saveAdjust": 0,
		"cannot": 1,
		"resistAdjust": 0,
		"cost": 0,
		"damage1": 1,
		"damage2": 6,
		"powerDamage1": 0,
		"powerDamage2": 0,
		"duration1": 0,
		"duration2": 0,
		"powerDuration1": 0,
		"powerDuration2": 0,
		"spellLook1": 5,
		"spellLook2": 6,
		"sound1": 50,
		"sound2": 45,
		"targetType": 1,
		"size": 0,
		"special": 0,
		"damageType": 1,
		"spellClass": 9,
		"inCombat": 1,
		"inCamp": 0,
		"sourceRecord": {
			"sourceFile": "Data S",
			"recordIndex": 368,
			"byteOffset": 11040,
			"byteLength": 30,
		},
	})
