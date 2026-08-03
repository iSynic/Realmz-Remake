extends NinePatchRect
class_name NewCharStatsRect

const STAT_GROUPS : Array = [
	["Basics", ["MaxMovement","MaxActions","Weight_Limit","MaxSpellsPerRound"]],
	["Resources", ["maxHP","HP_regen_base","HP_regen_mult","maxSP","SP_regen_base","SP_regen_mult"]],
	["Attributes", ["Strength","Intellect","Wisdom","Dexterity","Vitality"]],
	["Accuracy", ["AccuracyMelee","AccuracyRanged","AccuracyMagic"]],
	["Evasion", ["EvasionMelee","EvasionRanged","EvasionMagic"]],
	["Resistances", ["ResistancePhysical","ResistanceMagic","ResistanceFire","ResistanceIce","ResistanceElect","ResistancePoison","ResistanceChemical","ResistanceDisease","ResistanceHealing"]],
	["Multipliers", ["MultiplierPhysical","MultiplierMagic","MultiplierFire","MultiplierIce","MultiplierElect","MultiplierPoison","MultiplierChemical","MultiplierDisease","MultiplierHealing"]],
]

const CLASSIC_STAT_GROUPS : Array = [
	[
		"Classic Character",
		[
			"ClassicGender",
			"ClassicAge",
			"ClassicLuck",
			"ClassicMagicResistance",
			"ClassicExperienceRequirement",
			"ClassicPrestigePenalty",
		],
	],
	[
		"Classic Combat",
		[
			"ClassicHandToHand",
			"ClassicTwoHand",
			"ClassicFoe0",
			"ClassicFoe1",
			"ClassicFoe2",
			"ClassicFoe3",
			"ClassicFoe4",
			"ClassicFoe5",
			"ClassicFoe6",
			"ClassicFoe7",
		],
	],
	[
		"Classic Saving Throws",
		[
			"ClassicSave0",
			"ClassicSave1",
			"ClassicSave2",
			"ClassicSave3",
			"ClassicSave4",
			"ClassicSave5",
			"ClassicSave6",
			"ClassicSave7",
		],
	],
	[
		"Classic Skills",
		[
			"ClassicSkill0",
			"ClassicSkill1",
			"ClassicSkill2",
			"ClassicSkill3",
			"ClassicSkill4",
			"ClassicSkill5",
			"ClassicSkill6",
			"ClassicSkill7",
			"ClassicSkill8",
			"ClassicSkill9",
			"ClassicSkill10",
			"ClassicSkill11",
			"ClassicSkill12",
			"ClassicSkill13",
		],
	],
]

# Display names for stat keys. Some are intentionally short ("Magic", "Melee")
# because they're shown under section headers (ACCURACY, EVASION, RESISTANCES,
# MULTIPLIERS) that supply the context. Don't read these in isolation.
const STAT_DISPLAY_NAMES : Dictionary = {
	"MaxMovement": "Movement",
	"MaxActions": "Actions / Turn",
	"MaxSpellsPerRound": "Spells / Turn",
	"Weight_Limit": "Weight Limit",
	"maxHP": "Max HP",
	"maxSP": "Max SP",
	"HP_regen_base": "HP Regen",
	"SP_regen_base": "SP Regen",
	"HP_regen_mult": "HP Regen %",
	"SP_regen_mult": "SP Regen %",
	"AccuracyMelee": "Melee",
	"AccuracyRanged": "Ranged",
	"AccuracyMagic": "Magic",
	"EvasionMelee": "Melee",
	"EvasionRanged": "Ranged",
	"EvasionMagic": "Magic",
	"ResistancePhysical": "Physical",
	"ResistanceMagic": "Magic",
	"ResistanceFire": "Fire",
	"ResistanceIce": "Ice",
	"ResistanceElect": "Electric",
	"ResistancePoison": "Poison",
	"ResistanceChemical": "Chemical",
	"ResistanceDisease": "Disease",
	"ResistanceHealing": "Healing",
	"MultiplierPhysical": "Physical",
	"MultiplierMagic": "Magic",
	"MultiplierFire": "Fire",
	"MultiplierIce": "Ice",
	"MultiplierElect": "Electric",
	"MultiplierPoison": "Poison",
	"MultiplierChemical": "Chemical",
	"MultiplierDisease": "Disease",
	"MultiplierHealing": "Healing",
}

