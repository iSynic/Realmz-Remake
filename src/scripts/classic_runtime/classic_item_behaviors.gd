class_name ClassicItemBehaviors
extends RefCounted

const TORCH_ITEM_ID := 805
const SHINE_SPELL_ID := 1110
const DEFAULT_TORCH_POWER := 4
const TORCH_SOUND := "spell launch 2.wav"
const TORCH_SPECIAL_FIELDS := ["special1", "special2"]
const EQUIPMENT_TYPES := [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 16, 17, 18, 19]
const SHARED_SPELL_DIRECTORY := "res://shared_assets/spells/"
const SpellIdentityScript = preload(
	"res://scripts/classic_runtime/classic_spell_identity.gd"
)
const SpellResourceCatalogScript = preload(
	"res://scripts/classic_runtime/classic_spell_resource_catalog.gd"
)
const SpellIdsScript = preload("res://scripts/spells_id_divinity.gd")
const ConditionRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_condition_rules.gd"
)

static var _spell_mapping: Dictionary = {}
static var _spell_catalog: Dictionary = {}
static var _spell_catalog_loaded := false


static func enrich_item_book(item_book: Dictionary) -> Dictionary:
	var result := item_book.duplicate()
	for item_key: Variant in result:
		var item_value: Variant = result[item_key]
		if item_value is Dictionary:
			result[item_key] = enrich_definition_source(item_value)
	return result


static func enrich_definition_source(source: Dictionary) -> Dictionary:
	var result := source.duplicate(true)
	var handled_fields: Array[String] = []
	var power := classic_torch_power(source)
	if power > 0:
		var hook_source := torch_field_use_source(power)
		if not result.has("_on_field_use_source") \
				or str(result["_on_field_use_source"]) == hook_source:
			result["_on_field_use_source"] = hook_source
			handled_fields.append_array(TORCH_SPECIAL_FIELDS)
	var record: Variant = source.get("classicRecord", {})
	if record is Dictionary and not record.is_empty():
		_apply_stored_spell(result, record, handled_fields)
		_apply_equipped_condition(result, record, handled_fields)
		_apply_special_ability_modifiers(result, record, handled_fields)
	_update_materialization(result, handled_fields)
	return result


static func classic_torch_power(source: Dictionary) -> int:
	if not _has_classic_item_id(source, TORCH_ITEM_ID):
		return 0
	var record: Variant = source.get("classicRecord", {})
	if record is Dictionary and not record.is_empty():
		return torch_record_power(record)
	return DEFAULT_TORCH_POWER


static func torch_record_power(record: Dictionary) -> int:
	if abs(int(record.get("itemId", 0))) != TORCH_ITEM_ID:
		return 0
	if abs(int(record.get("special2", 0))) != SHINE_SPELL_ID:
		return 0
	return abs(int(record.get("special1", 0)))


static func handles_special_field(record: Dictionary, field_name: String) -> bool:
	if torch_record_power(record) > 0 and TORCH_SPECIAL_FIELDS.has(field_name):
		return true
	var spell_behavior := stored_spell_behavior(record)
	if not spell_behavior.is_empty() and field_name in ["special1", "special2"]:
		return true
	var condition := equipped_condition_behavior(record)
	if not condition.is_empty() and field_name in ["special1", "special2"]:
		return true
	var ability_modifiers := special_ability_modifiers(record)
	if field_name == "special3" and ability_modifiers.has("special3"):
		return true
	if field_name == "special4" and ability_modifiers.has("special4"):
		return true
	return field_name == "special5" and not ability_modifiers.is_empty()


static func stored_spell_behavior(record: Dictionary) -> Dictionary:
	if torch_record_power(record) > 0:
		return {}
	var spell_id: int = absi(int(record.get("special2", 0)))
	var power: int = absi(int(record.get("special1", 0)))
	if spell_id <= 1100 or power <= 0 or power == 8:
		return {}
	_ensure_spell_catalog()
	var resource_key := SpellIdentityScript.resource_key(
		spell_id,
		_spell_mapping,
		_spell_catalog
	)
	if resource_key.is_empty():
		return {}
	var metadata: Variant = _spell_catalog.get(resource_key, {})
	if not (metadata is Dictionary):
		return {}
	var usage: Dictionary = _spell_usage(metadata)
	var in_field: bool = bool(usage.get("inField", false))
	var in_combat: bool = bool(usage.get("inCombat", false))
	if not in_field and not in_combat:
		return {}
	return {
		"spellId": spell_id,
		"resourceKey": resource_key,
		"power": power,
		"inField": in_field,
		"inCombat": in_combat,
	}


