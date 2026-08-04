class_name ScenarioCampaignBundle
extends RefCounted

const ClassicBundleScript = preload(
	"res://scripts/classic_runtime/classic_campaign_bundle.gd"
)
const ScenarioScriptRuntimeScript = preload(
	"res://scripts/scenario_runtime/scenario_script_runtime.gd"
)

const FORMAT := "realmz-remake-scenario"
const FORMAT_VERSION := 3
const DOCUMENT_SCHEMA_VERSION := 6
const CAMPAIGN_KINDS := [
	"classic-interpreted",
	"classic-enhanced",
	"remake-authored",
]
const REQUIRED_AUTHORED_DOCUMENTS := [
	"scenario",
	"maps",
	"content",
	"rules",
	"assets",
	"remakeLogic",
	"remakeScripts",
	"runtime",
]
const FORBIDDEN_EXTENSIONS := [
	".dll", ".dylib", ".exe", ".gdc", ".pck", ".so",
]
const MATERIALIZED_RUNTIME_DIRECTORIES := [
	"Bestiary", "Items", "Maps", "Tilesets",
]

var implementation: Object
var root_directory := ""
var manifest: Dictionary = {}
var documents: Dictionary = {}
var last_error := ""
var spell_overrides_by_id: Dictionary = {}


func load_from_directory(directory: String) -> bool:
	_reset()
	root_directory = ProjectSettings.globalize_path(directory).replace("\\", "/").simplify_path()
	var manifest_path := root_directory.path_join("campaign.json")
	var parsed: Variant = _read_json(manifest_path)
	if not (parsed is Dictionary):
		return _fail("campaign.json is missing or invalid")
	var candidate: Dictionary = parsed
	if str(candidate.get("format", "")) != FORMAT \
			or int(candidate.get("formatVersion", 0)) != FORMAT_VERSION:
		return _fail("Unsupported pre-release scenario package; re-export it from Providence")
	var loaded_campaign_kind := str(candidate.get("campaignKind", ""))
	if loaded_campaign_kind not in CAMPAIGN_KINDS:
		return _fail("Unsupported scenario campaign kind '%s'" % loaded_campaign_kind)
	if loaded_campaign_kind != "remake-authored":
		implementation = ClassicBundleScript.new()
		if not implementation.load_from_directory(directory):
			return _fail(str(implementation.last_error))
		root_directory = str(implementation.root_directory)
		manifest = implementation.manifest
		documents = implementation.documents
		return true
	manifest = candidate
	return _load_remake_authored()


func campaign_kind() -> String:
	return str(manifest.get("campaignKind", ""))


func package_hash() -> String:
	if implementation != null:
		return implementation.package_hash()
	var integrity: Variant = manifest.get("integrity", {})
	return str(integrity.get("packageHash", "")) if integrity is Dictionary else ""


func resolve_package_path(relative_path: String) -> String:
	if implementation != null and implementation.has_method("resolve_package_path"):
		return str(implementation.call("resolve_package_path", relative_path))
	if not _safe_relative_path(relative_path):
		return ""
	return root_directory.path_join(relative_path)


func get_start() -> Dictionary:
	if implementation != null:
		return implementation.get_start()
	var startup: Variant = documents.get("scenario", {}).get("startup", {})
	if not (startup is Dictionary):
		return {}
	var parsed := _parse_map_id(str(startup.get("mapId", "land:0")))
	if parsed.is_empty():
		return {}
	return {
		"levelType": parsed["levelType"],
		"levelIndex": parsed["levelIndex"],
		"x": int(startup.get("x", 0)),
		"y": int(startup.get("y", 0)),
	}


func start_location() -> Dictionary:
	return get_start()


func get_random_level(level_type: String, level_index: int) -> Dictionary:
	if implementation != null:
		return implementation.get_random_level(level_type, level_index)
	for value: Variant in documents.get("maps", {}).get("randomLevels", []):
		if not (value is Dictionary):
			continue
		var record: Dictionary = value
		if str(record.get("levelType", "")) == level_type \
				and int(record.get("levelIndex", record.get("index", -1))) == level_index:
			return record
	return {}


func get_extra_code(record_id: int) -> Dictionary:
	if implementation != null:
		return implementation.get_extra_code(record_id)
	return {}


