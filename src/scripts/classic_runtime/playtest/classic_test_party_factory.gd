class_name ClassicTestPartyFactory
extends RefCounted

const PARTY_SIZE := 6
const TEST_PARTY_SOURCE := "remake-classic-lifecycle"
const CARRIED_ONLY_ITEMS := [
	"Holy Symbol",
	"Divine Holy Symbol",
	"Short Sword",
	"Short Sword +3",
]

const MEMBER_TEMPLATES := [
	{
		"name": "Alaric",
		"role": "frontline",
		"raceName": "Human",
		"raceId": 1,
		"casteName": "Fighter",
		"casteId": 1,
		"artIndex": 1,
	},
	{
		"name": "Brynja",
		"role": "crusader",
		"raceName": "Dwarf",
		"raceId": 7,
		"casteName": "Crusader",
		"casteId": 3,
		"artIndex": 2,
	},
	{
		"name": "Korga",
		"role": "rogue",
		"raceName": "Half Orc",
		"raceId": 9,
		"casteName": "Rogue",
		"casteId": 5,
		"artIndex": 3,
	},
	{
		"name": "Lethiel",
		"role": "archer",
		"raceName": "Elf",
		"raceId": 3,
		"casteName": "Archer",
		"casteId": 4,
		"artIndex": 4,
	},
	{
		"name": "Nyssara",
		"role": "sorcerer",
		"raceName": "Shadow Elf",
		"raceId": 2,
		"casteName": "Sorcerer",
		"casteId": 6,
		"artIndex": 5,
	},
	{
		"name": "Pella",
		"role": "priest",
		"raceName": "Gnome",
		"raceId": 6,
		"casteName": "Priest",
		"casteId": 7,
		"artIndex": 6,
	},
]

const LOADOUTS := {
	"frontline": [
		["Broadsword", "Chain Armor", "Shield", "Leather Boots"],
		["Broadsword +1", "Chain Armor", "Shield +3", "Leather Boots"],
		["Broadsword +2", "Plate Armor +3", "Shield +3", "Leather Boots"],
		["Broadsword +2", "Plate Armor +9", "Shield +6"],
		["Broadsword +2", "Plate Armor +9", "Shield +6"],
	],
	"crusader": [
		["Mace", "Chain Armor", "Shield", "Holy Symbol"],
		["Mace +1", "Chain Armor +3", "Shield +3", "Holy Symbol"],
		["Mace +2", "Plate Armor +3", "Shield +3", "Divine Holy Symbol"],
		[
			"Mace of Resistance +2",
			"Plate Armor +9",
			"Shield +6",
		],
		[
			"Mace of Destruction +3",
			"Plate Armor +9",
			"Shield +6",
		],
	],
	"rogue": [
		["Dagger", "Leather Armor", "Leather Boots"],
		["Dagger +1", "Leather Armor +3", "Boots of Stealth"],
		["Dagger of Penetration +2", "Leather Armor +6", "Boots of Stealth"],
		["Dagger of Styx +2", "Leather Armor +6", "Boots of Stealth"],
		["Dagger of Styx +2", "Leather Armor +6", "Boots of Stealth"],
	],
	"archer": [
		["Bow", "Quiver of Arrows", "Short Sword", "Leather Armor"],
		["Bow +1", "Quiver of Arrows", "Short Sword", "Leather Armor +3"],
		[
			"Bow of Shalomar +2",
			"Quiver of Arrows",
			"Short Sword +3",
			"Leather Armor +6",
		],
		[
			"Bow of Champions +4",
			"Quiver of Arrows",
			"Short Sword +3",
			"Leather Armor +6",
		],
		[
			"Bow of the Elves +6",
			"Quiver of Arrows",
			"Short Sword +3",
			"Leather Armor +6",
		],
	],
	"sorcerer": [
		["Quarter Staff", "Robe", "Leather Boots"],
		["Quarter Staff +1", "Robe of Enchanters +1", "Leather Boots"],
		["Quarter Staff +2", "Robe of The Magi +2", "Leather Boots"],
		["Staff of Spells +2", "Robe of Spell Storing +1", "Leather Boots"],
		["Staff of Merlin +3", "Robe of The Magi +2", "Leather Boots"],
	],
	"priest": [
		["Mace", "Chain Armor", "Shield", "Holy Symbol"],
		["Mace +1", "Chain Armor +3", "Shield +3", "Holy Symbol"],
		["Mace +2", "Plate Armor +3", "Shield +3", "Divine Holy Symbol"],
		[
			"Mace of Resistance +2",
			"Plate Armor +9",
			"Shield +6",
		],
		[
			"Mace of Destruction +3",
			"Plate Armor +9",
			"Shield +6",
		],
	],
}

