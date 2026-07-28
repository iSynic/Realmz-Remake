extends "res://scripts/classic_runtime/classic_breath_spell.gd"


func _init() -> void:
	name = "Lightning Breath"
	classic_spell_class = 3
	classic_target_type = 6
	classic_spell_ids = [4209]
	classic_spell_save_index = 3
	classic_spell_save_mode = "half_damage"
	description = "Lightning Breath: Deals 2-15 electric damage per power along a range-7 ray."
	attributes = ["Magical"]
	elements = [GameGlobal.ELEMENTS.ELECTRIC]
	tags = ["Magical", "Electric"]
	schools = ["Special"]
	targettile = TARGET_TILE.ANY
	in_field = false
	in_combat = true
	resist = RESIST_TYPE.IGNORE_MRES_DODGE
	los = false
	ray = true
	proj_tex = GFX.SPARK
	proj_hit = GFX.SPHERE
	sounds = ["electric energize.wav", "dididup.wav"]
	breath_range = 7
	damage_minimum = 2
	damage_maximum = 15