const CLASSIC_DISPLAY_NAMES : Dictionary = {
	"ClassicGender": "Gender",
	"ClassicAge": "Age",
	"ClassicLuck": "Luck",
	"ClassicMagicResistance": "Magic Resistance",
	"ClassicExperienceRequirement": "Next Level XP",
	"ClassicPrestigePenalty": "Starting Prestige Penalty",
	"ClassicHandToHand": "Hand-to-Hand",
	"ClassicTwoHand": "Two-Hand Skill",
	"ClassicFoe0": "Vs. Magic Creatures",
	"ClassicFoe1": "Vs. Undead Creatures",
	"ClassicFoe2": "Vs. Demons and Devils",
	"ClassicFoe3": "Vs. Reptilian Creatures",
	"ClassicFoe4": "Vs. Very Evil Creatures",
	"ClassicFoe5": "Vs. Intelligent Creatures",
	"ClassicFoe6": "Vs. Giant Creatures",
	"ClassicFoe7": "Vs. Non-humanoids",
	"ClassicSave0": "Charm",
	"ClassicSave1": "Heat",
	"ClassicSave2": "Cold",
	"ClassicSave3": "Electric",
	"ClassicSave4": "Chemical",
	"ClassicSave5": "Mental",
	"ClassicSave6": "Energy",
	"ClassicSave7": "Special",
	"ClassicSkill0": "Sneak Attack",
	"ClassicSkill1": "Hide In Shadows",
	"ClassicSkill2": "Resurrect",
	"ClassicSkill3": "Major Wound",
	"ClassicSkill4": "Detect Secret",
	"ClassicSkill5": "Acrobatic Act",
	"ClassicSkill6": "Detect Trap",
	"ClassicSkill7": "Disarm Trap",
	"ClassicSkill8": "Hear Noise",
	"ClassicSkill9": "Force Door",
	"ClassicSkill10": "Move Silently",
	"ClassicSkill11": "Pick Lock",
	"ClassicSkill12": "Special Skill 13",
	"ClassicSkill13": "Turn Undead",
}

const COLOR_DIM : Color = Color(0.7, 0.7, 0.7, 1)
const COLOR_DEFAULT : Color = Color(1, 1, 1, 1)
const COLOR_SECTION : Color = Color(0.85, 0.7, 0.45, 1)

@export var portraitrect : TextureRect
@export var namelabel : Label
@export var raceclasslabel : Label
@export var levellabel : Label
@export var pointslabel : Label
@export var statslist : VBoxContainer
@export var emptyprompt : Label

@onready var statsscroll : ScrollContainer = $VBox/StatsControl/StatsScroll

var character_level : int = 1
var stat_mods_dict : Dictionary = {}

# stat_name -> HBoxContainer row, so we can update value/badge in place.
var stat_rows : Dictionary = {}

var current_character = null


func _stat_display_name(sn : String) -> String :
	if CLASSIC_DISPLAY_NAMES.has(sn) :
		return str(CLASSIC_DISPLAY_NAMES[sn])
	return STAT_DISPLAY_NAMES.get(sn, sn)


func display_name(charname : String) -> void :
	if charname == "" :
		namelabel.text = "— unnamed —"
	else :
		namelabel.text = charname


func display_portrait(portrait : Texture2D) -> void :
	portraitrect.texture = portrait


func set_character_level(level : int) -> void :
	character_level = level
	levellabel.text = str(level)


func display_partial_selection(racegd, classgd) -> void :
	var racetext : String = racegd.classrace_name if racegd else "no race"
	var classtext : String = classgd.classrace_name if classgd else "no class"
	raceclasslabel.text = racetext + " · " + classtext


func display_data(character) -> void :
	if character.classgd == null or character.racegd == null :
		if emptyprompt :
			emptyprompt.show()
		statsscroll.hide()
		raceclasslabel.text = "no race · no class"
		return
	if emptyprompt :
		emptyprompt.hide()
	statsscroll.show()
	portraitrect.texture = character.portrait
	var race_name: String = (
		str(character.get_display_race_name())
		if character.has_method("get_display_race_name")
		else str(character.racegd.classrace_name)
	)
	var caste_name: String = (
		str(character.get_display_caste_name())
		if character.has_method("get_display_caste_name")
		else str(character.classgd.classrace_name)
	)
	raceclasslabel.text = race_name + " · " + caste_name
	levellabel.text = str(character.level)
	current_character = character
	_rebuild_stats_list()
	_refresh_points_label()


# --- stat list construction ---

func _rebuild_stats_list() -> void :
	for c in statslist.get_children() :
		c.queue_free()
	stat_rows.clear()
	if current_character == null :
		return
	var first : bool = true
	for group in STAT_GROUPS :
		var header_text : String = group[0]
		var stats_in_group : Array = group[1]
		_make_section_header(header_text, first)
		first = false
		for sn in stats_in_group :
			_make_stat_row(sn)
	if not current_character.classic_rule_profile.is_empty() :
		for group in CLASSIC_STAT_GROUPS :
			var header_text : String = group[0]
			var stats_in_group : Array = group[1]
			_make_section_header(header_text, false)
			for sn in stats_in_group :
				_make_stat_row(sn)


func _make_section_header(header_text : String, is_first : bool) -> void :
	if not is_first :
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		statslist.add_child(spacer)
	var lbl := Label.new()
	lbl.text = header_text.to_upper()
	lbl.add_theme_color_override("font_color", COLOR_SECTION)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	statslist.add_child(lbl)