const SPELL_PRIORITIES := {
	"archer": [
		"Leap",
		"Protection from Foe",
	],
	"sorcerer": [
		"Leap",
		"Superfly",
		"Invisible Skin",
		"Protection from Foe",
		"Adrenalin",
		"Magic Screen I",
		"Magic Shield",
		"Flame Missile",
		"Annihilate",
		"Hail Storm",
	],
	"priest": [
		"Heal Small Wounds",
		"Protection from Cold",
		"Protection from Heat",
		"Heal Disease",
		"Heal Poison",
		"Heal Medium Wounds",
		"Psi Shield",
		"Heal Large Wounds",
		"Heal Wounds",
		"Revive Dead",
		"Regenerate Stamina",
	],
}


static func levels_for_recommended_total(
	recommended_total: int,
	party_size := PARTY_SIZE,
) -> Array[int]:
	var normalized_size := maxi(1, party_size)
	var normalized_total := maxi(normalized_size, recommended_total)
	var base_level := normalized_total / normalized_size
	var remainder := normalized_total % normalized_size
	var levels: Array[int] = []
	for member_index: int in normalized_size:
		levels.append(base_level + (1 if member_index < remainder else 0))
	return levels


static func specs_for_recommended_total(recommended_total: int) -> Array[Dictionary]:
	var levels := levels_for_recommended_total(recommended_total)
	var specs: Array[Dictionary] = []
	for member_index: int in MEMBER_TEMPLATES.size():
		var spec: Dictionary = MEMBER_TEMPLATES[member_index].duplicate(true)
		spec["level"] = levels[member_index]
		spec["gearTier"] = gear_tier_for_level(levels[member_index])
		specs.append(spec)
	return specs


static func member_names() -> Array[String]:
	var names: Array[String] = []
	for template_value: Variant in MEMBER_TEMPLATES:
		names.append(str(template_value.get("name", "")))
	return names


static func gear_tier_for_level(level: int) -> int:
	if level <= 3:
		return 0
	if level <= 8:
		return 1
	if level <= 14:
		return 2
	if level <= 20:
		return 3
	return 4


static func maximum_spell_tier_for_level(level: int) -> int:
	return clampi(1 + (maxi(1, level) - 1) / 4, 1, 7)


static func provision(
	profile_characters_directory: String,
	recommended_total: int,
	resources: CampaignResources,
) -> Dictionary:
	if resources == null:
		return _error("The campaign resource service is unavailable.")
	if not resources.ensure_shared_item_catalog_loaded():
		return _error("Shared item definitions could not be loaded.")
	resources.load_spell_resources("res://shared_assets/spells/")
	if resources.spells_book.is_empty():
		return _error("Shared spell definitions could not be loaded.")

	var normalized_directory := (
		profile_characters_directory
		.replace("\\", "/")
		.simplify_path()
		.trim_suffix("/")
	)
	var create_error := DirAccess.make_dir_recursive_absolute(
		normalized_directory
	)
	if create_error != OK:
		return _error(
			"Could not create the playtest character directory: %s"
			% error_string(create_error)
		)

	var summaries: Array[Dictionary] = []
	for spec: Dictionary in specs_for_recommended_total(recommended_total):
		var character_result := _build_character(spec, resources)
		if str(character_result.get("status", "")) != "ok":
			return character_result
		var character: PlayerCharacter = character_result["character"]
		var character_directory := normalized_directory.path_join(character.name)
		if DirAccess.dir_exists_absolute(character_directory):
			return _error(
				"Playtest character directory already exists: %s"
				% character.name
			)
		var character_error := DirAccess.make_dir_recursive_absolute(
			character_directory
		)
		if character_error != OK:
			return _error(
				"Could not create the playtest character %s: %s"
				% [character.name, error_string(character_error)]
			)
		if not Utils.FileHandler.save_character(character_directory, character):
			return _error(
				"Could not save the playtest character %s." % character.name
			)
		summaries.append(_character_summary(character, spec, resources))
	return {
		"status": "ok",
		"recommendedPartyLevel": recommended_total,
		"actualPartyLevel": _level_total(summaries),
		"characters": summaries,
	}