func get_message(message_id: int) -> Dictionary:
	if implementation != null:
		return implementation.get_message(message_id)
	return _record_by_numeric_id(
		documents.get("content", {}).get("messages", []),
		absi(message_id)
	)


func get_battle(battle_id: int) -> Dictionary:
	if implementation != null:
		return implementation.get_battle(battle_id)
	return _record_by_numeric_id(
		documents.get("content", {}).get("battles", []),
		absi(battle_id)
	)


func get_scenario_item(item_id: int) -> Dictionary:
	if implementation != null:
		return implementation.get_scenario_item(item_id)
	return _record_by_numeric_id(
		documents.get("content", {}).get("items", []),
		absi(item_id)
	)


func get_item_text(item_id: int) -> Dictionary:
	if implementation != null:
		return implementation.get_item_text(item_id)
	return _record_by_numeric_id(
		documents.get("content", {}).get("itemTexts", []),
		absi(item_id)
	)


func is_empty_scenario_item(item_id: int) -> bool:
	if implementation != null:
		return implementation.is_empty_scenario_item(item_id)
	var record := get_scenario_item(item_id)
	if record.is_empty():
		return false
	for key: Variant in record:
		if str(key) in ["id", "itemId", "authored", "provenance", "rawBytes"]:
			continue
		var value: Variant = record[key]
		if value is bool and value:
			return false
		if (value is int or value is float) and value != 0:
			return false
		if value is String and not value.strip_edges().is_empty():
			return false
		if (value is Array or value is Dictionary) and not value.is_empty():
			return false
	return get_item_text(item_id).is_empty()


func _load_remake_authored() -> bool:
	var forbidden_payload := _find_forbidden_payload(root_directory)
	if not forbidden_payload.is_empty():
		return _fail(
			"Scenario package contains unsupported executable payload '%s'"
				% forbidden_payload
		)
	var files: Variant = manifest.get("files")
	if not (files is Dictionary):
		return _fail("Scenario package file map is invalid")
	for alias: String in REQUIRED_AUTHORED_DOCUMENTS:
		if not files.has(alias):
			return _fail("Scenario package is missing file mapping '%s'" % alias)
	if not _validate_integrity(files):
		return false
	for alias_value: Variant in files:
		var alias := str(alias_value)
		var relative_path := str(files[alias_value])
		if not _safe_relative_path(relative_path):
			return _fail("Scenario package path '%s' is unsafe" % relative_path)
		var document: Variant = _read_json(root_directory.path_join(relative_path))
		if not (document is Dictionary):
			return _fail("Scenario package document '%s' is invalid" % relative_path)
		documents[alias] = document
	var logic: Variant = documents.get("remakeLogic")
	var scripts: Variant = documents.get("remakeScripts")
	if not (logic is Dictionary) \
			or int(logic.get("schemaVersion", 0)) != DOCUMENT_SCHEMA_VERSION:
		return _fail("Scenario logic document schema is unsupported")
	if not (scripts is Dictionary) \
			or int(scripts.get("schemaVersion", 0)) != ScenarioScriptRuntimeScript.SCHEMA_VERSION:
		return _fail("Scenario script document schema is unsupported")
	if _contains_classic_instruction_data(logic) \
			or _contains_classic_instruction_data(scripts):
		return _fail("Remake Authored documents contain forbidden Classic instruction data")
	var script_validation: Dictionary = ScenarioScriptRuntimeScript.validate_document(
		scripts,
		self
	)
	if not bool(script_validation.get("valid", false)):
		return _fail(str(script_validation.get(
			"message",
			"Remake scenario scripts are invalid"
		)))
	if not _validate_script_sources():
		return false
	_index_authored_rules()
	return true


