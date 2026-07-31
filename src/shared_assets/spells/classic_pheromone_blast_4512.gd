extends "res://scripts/classic_runtime/classic_core_charm_spell.gd"


func _init() -> void:
	var source := {
		"packedSpellId": 4512,
		"displayName": "Pheromone Blast",
		"description": (
			"Pheromone Blast: Changes affected creatures' allegiance to the "
			+ "caster for the battle."
		),
		"range1": -4,
		"range2": 0,
		"queueIcon": 0,
		"toHitBonus": 0,
		"saveBonus": -10,
		"fixedTargetNum": 0,
		"canRotate": 0,
		"saveAdjust": 0,
		"cannot": 1,
		"resistAdjust": 0,
		"cost": 0,
		"damage1": 0,
		"damage2": 0,
		"powerDamage1": 0,
		"powerDamage2": 0,
		"duration1": 0,
		"duration2": 0,
		"powerDuration1": 0,
		"powerDuration2": 0,
		"spellLook1": 7,
		"spellLook2": 8,
		"sound1": 99,
		"sound2": 67,
		"targetType": 3,
		"size": 7,
		"special": 52,
		"damageType": 0,
		"spellClass": 0,
		"inCombat": 1,
		"inCamp": 0,
		"elements": [GameGlobal.ELEMENTS.MAGICAL, GameGlobal.ELEMENTS.MENTAL],
		"tags": ["Magical", "Mental", "Charm"],
		"schools": [],
		"schoolLevels": {},
		"selectionCosts": {},
		"lineOfSight": false,
		"sourceRecord": {
			"sourceFile": "Data S",
			"recordIndex": 386,
			"byteOffset": 11580,
			"byteLength": 30,
		},
	}
	source["projectileTexture"] = PresentationScript.gfx_for_source_id(
		int(source["spellLook1"])
	)
	source["projectileHit"] = PresentationScript.gfx_for_source_id(
		int(source["spellLook2"])
	)
	source["sounds"] = PresentationScript.sounds(source)
	configure(source)
	attributes = ["Magical", "Mental"]


func is_generically_executable() -> bool:
	return true
