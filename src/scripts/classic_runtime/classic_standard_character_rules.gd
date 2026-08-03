extends RefCounted
class_name ClassicStandardCharacterRules

const DATA_PATH := (
	"res://scripts/classic_runtime/data/standard_character_rules.json"
)
const STANDARD_BUNDLE_ID := "realmz-standard-rules"
const STANDARD_BUNDLE_NAME := "Realmz Standard Rules"

static var _cached_rules: Dictionary = {}
static var _last_error := ""


static func standard_bundle() -> Dictionary:
	var rules := _standard_rules()
	if rules.is_empty():
		return {}
	return {
		"manifest": {
			"id": STANDARD_BUNDLE_ID,
			"name": STANDARD_BUNDLE_NAME,
		},
		"documents": {
			"rules": rules.duplicate(true),
		},
	}


## Combines the stock Realmz tables with complete scenario-local replacements.
## The returned bundle presents every effective record through the same adapter,
## so unchanged stock identities and authored scenario identities share one rules
## owner during creation and later progression.
static func effective_bundle(scenario_bundle: Variant = null) -> Dictionary:
	var base_bundle := standard_bundle()
	if base_bundle.is_empty() or scenario_bundle == null:
		return base_bundle

	var scenario_documents := _dictionary_value(
		_value(scenario_bundle, "documents", {})
	)
	var scenario_rules := _dictionary_value(scenario_documents.get("rules", {}))
	if scenario_rules.is_empty():
		return base_bundle

	var standard_rules: Dictionary = base_bundle["documents"]["rules"]
	var merged_rules := scenario_rules.duplicate(true)
	var scenario_selection := _dictionary_value(
		scenario_rules.get("tableSelection", {})
	)
	var merged_races := _merge_active_records(
		standard_rules.get("raceOverrides", []),
		scenario_rules.get("raceOverrides", []),
		_active_changed_ids(scenario_selection, "races")
	)
	var merged_castes := _merge_active_records(
		standard_rules.get("casteOverrides", []),
		scenario_rules.get("casteOverrides", []),
		_active_changed_ids(scenario_selection, "castes")
	)
	merged_rules["raceOverrides"] = merged_races
	merged_rules["casteOverrides"] = merged_castes
	merged_rules["ruleNames"] = _merged_rule_names(
		_dictionary_value(standard_rules.get("ruleNames", {})),
		_dictionary_value(scenario_rules.get("ruleNames", {}))
	)
	merged_rules["tableSelection"] = {
		"races": {
			"source": "scenario-local",
			"changedRecordIds": _record_ids(merged_races),
		},
		"castes": {
			"source": "scenario-local",
			"changedRecordIds": _record_ids(merged_castes),
		},
	}

	var merged_documents := scenario_documents.duplicate(true)
	merged_documents["rules"] = merged_rules
	var manifest := _dictionary_value(
		_value(scenario_bundle, "manifest", {})
	).duplicate(true)
	return {
		"manifest": manifest,
		"documents": merged_documents,
	}


static func identity_names(bundle: Variant, identity_kind: String) -> Array:
	var rules := _bundle_rules(bundle)
	var names: Variant = _dictionary_value(rules.get("ruleNames", {})).get(
		"raceNames" if identity_kind == "race" else "casteNames",
		[]
	)
	return names.duplicate() if names is Array else []


static func is_caste_allowed(
	bundle: Variant,
	race_id: int,
	caste_id: int
) -> bool:
	if race_id < 1 or caste_id < 1:
		return false
	var rules := _bundle_rules(bundle)
	var race_record := _record_by_id(
		rules.get("raceOverrides", []),
		race_id - 1
	)
	var allowed: Variant = race_record.get("canCaste", [])
	return allowed is Array \
		and caste_id <= allowed.size() \
		and int(allowed[caste_id - 1]) != 0


static func last_error() -> String:
	return _last_error


static func _standard_rules() -> Dictionary:
	if not _cached_rules.is_empty():
		return _cached_rules
	if not FileAccess.file_exists(DATA_PATH):
		_last_error = "Standard Realmz character rules are missing."
		push_error(_last_error)
		return {}
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		_last_error = "Standard Realmz character rules could not be opened."
		push_error(_last_error)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		_last_error = "Standard Realmz character rules contain invalid JSON."
		push_error(_last_error)
		return {}
	var rules: Dictionary = parsed
	if not _validate_standard_rules(rules):
		push_error(_last_error)
		return {}
	_cached_rules = rules.duplicate(true)
	_last_error = ""
	return _cached_rules


