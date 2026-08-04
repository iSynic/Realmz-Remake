extends "res://scripts/classic_runtime/classic_core_missile_spell.gd"


func _init() -> void:
	name = "Arrow +1"
	in_field = false
	in_combat = true
	classic_spell_class = 9
	classic_target_type = 1
	classic_spell_ids = [4102]
	classic_spell_save_index = -1
	classic_spell_save_mode = "none"
	configure_stock_missile_spell({
		"packedSpellId": 4102,
		"displayName": "Arrow +1",
		"range1": 20,
		"range2": 0,
		"queueIcon": 0,
		"toHitBonus": 5,
		"saveBonus": 0,
		"fixedTargetNum": 1,
		"canRotate": 0,
		"saveAdjust": 0,
		"cannot": 3,
		"resistAdjust": 0,
		"cost": 0,
		"damage1": 2,
		"damage2": 7,
		"powerDamage1": 0,
		"powerDamage2": 0,
		"duration1": 0,
		"duration2": 0,
		"powerDuration1": 0,
		"powerDuration2": 0,
		"spellLook1": 1,
		"spellLook2": 5,
		"sound1": 25,
		"sound2": 19,
		"targetType": 1,
		"size": 0,
		"special": 0,
		"damageType": 9,
		"spellClass": 9,
		"inCombat": 1,
		"inCamp": 0,
		"sourceRecord": {
			"sourceFile": "Data S",
			"recordIndex": 316,
			"byteOffset": 9480,
			"byteLength": 30,
		},
	})