func _validate_integrity(files: Dictionary) -> bool:
	var integrity: Variant = manifest.get("integrity")
	if not (integrity is Dictionary) or str(integrity.get("algorithm", "")) != "sha256":
		return _fail("Scenario package integrity contract is invalid")
	var indexed: Variant = integrity.get("files")
	if not (indexed is Dictionary):
		return _fail("Scenario package integrity file index is invalid")
	var package_paths: Variant = _package_file_paths(root_directory)
	if not (package_paths is Array):
		return false
	var actual_paths: Dictionary = {}
	for relative_path_value: Variant in package_paths:
		var relative_path := str(relative_path_value)
		if relative_path == "campaign.json":
			continue
		if not _safe_relative_path(relative_path):
			return _fail("Scenario package path '%s' is unsafe" % relative_path)
		if not indexed.has(relative_path):
			return _fail("Scenario package integrity omits '%s'" % relative_path)
		actual_paths[relative_path] = true
	for indexed_path_value: Variant in indexed:
		var relative_path := str(indexed_path_value)
		if not _safe_relative_path(relative_path):
			return _fail("Scenario package path '%s' is unsafe" % relative_path)
		if not actual_paths.has(relative_path):
			return _fail("Scenario package indexed file '%s' is missing" % relative_path)
		var descriptor: Variant = indexed[indexed_path_value]
		if not (descriptor is Dictionary):
			return _fail("Scenario package integrity entry '%s' is invalid" % relative_path)
		var bytes := FileAccess.get_file_as_bytes(root_directory.path_join(relative_path))
		if bytes.size() != int(descriptor.get("bytes", -1)):
			return _fail("Scenario package file '%s' has the wrong size" % relative_path)
		if _sha256(bytes) != str(descriptor.get("sha256", "")).to_lower():
			return _fail("Scenario package file '%s' failed its hash check" % relative_path)
	for alias_value: Variant in files:
		var document_path := str(files[alias_value])
		if not indexed.has(document_path):
			return _fail("Scenario package integrity omits '%s'" % document_path)
	var expected_package_hash := str(integrity.get("packageHash", "")).to_lower()
	var manifest_without_hash := manifest.duplicate(true)
	manifest_without_hash["integrity"].erase("packageHash")
	if _sha256(JSON.stringify(_canonical_value(manifest_without_hash)).to_utf8_buffer()) \
			!= expected_package_hash:
		return _fail("Scenario package manifest hash is invalid")
	return true


func _validate_script_sources() -> bool:
	var scripts: Dictionary = documents.get("remakeScripts", {})
	var behaviors: Variant = scripts.get("behaviors", [])
	if not (behaviors is Array):
		return _fail("Scenario behavior manifest is invalid")
	var integrity: Dictionary = manifest.get("integrity", {})
	var indexed: Dictionary = integrity.get("files", {})
	var declared_sources: Dictionary = {}
	for behavior_value: Variant in behaviors:
		if not (behavior_value is Dictionary):
			return _fail("Scenario behavior manifest entry is invalid")
		var behavior: Dictionary = behavior_value
		var tier := str(behavior.get("tier", ""))
		var source_path := str(behavior.get("sourcePath", ""))
		if tier == "safe":
			if not source_path.is_empty():
				return _fail("Safe behavior cannot declare GDScript source")
			continue
		if tier != "sandboxed":
			return _fail("Scenario behavior execution tier is unsupported")
		if not _safe_source_path(source_path) or declared_sources.has(source_path):
			return _fail("Sandboxed behavior source path is invalid or duplicated")
		if not indexed.has(source_path):
			return _fail("Sandboxed behavior source is missing from package integrity")
		if str(indexed[source_path].get("sha256", "")).to_lower() \
				!= str(behavior.get("contentHash", "")).to_lower():
			return _fail("Sandboxed behavior source hash does not match its manifest")
		declared_sources[source_path] = true
	for indexed_path_value: Variant in indexed:
		var indexed_path := str(indexed_path_value)
		if indexed_path.to_lower().ends_with(".gd") \
				and not declared_sources.has(indexed_path):
			return _fail("Scenario package contains undeclared GDScript source")
	return true