static func _spell_usage(metadata: Dictionary) -> Dictionary:
	if metadata.has("inField") and metadata.has("inCombat"):
		return {
			"inField": bool(metadata["inField"]),
			"inCombat": bool(metadata["inCombat"]),
		}
	var resource_path: String = str(metadata.get("resourcePath", ""))
	var spell_script: Variant = load(resource_path) if not resource_path.is_empty() else null
	var spell: Variant = spell_script.new() if spell_script is GDScript else null
	return {
		"inField": bool(spell.get("in_field")) if spell is Object else false,
		"inCombat": bool(spell.get("in_combat")) if spell is Object else false,
	}


static func equipped_condition_behavior(record: Dictionary) -> Dictionary:
	if absi(int(record.get("type", 0))) not in EQUIPMENT_TYPES:
		return {}
	var condition_index := int(record.get("special1", 0)) - 20
	var condition_change := int(record.get("special2", 0))
	if condition_change >= 0 \
			or not ConditionRulesScript.CONDITION_TRAITS.has(condition_index):
		return {}
	var definition: Dictionary = ConditionRulesScript.CONDITION_TRAITS[
		condition_index
	]
	return {
		"conditionIndex": condition_index,
		"conditionName": str(definition.get("name", "")),
		"trait": str(definition.get("permanent", "")).get_file(),
		"power": maxi(1, absi(condition_change)),
	}


static func special_ability_modifiers(record: Dictionary) -> Dictionary:
	if absi(int(record.get("type", 0))) not in EQUIPMENT_TYPES:
		return {}
	var modifier := int(record.get("special5", 0))
	if modifier == 0:
		return {}
	var result := {}
	for field_name: String in ["special3", "special4"]:
		var ability_number := int(record.get(field_name, 0))
		if ability_number >= 1 and ability_number <= 15:
			result[field_name] = {
				"index": ability_number - 1,
				"modifier": modifier,
			}
	return result


static func _apply_stored_spell(
	result: Dictionary,
	record: Dictionary,
	handled_fields: Array[String]
) -> void:
	var behavior := stored_spell_behavior(record)
	if behavior.is_empty():
		return
	var descriptor := [behavior["resourceKey"], behavior["power"]]
	if bool(behavior["inField"]):
		result["_on_field_use_spell"] = descriptor.duplicate()
	if bool(behavior["inCombat"]):
		result["_on_combat_use_spell"] = descriptor.duplicate()
	handled_fields.append("special1")
	handled_fields.append("special2")


static func _apply_equipped_condition(
	result: Dictionary,
	record: Dictionary,
	handled_fields: Array[String]
) -> void:
	var behavior := equipped_condition_behavior(record)
	if behavior.is_empty():
		return
	var traits: Array = result.get("traits", []).duplicate(true) \
		if result.get("traits", []) is Array else []
	var descriptor := [behavior["trait"], [behavior["power"]]]
	if not traits.has(descriptor):
		traits.append(descriptor)
	result["traits"] = traits
	handled_fields.append("special1")
	handled_fields.append("special2")


static func _apply_special_ability_modifiers(
	result: Dictionary,
	record: Dictionary,
	handled_fields: Array[String]
) -> void:
	var behaviors := special_ability_modifiers(record)
	if behaviors.is_empty():
		return
	var extra_data: Dictionary = result.get("extra_data", {}).duplicate(true) \
		if result.get("extra_data", {}) is Dictionary else {}
	var modifiers := {}
	for field_name: String in behaviors:
		var behavior: Dictionary = behaviors[field_name]
		modifiers[str(behavior["index"])] = int(behavior["modifier"])
		handled_fields.append(field_name)
	extra_data["classicSpecialAbilityModifiers"] = modifiers
	result["extra_data"] = extra_data
	handled_fields.append("special5")


static func _ensure_spell_catalog() -> void:
	if _spell_catalog_loaded:
		return
	_spell_catalog_loaded = true
	var spell_ids: Object = SpellIdsScript.new()
	_spell_mapping = spell_ids.get("mappings").duplicate(true)
	spell_ids.free()
	SpellResourceCatalogScript.merge_directory(
		SHARED_SPELL_DIRECTORY,
		_spell_catalog
	)


