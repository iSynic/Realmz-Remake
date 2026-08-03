extends NinePatchRect
class_name AlliesRect

const IMMUNITY_NAMES := [
	"Charm", "Heat", "Cold", "Electrical", "Chemical", "Mental",
]

@export var entry_tscn: PackedScene
@export var entry_container: VBoxContainer
@export var empty_label: Label
@export var ally_count_label: Label
@export var info_panel: CreatureInfoPanel
@export var retention_label: Label
@export var done_button: Button

var listed_creatures: Array = []
var _rows: Array = []
var _retained := {}
var _selected_row = null

signal done_allying


func _ready() -> void:
	if info_panel != null:
		info_panel.close_button.hide()


func fill(allies: Array) -> void:
	listed_creatures.clear()
	_rows.clear()
	_retained.clear()
	_selected_row = null
	for child in entry_container.get_children():
		entry_container.remove_child(child)
		child.queue_free()

	var kept_summons_by_owner := {}
	for creature_value in allies:
		if not (creature_value is Creature):
			continue
		var creature: Creature = creature_value
		if creature.is_summoned and creature.get_stat("curHP") <= 0:
			continue
		if not creature.is_npc_ally and not creature.is_summoned:
			continue

		var summoner_name := creature.summoner_name if creature.is_summoned else ""
		var retained := true
		if creature.is_summoned:
			var summoner: PlayerCharacter = _find_summoner(summoner_name)
			var limit: int = summoner.get_max_perma_summons() if summoner != null else 0
			var kept := int(kept_summons_by_owner.get(summoner_name, 0))
			retained = kept < limit
			if retained:
				kept_summons_by_owner[summoner_name] = kept + 1

		listed_creatures.append(creature)
		_retained[creature] = retained
		var row = entry_tscn.instantiate()
		entry_container.add_child(row)
		row.configure(
			creature,
			_ally_kind_text(creature),
			retained,
			summoner_name,
		)
		row.selected.connect(_on_row_selected)
		row.retained_changed.connect(_on_row_retained_changed)
		_rows.append(row)

	ally_count_label.text = "%d companion%s" % [
		listed_creatures.size(),
		"" if listed_creatures.size() == 1 else "s",
	]
	empty_label.visible = listed_creatures.is_empty()
	info_panel.visible = not listed_creatures.is_empty()
	if not _rows.is_empty():
		_select_row(_rows[0])
	_refresh_retention_status()


func _ally_kind_text(creature: Creature) -> String:
	if creature.is_summoned:
		if creature.summoner_name.is_empty():
			return "Summoned creature"
		return "Summoned by %s" % creature.summoner_name
	return "Permanent ally"


func _find_summoner(summoner_name: String) -> PlayerCharacter:
	for character in GameGlobal.player_characters:
		if character is PlayerCharacter and character.name == summoner_name:
			return character
	return null


func _on_row_selected(row) -> void:
	_select_row(row)


func _select_row(row) -> void:
	if _selected_row != null and is_instance_valid(_selected_row):
		_selected_row.set_selected(false)
	_selected_row = row
	_selected_row.set_selected(true)
	info_panel.populate(creature_info(row.creature))


func _on_row_retained_changed(row, retained: bool) -> void:
	_retained[row.creature] = retained
	_refresh_retention_status()


func _refresh_retention_status() -> void:
	var counts := {}
	var limits := {}
	for creature in listed_creatures:
		if not creature.is_summoned or not bool(_retained.get(creature, false)):
			continue
		var summoner_key: String = creature.summoner_name
		counts[summoner_key] = int(counts.get(summoner_key, 0)) + 1
		var summoner: PlayerCharacter = _find_summoner(summoner_key)
		limits[summoner_key] = (
			summoner.get_max_perma_summons() if summoner != null else 0
		)

	var over_limit := false
	var summaries: Array[String] = []
	for summoner_key in limits:
		var count := int(counts.get(summoner_key, 0))
		var limit := int(limits[summoner_key])
		if count > limit:
			over_limit = true
		summaries.append("%s's summons %d/%d" % [summoner_key, count, limit])

	if summaries.is_empty():
		retention_label.text = "Select an ally to inspect equipment, combat values, traits, and resistances."
	else:
		retention_label.text = "  •  ".join(summaries)
	if over_limit:
		retention_label.text += " — reduce retained summons to continue."
	retention_label.add_theme_color_override(
		"font_color",
		Color(1.0, 0.35, 0.25) if over_limit else Color(0.82, 0.82, 0.82),
	)
	done_button.disabled = over_limit


func creature_info(creature: Creature) -> Dictionary:
	var source := _source_bestiary_entry(creature)
	var cdata: Dictionary = source.duplicate(true) if not source.is_empty() else {}
	if not cdata.has("data"):
		cdata["data"] = {}
	if not cdata.has("stats"):
		cdata["stats"] = {}
	if not cdata.has("tools"):
		cdata["tools"] = {}

	var data: Dictionary = cdata["data"]
	data["name"] = creature.name
	data["level"] = creature.level
	data["image"] = creature.textureR
	data["tags"] = creature.tags.duplicate()
	data["subtitle"] = _ally_kind_text(creature)
	data["description"] = _equipment_and_classic_text(creature, source)
	cdata["data"] = data
	cdata["stats"] = creature.stats.duplicate(true)
	cdata["description_header"] = "Equipment & Classic Details"
	cdata["show_current_resources"] = true
	return cdata