static func _validate_standard_rules(rules: Dictionary) -> bool:
	var names := _dictionary_value(rules.get("ruleNames", {}))
	var race_names: Variant = names.get("raceNames", [])
	var caste_names: Variant = names.get("casteNames", [])
	var races: Variant = rules.get("raceOverrides", [])
	var castes: Variant = rules.get("casteOverrides", [])
	if not (race_names is Array) or race_names.size() != 19:
		_last_error = "Standard Realmz rules require nineteen races."
		return false
	if not (caste_names is Array) or caste_names.size() != 20:
		_last_error = "Standard Realmz rules require twenty castes."
		return false
	if not (races is Array) or races.size() != race_names.size():
		_last_error = "Standard Realmz race records are incomplete."
		return false
	if not (castes is Array) or castes.size() != caste_names.size():
		_last_error = "Standard Realmz caste records are incomplete."
		return false
	for race_index: int in range(races.size()):
		var race: Variant = races[race_index]
		if not (race is Dictionary) \
				or int(race.get("id", -1)) != race_index \
				or not (race.get("canCaste", []) is Array) \
				or race["canCaste"].size() != 30:
			_last_error = "Standard Realmz race record %d is incomplete." % (
				race_index + 1
			)
			return false
	for caste_index: int in range(castes.size()):
		var caste: Variant = castes[caste_index]
		if not (caste is Dictionary) \
				or int(caste.get("id", -1)) != caste_index \
				or not (caste.get("victory", []) is Array) \
				or caste["victory"].size() != 30 \
				or not (caste.get("startItems", []) is Array) \
				or caste["startItems"].size() != 20:
			_last_error = "Standard Realmz caste record %d is incomplete." % (
				caste_index + 1
			)
			return false
	return true


static func _merge_active_records(
	standard_records_value: Variant,
	scenario_records_value: Variant,
	changed_ids: Array[int]
) -> Array:
	var by_id: Dictionary = {}
	if standard_records_value is Array:
		for record_value: Variant in standard_records_value:
			if record_value is Dictionary:
				by_id[int(record_value.get("id", -1))] = (
					record_value.duplicate(true)
				)
	if scenario_records_value is Array:
		for record_value: Variant in scenario_records_value:
			if not (record_value is Dictionary):
				continue
			var record_id := int(record_value.get("id", -1))
			if record_id in changed_ids:
				by_id[record_id] = record_value.duplicate(true)
	var ids: Array = by_id.keys()
	ids.sort()
	var result: Array = []
	for record_id: Variant in ids:
		result.append(by_id[record_id])
	return result


static func _active_changed_ids(
	table_selection: Dictionary,
	table_name: String
) -> Array[int]:
	var result: Array[int] = []
	var selection := _dictionary_value(table_selection.get(table_name, {}))
	if str(selection.get("source", "")) != "scenario-local":
		return result
	var values: Variant = selection.get("changedRecordIds", [])
	if values is Array:
		for value: Variant in values:
			result.append(int(value))
	return result


static func _record_ids(records: Array) -> Array[int]:
	var result: Array[int] = []
	for record_value: Variant in records:
		if record_value is Dictionary:
			result.append(int(record_value.get("id", -1)))
	return result


static func _merged_rule_names(
	standard_names: Dictionary,
	scenario_names: Dictionary
) -> Dictionary:
	var result := standard_names.duplicate(true)
	for field: String in ["raceNames", "casteNames"]:
		var values: Variant = scenario_names.get(field, [])
		if values is Array and not values.is_empty():
			result[field] = values.duplicate()
	result["authored"] = true
	return result


static func _record_by_id(records: Variant, record_id: int) -> Dictionary:
	if records is Array:
		for record_value: Variant in records:
			if record_value is Dictionary \
					and int(record_value.get("id", -1)) == record_id:
				return record_value
	return {}


static func _bundle_rules(bundle: Variant) -> Dictionary:
	var documents := _dictionary_value(_value(bundle, "documents", {}))
	return _dictionary_value(documents.get("rules", {}))


static func _dictionary_value(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _value(source: Variant, property_name: String, fallback: Variant) -> Variant:
	if source is Dictionary:
		return source.get(property_name, fallback)
	if source == null or not (source is Object):
		return fallback
	for property: Dictionary in source.get_property_list():
		if str(property.get("name", "")) == property_name:
			return source.get(property_name)
	return fallback