static func find_party_torch(
	characters: Array,
	resources: Object
) -> Dictionary:
	if resources == null \
			or not resources.has_method("item_classic_ids"):
		return {}
	for character_value: Variant in characters:
		if not (character_value is Object) \
				or not character_value.has_method("inventory_instances"):
			continue
		for item_value: Variant in character_value.call("inventory_instances"):
			if not (item_value is ItemInstance) \
					or int(item_value.get("charges")) <= 0:
				continue
			var classic_ids: Variant = resources.call(
				"item_classic_ids",
				item_value
			)
			if classic_ids is Array and classic_ids.has(TORCH_ITEM_ID):
				return {
					"holder": character_value,
					"item": item_value,
				}
	return {}


static func activate_party_torch(
	characters: Array,
	resources: Object
) -> Dictionary:
	var selection := find_party_torch(characters, resources)
	if selection.is_empty():
		return _activation_failure("no-torch", "The party has no usable Torch")
	var holder: Object = selection["holder"]
	var torch: ItemInstance = selection["item"]
	if holder.has_method("can_use_inventory_item") \
			and not bool(holder.call("can_use_inventory_item", torch)):
		return _activation_failure(
			"not-permitted",
			"The Torch holder cannot use this item"
		)
	if not resources.has_method("item_has_hook") \
			or not bool(resources.call("item_has_hook", torch, "field_use")):
		return _activation_failure(
			"missing-behavior",
			"The Torch has no field-use behavior"
		)
	var hook_result: Dictionary = resources.call(
		"run_item_hook",
		torch,
		"field_use",
		[holder]
	)
	if not bool(hook_result.get("ok", false)) \
			or not bool(hook_result.get("value", false)):
		var errors: Array = hook_result.get("errors", [])
		return {
			"ok": false,
			"reason": "use-failed",
			"message": (
				str(errors[0])
				if not errors.is_empty()
				else "The Torch could not be used"
			),
			"errors": errors.duplicate(),
		}
	var removed := false
	var definition: ItemDefinition = resources.call(
		"get_item_definition",
		torch
	)
	if definition != null and definition.delete_on_empty \
			and torch.charges <= 0 \
			and holder.has_method("remove_inventory_item"):
		removed = bool(holder.call("remove_inventory_item", torch))
	return {
		"ok": true,
		"reason": "activated",
		"holder": holder,
		"item": torch,
		"remainingCharges": torch.charges,
		"removed": removed,
		"errors": [],
	}


static func torch_field_use_source(power: int) -> String:
	return (
		"if int(item.get(\"charges\", 0)) <= 0:\n"
		+ "\treturn false\n"
		+ "item[\"charges\"] = int(item[\"charges\"]) - 1\n"
		+ "GameGlobal.add_classic_light_effect(%d)\n" % max(1, power)
		+ "GameGlobal.play_sfx(\"%s\")\n" % TORCH_SOUND
		+ "return true"
	)


static func _has_classic_item_id(source: Dictionary, item_id: int) -> bool:
	if abs(int(source.get("classicItemId", 0))) == item_id:
		return true
	var aliases: Variant = source.get("classicItemIds", [])
	if aliases is Array:
		for alias_value: Variant in aliases:
			if abs(int(alias_value)) == item_id:
				return true
	return false


static func _activation_failure(reason: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"message": message,
		"errors": [],
	}


static func _update_materialization(
	source: Dictionary,
	handled_fields: Array[String]
) -> void:
	var materialization_value: Variant = source.get("classicMaterialization", {})
	if not (materialization_value is Dictionary) or materialization_value.is_empty():
		return
	var materialization: Dictionary = materialization_value.duplicate(true)
	var unsupported_value: Variant = materialization.get("unsupportedFields", [])
	var unsupported: Array = unsupported_value.duplicate() if unsupported_value is Array else []
	for field_name: String in handled_fields:
		unsupported.erase(field_name)
	materialization["unsupportedFields"] = unsupported
	if unsupported.is_empty():
		var fallbacks: Variant = materialization.get("fidelityFallbacks", [])
		materialization["status"] = (
			"fallback"
			if fallbacks is Array and not fallbacks.is_empty()
			else "complete"
		)
	source["classicMaterialization"] = materialization
