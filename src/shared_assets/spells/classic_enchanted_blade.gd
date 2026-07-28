extends "res://scripts/classic_runtime/classic_core_attack_bonus_spell.gd"


func _init() -> void:
	classic_spell_ids = [3104]
	configure_core_attack_bonus_spell(3104)
	name = "Classic Enchanted Blade"
	schools = []
	school_levels = {}
	selection_costs = {}
