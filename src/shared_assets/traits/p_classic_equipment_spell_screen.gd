const name := "p_classic_equipment_spell_screen.gd"
const menuname := "Spell Screen (Classic Equipment)"
const stacks := false
const permanent := true
const trait_types := ["Spell Screen"]

var chara
var trait_source := ""
var level := 1


func _init(args: Array) -> void:
	chara = args[0]
	if args.size() >= 2:
		level = clampi(int(args[1]), 1, 5)


func screen_level() -> int:
	return level


func get_saved_variables() -> Array:
	return [level]


func get_info_as_text() -> String:
	var source_text := "" if trait_source.is_empty() \
		else " (source: %s)" % trait_source
	return "Spell screen level %d%s" % [level, source_text]


func equals_args(args: Array) -> bool:
	return args.size() >= 1 and int(args[0]) == level