func _make_stat_row(sn : String) -> void :
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.tooltip_text = _build_tooltip(sn)
	row.mouse_filter = Control.MOUSE_FILTER_PASS

	var name_lbl := Label.new()
	name_lbl.text = _stat_display_name(sn)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(name_lbl)

	var value_lbl := Label.new()
	value_lbl.name = "Value"
	value_lbl.custom_minimum_size = Vector2(70, 0)
	value_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(value_lbl)

	statslist.add_child(row)
	stat_rows[sn] = row
	_paint_row(sn)


func _paint_row(sn : String) -> void :
	if not stat_rows.has(sn) :
		return
	var row : HBoxContainer = stat_rows[sn]
	var value_lbl : Label = row.get_node("Value")
	var base_value = (
		_classic_stat_value(sn)
		if CLASSIC_DISPLAY_NAMES.has(sn)
		else current_character.get_stat(sn)
	)
	value_lbl.text = _format_stat_value(base_value)
	value_lbl.add_theme_color_override("font_color", COLOR_DEFAULT)


func _classic_stat_value(sn : String) -> Variant :
	match sn :
		"ClassicGender" :
			return {1: "Male", 2: "Female"}.get(
				int(current_character.classic_gender),
				"—"
			)
		"ClassicAge" :
			return "%d years" % int(current_character.classic_age_years)
		"ClassicLuck" :
			return int(current_character.classic_luck)
		"ClassicMagicResistance" :
			return "%d%%" % int(current_character.classic_magic_resistance)
		"ClassicExperienceRequirement" :
			return int(current_character.exp_tnl)
		"ClassicPrestigePenalty" :
			return int(current_character.classic_prestige_penalty)
		"ClassicHandToHand" :
			return int(current_character.classic_hand_to_hand)
		"ClassicTwoHand" :
			return int(current_character.classic_two_hand)
	if sn.begins_with("ClassicFoe") :
		var foe_index := int(sn.trim_prefix("ClassicFoe"))
		var foe_bonuses: Variant = current_character.classic_rule_profile.get(
			"foeTypeBonuses",
			{}
		).get("bonuses", [])
		if foe_bonuses is Array \
				and foe_index >= 0 \
				and foe_index < foe_bonuses.size() :
			return int(foe_bonuses[foe_index])
	if sn.begins_with("ClassicSave") :
		var save_index := int(sn.trim_prefix("ClassicSave"))
		return current_character.get_classic_saving_throw(save_index)
	if sn.begins_with("ClassicSkill") :
		var skill_index := int(sn.trim_prefix("ClassicSkill"))
		if skill_index >= 0 \
				and skill_index < current_character.classic_special_abilities.size() :
			return current_character.classic_special_abilities[skill_index]
	return 0


func _format_stat_value(v) -> String :
	if v is float :
		# Drop trailing zeros: 1.00 -> 1, 1.06 -> 1.06, 0.50 -> 0.5.
		var s : String = "%.2f" % v
		if "." in s :
			s = s.rstrip("0").rstrip(".")
			if s == "" or s == "-" :
				s = "0"
		return s
	return str(v)


# --- tooltip ---

func _build_tooltip(sn : String) -> String :
	if current_character == null or current_character.classgd == null or current_character.racegd == null :
		return ""
	if CLASSIC_DISPLAY_NAMES.has(sn) :
		return "Calculated by the source-backed Classic Realmz character rules."
	var cbs = current_character.classgd.base_stat_bonuses
	var clu = current_character.classgd.levelup_bonuses
	var rbs = current_character.racegd.base_stat_bonuses
	var rlu = current_character.racegd.levelup_bonuses
	var lines : Array = []
	lines.append("Class %s · Race %s" % [cbs.get(sn, 0), rbs.get(sn, 0)])
	lines.append("Class/lvl %s · Race/lvl %s" % [clu.get(sn, 0), rlu.get(sn, 0)])
	return "\n".join(lines)


# --- points indicator ---

func _refresh_points_label() -> void :
	stat_mods_dict.clear()
	pointslabel.text = "Generated by character creation rules"
	pointslabel.add_theme_color_override("font_color", COLOR_DIM)


func clear() -> void :
	stat_mods_dict.clear()
	current_character = null
	for c in statslist.get_children() :
		c.queue_free()
	stat_rows.clear()
	raceclasslabel.text = "no race · no class"
	namelabel.text = "— unnamed —"
	levellabel.text = "1"
	character_level = 1
	pointslabel.text = "Generated by character creation rules"
	pointslabel.add_theme_color_override("font_color", COLOR_DIM)
	if emptyprompt :
		emptyprompt.show()
	statsscroll.hide()


# --- statnames compat (NewCharacterPanel may still iterate) ---

var statnames : Array :
	get :
		var flat : Array = []
		for group in STAT_GROUPS :
			for sn in group[1] :
				flat.append(sn)
		return flat
