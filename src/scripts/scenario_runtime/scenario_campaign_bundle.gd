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
const DOCUMENT_SCHEMA_VERSION := 3
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

var implementation: Object
var root_directory := ""
var manifest: Dictionary = {}
var documents: Dictionary = {}
var last_error := ""


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
	var campaign_kind := str(candidate.get("campaignKind", ""))
	if campaign_kind not in CAMPAIGN_KINDS:
		return _fail("Unsupported scenario campaign kind '%s'" % campaign_kind)
	if campaign_kind != "remake-authored":
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


func _load_remake_authored() -> bool:
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


func _reset() -> void:
	if implementation != null and implementation.has_method("clear"):
		implementation.call("clear")
	implementation = null
	root_directory = ""
	manifest.clear()
	documents.clear()
	last_error = ""


func _fail(message: String) -> bool:
	last_error = message
	return false
