extends "res://scripts/classic_runtime/classic_breath_spell.gd"


func _init() -> void:
	name = "Flame Breath"
	classic_spell_class = 1
	classic_target_type = 6
	classic_spell_ids = [4206]
	classic_spell_save_index = 1
	classic_spell_save_mode = "half_damage"
	description = "Flame Breath: Deals 2-15 fire damage per power along a range-7 ray."
	attributes = ["Magical"]
	elements = [GameGlobal.ELEMENTS.FIRE]
	tags = ["Magical", "Fire"]
	schools = ["Special"]
	targettile = TARGET_TILE.ANY
	in_field = false
	in_combat = true
	resist = RESIST_TYPE.IGNORE_MRES_DODGE
	los = false
	ray = true
	proj_tex = GFX.FIRE
	proj_hit = GFX.FIRE
	sounds = ["wind.wav", "small explode.wav"]
	breath_range = 7
	damage_minimum = 2
	damage_maximum = 15