static func _build_character(
	spec: Dictionary,
	resources: CampaignResources,
) -> Dictionary:
	var race_name := str(spec.get("raceName", ""))
	var caste_name := str(spec.get("casteName", ""))
	var class_script: GDScript = load(
		"res://Data/Character Classes/Class_%s.gd" % caste_name
	)
	var race_script: GDScript = load(
		"res://Data/Character Races/Race_%s.gd" % race_name
	)
	var art_index := int(spec.get("artIndex", 1))
	var icon := _load_texture(
		"res://Data/Character Icons/%s %d.png" % [race_name, art_index]
	)
	var portrait := _load_texture(
		"res://Data/Character Portraits/%s %d.png" % [race_name, art_index]
	)
	if class_script == null or race_script == null \
			or icon == null or portrait == null:
		return _error(
			"%s has unresolved race, caste, icon, or portrait assets."
			% str(spec.get("name", "Playtest character"))
		)
	var level := maxi(1, int(spec.get("level", 1)))
	var character := PlayerCharacter.new(
		{
			"name": str(spec.get("name", "")),
			"level": level,
			"exp_tnl": PlayerCharacter.get_exp_req_for_lvl(level + 1),
			"money": [50 + level * 10, 0, 0],
			"campaign": "Free",
			"classicRaceId": int(spec.get("raceId", 0)),
			"classicCasteId": int(spec.get("casteId", 0)),
			"classicRaceName": race_name,
			"classicCasteName": caste_name,
			"classicSourceCharacter": {
				"fixture": TEST_PARTY_SOURCE,
				"role": str(spec.get("role", "")),
				"recommendedLevel": level,
			},
		},
		icon,
		portrait,
		class_script,
		race_script,
	)
	var loadout_result := _apply_loadout(character, spec, resources)
	if str(loadout_result.get("status", "")) != "ok":
		return loadout_result
	var spell_result := _learn_spells(character, spec, resources)
	if str(spell_result.get("status", "")) != "ok":
		return spell_result
	return {
		"status": "ok",
		"character": character,
		"loadout": loadout_result,
		"spells": spell_result,
	}


static func _apply_loadout(
	character: PlayerCharacter,
	spec: Dictionary,
	resources: CampaignResources,
) -> Dictionary:
	var role := str(spec.get("role", ""))
	var tier := clampi(int(spec.get("gearTier", 0)), 0, 4)
	var role_loadouts: Variant = LOADOUTS.get(role, [])
	if not (role_loadouts is Array) or tier >= role_loadouts.size():
		return _error("No playtest loadout is defined for role %s." % role)
	var item_names: Variant = role_loadouts[tier]
	if not (item_names is Array):
		return _error("The playtest loadout for role %s is malformed." % role)

	var equipped: Array[String] = []
	var carried: Array[String] = []
	for item_index: int in item_names.size():
		var item_name := str(item_names[item_index])
		var instance := resources.create_item_instance(
			item_name,
			{
				"instanceId": "classic-test:%s:item:%d"
					% [character.name.uri_encode(), item_index],
				"identified": true,
			},
		)
		if instance == null:
			return _error(
				"%s could not receive missing item %s."
				% [character.name, item_name]
			)
		if not character.add_inventory_item(instance):
			return _error(
				"%s could not legally carry %s."
				% [character.name, item_name]
			)
		var definition := resources.get_item_definition(instance)
		var equippable := (
			definition != null
			and bool(definition.equippable)
			and not definition.slots().is_empty()
			and not CARRIED_ONLY_ITEMS.has(item_name)
		)
		if equippable:
			if not character.equip_item(instance):
				return _error(
					"%s could not legally equip %s."
					% [character.name, item_name]
				)
			equipped.append(item_name)
		else:
			carried.append(item_name)

	return {
		"status": "ok",
		"equipped": equipped,
		"carried": carried,
	}