func _package_file_paths(directory: String, prefix := "") -> Variant:
	var access := DirAccess.open(directory)
	if access == null:
		_fail("Scenario package directory cannot be inspected")
		return null
	var result: Array = []
	access.list_dir_begin()
	var name := access.get_next()
	while not name.is_empty():
		if name not in [".", ".."]:
			if access.is_link(name):
				access.list_dir_end()
				_fail("Scenario package contains a symbolic link")
				return null
			var relative_path := name if prefix.is_empty() else prefix.path_join(name)
			if access.current_is_dir():
				if prefix.is_empty() and name in MATERIALIZED_RUNTIME_DIRECTORIES:
					name = access.get_next()
					continue
				var child: Variant = _package_file_paths(
					directory.path_join(name),
					relative_path
				)
				if not (child is Array):
					access.list_dir_end()
					return null
				result.append_array(child)
			else:
				result.append(relative_path.replace("\\", "/"))
		name = access.get_next()
	access.list_dir_end()
	result.sort()
	return result


func _find_forbidden_payload(directory: String, prefix := "") -> String:
	var access := DirAccess.open(directory)
	if access == null:
		return ""
	access.list_dir_begin()
	var name := access.get_next()
	while not name.is_empty():
		if name not in [".", ".."]:
			var relative_path := name if prefix.is_empty() else prefix.path_join(name)
			if access.is_link(name):
				access.list_dir_end()
				return relative_path
			if access.current_is_dir():
				var child := _find_forbidden_payload(
					directory.path_join(name),
					relative_path
				)
				if not child.is_empty():
					access.list_dir_end()
					return child
			else:
				var lower := name.to_lower()
				for extension: String in FORBIDDEN_EXTENSIONS:
					if lower.ends_with(extension):
						access.list_dir_end()
						return relative_path
		name = access.get_next()
	access.list_dir_end()
	return ""


func _safe_relative_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.is_empty() or normalized.begins_with("/") or normalized.contains("../"):
		return false
	var lower := normalized.to_lower()
	for extension: String in FORBIDDEN_EXTENSIONS:
		if lower.ends_with(extension):
			return false
	return true


func _safe_source_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	return normalized.begins_with("remake/source/") \
		and normalized.ends_with(".gd") \
		and not normalized.contains("..") \
		and not normalized.is_absolute_path() \
		and not normalized.contains(":")


func _contains_classic_instruction_data(value: Variant) -> bool:
	if value is Array:
		for child: Variant in value:
			if _contains_classic_instruction_data(child):
				return true
	elif value is Dictionary:
		if str(value.get("kind", "")) == "classic":
			return true
		for key: Variant in value:
			if str(key) in ["rawCode", "classicCode", "extraCodeRow"]:
				return true
			if _contains_classic_instruction_data(value[key]):
				return true
	return false


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var parser := JSON.new()
	return parser.data if parser.parse(FileAccess.get_file_as_string(path)) == OK else null


func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _canonical_value(value: Variant) -> Variant:
	if value is float and value == floor(value):
		return int(value)
	if value is Array:
		var result_array: Array = []
		for child: Variant in value:
			result_array.append(_canonical_value(child))
		return result_array
	if value is Dictionary:
		var result_dictionary: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			result_dictionary[str(key)] = _canonical_value(value[key])
		return result_dictionary
	return value


func _index_authored_rules() -> void:
	spell_overrides_by_id.clear()
	for value: Variant in documents.get("rules", {}).get("spellOverrides", []):
		if value is Dictionary:
			var record: Dictionary = value
			var record_id := int(record.get("spellId", record.get("id", 0)))
			if record_id != 0:
				spell_overrides_by_id[record_id] = record


static func _record_by_numeric_id(records: Variant, record_id: int) -> Dictionary:
	if not (records is Array):
		return {}
	for value: Variant in records:
		if not (value is Dictionary):
			continue
		var record: Dictionary = value
		if int(record.get("id", record.get("itemId", -1))) == record_id:
			return record
	return {}


static func _parse_map_id(map_id: String) -> Dictionary:
	var parts := map_id.split(":", false, 1)
	if parts.size() != 2 \
			or str(parts[0]) not in ["land", "dungeon"] \
			or not str(parts[1]).is_valid_int():
		return {}
	return {
		"levelType": str(parts[0]),
		"levelIndex": int(parts[1]),
	}


func _reset() -> void:
	if implementation != null and implementation.has_method("clear"):
		implementation.call("clear")
	implementation = null
	root_directory = ""
	manifest.clear()
	documents.clear()
	spell_overrides_by_id.clear()
	last_error = ""


func _fail(message: String) -> bool:
	last_error = message
	return false