func _source_bestiary_entry(creature: Creature) -> Dictionary:
	var resources = NodeAccess.__Resources()
	if resources == null:
		return {}
	if not creature.bestiary_key.is_empty() \
			and resources.crea_book.has(creature.bestiary_key):
		var direct = resources.crea_book[creature.bestiary_key]
		return direct if direct is Dictionary else {}
	for key in resources.crea_book:
		var candidate = resources.crea_book[key]
		if not (candidate is Dictionary):
			continue
		if int(candidate.get("classicMonsterId", -1)) == creature.classic_monster_id \
				and creature.classic_monster_id >= 0:
			return candidate
	return {}


func _equipment_and_classic_text(
	creature: Creature,
	source: Dictionary,
) -> String:
	var sections: Array[String] = []
	var equipment: Array[String] = []
	for item in creature.inventory_instances():
		var item_definition: ItemDefinition = creature.get_item_definition(item)
		var display_name := (
			item_definition.display_name_for(item)
			if item_definition != null
			else item.definition_id
		)
		if display_name.is_empty():
			continue
		equipment.append(
			("Equipped — " if item.equipped else "Carried — ") + display_name
		)
	if equipment.is_empty():
		sections.append("EQUIPMENT\nNone")
	else:
		var visible_equipment: Array[String] = []
		for index in mini(6, equipment.size()):
			visible_equipment.append(equipment[index])
		var equipment_text := "EQUIPMENT\n" + "\n".join(visible_equipment)
		if equipment.size() > visible_equipment.size():
			equipment_text += "\n+%d more" % (equipment.size() - visible_equipment.size())
		sections.append(equipment_text)

	var record_value = source.get("classicRecord", {})
	var record: Dictionary = record_value if record_value is Dictionary else {}
	var armor := int(creature.get_meta(
		"classic_armor",
		record.get("armor", 0),
	))
	var magic_resistance := int(creature.get_meta(
		"classic_magic_resistance",
		record.get("magicResistance", 0),
	))
	var toughness := int(record.get("hitDice", creature.level))
	var movement := int(record.get(
		"movementMax",
		creature.get_stat("MaxMovement"),
	))
	var magical_attacks := int(record.get(
		"magicAttackCount",
		creature.get_stat("MaxSpellsPerRound"),
	))
	var combat_lines := [
		"Armor Rating %d  •  Magic Resistance %d%%" % [armor, magic_resistance],
		"Movement %d  •  Magical Attacks %d  •  Toughness %d" % [
			movement, magical_attacks, toughness,
		],
	]
	var attacks := _attack_summaries(source)
	if not attacks.is_empty():
		combat_lines.append("Attacks — " + ", ".join(attacks))
	var immunity_text := _immunity_summary(creature, source)
	if not immunity_text.is_empty():
		combat_lines.append(immunity_text)
	sections.append("CLASSIC COMBAT\n" + "\n".join(combat_lines))

	return "\n\n".join(sections)


func _attack_summaries(source: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var tools = source.get("tools", {})
	if not (tools is Dictionary):
		return result
	var attacks = tools.get("unarmed_melee_attacks", [])
	if not (attacks is Array):
		return result
	for attack in attacks:
		if not (attack is Dictionary):
			continue
		var damage = attack.get("weapon_dmg", {})
		if not (damage is Dictionary):
			continue
		var pieces: Array[String] = []
		for damage_type in damage:
			var dice = damage[damage_type]
			if dice is Array and dice.size() >= 2:
				pieces.append("%dd%d %s" % [
					int(dice[0]), int(dice[1]), str(damage_type),
				])
		if not pieces.is_empty():
			var summary := " + ".join(pieces)
			if not result.has(summary):
				result.append(summary)
	return result


func _immunity_summary(creature: Creature, source: Dictionary) -> String:
	var immunities_value = creature.get_meta(
		"classic_spell_immunities",
		source.get("classicSpellImmunities", []),
	)
	var saves_value = creature.get_meta(
		"classic_spell_saves",
		source.get("classicSpellSaves", []),
	)
	var immunities: Array[String] = []
	var vulnerabilities: Array[String] = []
	if immunities_value is Array:
		for index in mini(IMMUNITY_NAMES.size(), immunities_value.size()):
			if int(immunities_value[index]) != 0:
				immunities.append(IMMUNITY_NAMES[index])
	if saves_value is Array:
		for index in mini(IMMUNITY_NAMES.size(), saves_value.size()):
			if int(saves_value[index]) < 0:
				vulnerabilities.append(IMMUNITY_NAMES[index])
	var parts: Array[String] = []
	if not immunities.is_empty():
		parts.append("Immune — " + ", ".join(immunities))
	if not vulnerabilities.is_empty():
		parts.append("Vulnerable — " + ", ".join(vulnerabilities))
	return "  •  ".join(parts)


func _on_done_button_pressed() -> void:
	if done_button.disabled:
		return
	GameGlobal.player_allies.clear()
	for creature in listed_creatures:
		if bool(_retained.get(creature, false)):
			GameGlobal.player_allies.append(creature)
	UI.ow_hud.fillCharactersRect()
	get_parent().hide()
	done_allying.emit()