static func _learn_spells(
	character: PlayerCharacter,
	spec: Dictionary,
	resources: CampaignResources,
) -> Dictionary:
	var role := str(spec.get("role", ""))
	var maximum_tier := maximum_spell_tier_for_level(character.level)
	var eligible_by_tier: Dictionary = {}
	var spell_names: Array[String] = []
	for spell_name_value: Variant in resources.spells_book.keys():
		spell_names.append(str(spell_name_value))
	spell_names.sort()
	for spell_name: String in spell_names:
		var spell_value: Variant = resources.spells_book.get(spell_name)
		if not (spell_value is Dictionary):
			continue
		var spell_script: Variant = spell_value.get("script")
		if spell_script == null:
			continue
		var required_tier := character.can_learn_spell_at_level(spell_script)
		if required_tier <= 0 or required_tier > maximum_tier:
			continue
		if not eligible_by_tier.has(required_tier):
			eligible_by_tier[required_tier] = []
		eligible_by_tier[required_tier].append(spell_name)

	var learned: Array[Dictionary] = []
	var priorities: Variant = SPELL_PRIORITIES.get(role, [])
	for tier: int in range(1, maximum_tier + 1):
		var tier_candidates: Array = eligible_by_tier.get(tier, [])
		if tier_candidates.is_empty():
			continue
		var selected: Array[String] = []
		if priorities is Array:
			for priority_value: Variant in priorities:
				var priority := str(priority_value)
				if priority in tier_candidates and not selected.has(priority):
					selected.append(priority)
				if selected.size() >= 2:
					break
		for candidate_value: Variant in tier_candidates:
			var candidate := str(candidate_value)
			if not selected.has(candidate):
				selected.append(candidate)
			if selected.size() >= 2:
				break
		for selected_name: String in selected:
			character.add_spell_from_spells_book(selected_name, tier)
			learned.append({"name": selected_name, "tier": tier})
	return {
		"status": "ok",
		"maximumTier": maximum_tier,
		"learned": learned,
	}


static func _character_summary(
	character: PlayerCharacter,
	spec: Dictionary,
	resources: CampaignResources,
) -> Dictionary:
	var equipment: Array[String] = []
	var carried: Array[String] = []
	for item: ItemInstance in character.item_inventory:
		var definition := resources.get_item_definition(item)
		var item_name := (
			definition.display_name_for(item)
			if definition != null
			else item.definition_id
		)
		if item.equipped:
			equipment.append(item_name)
		else:
			carried.append(item_name)
	var spells: Array[String] = []
	for spell_level: Variant in character.spells:
		if not (spell_level is Array):
			continue
		for spell_value: Variant in spell_level:
			if spell_value is Dictionary:
				spells.append(str(spell_value.get("name", "")))
	return {
		"name": character.name,
		"role": str(spec.get("role", "")),
		"race": character.get_display_race_name(),
		"caste": character.get_display_caste_name(),
		"level": character.level,
		"gearTier": int(spec.get("gearTier", 0)),
		"equipment": equipment,
		"carried": carried,
		"spells": spells,
	}


static func _level_total(summaries: Array[Dictionary]) -> int:
	var total := 0
	for summary: Dictionary in summaries:
		total += int(summary.get("level", 0))
	return total


static func _load_texture(resource_path: String) -> ImageTexture:
	var image := Image.load_from_file(
		ProjectSettings.globalize_path(resource_path)
	)
	if image == null or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


static func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
