class_name ClassicCampaignBundle
extends RefCounted

const SharedAssetStoreScript = preload(
	"res://scripts/classic_runtime/classic_shared_asset_store.gd"
)
const ExtensionRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_extension_registry.gd"
)
const ScenarioScriptRuntimeScript = preload(
	"res://scripts/scenario_runtime/scenario_script_runtime.gd"
)

const FORMAT := "realmz-remake-scenario"
const FORMAT_VERSION := 3
const CAMPAIGN_KIND_CLASSIC_INTERPRETED := "classic-interpreted"
const CAMPAIGN_KIND_CLASSIC_ENHANCED := "classic-enhanced"
const CLASSIC_CAMPAIGN_KINDS := [
	CAMPAIGN_KIND_CLASSIC_INTERPRETED,
	CAMPAIGN_KIND_CLASSIC_ENHANCED,
]
# Kept as the default fixture kind while callers migrate to the explicit constants.
const CAMPAIGN_KIND := CAMPAIGN_KIND_CLASSIC_INTERPRETED
const COMPATIBILITY_PROFILE := "realmz-7.1"
const DOCUMENT_SCHEMA_VERSION := 3
const RUNTIME_DOCUMENT_SCHEMA_VERSION := 3
const RULE_TABLE_SOURCES := ["shared", "scenario-local", "unresolved"]
const CLASSIC_DOCUMENTS := [
	"scenario",
	"maps",
	"scripts",
	"encounters",
	"content",
	"rules",
	"assets",
	"runtime",
	"remakeScripts",
]

var root_directory := ""
var campaign_kind := ""
var manifest: Dictionary = {}
var documents: Dictionary = {}
var last_error := ""

var triggers_by_id: Dictionary = {}
var extra_action_points_by_id: Dictionary = {}
var triggers_by_coordinate: Dictionary = {}
var extra_codes_by_id: Dictionary = {}
var messages_by_id: Dictionary = {}
var option_labels_by_id: Dictionary = {}
var battles_by_id: Dictionary = {}
var treasures_by_id: Dictionary = {}
var shops_by_id: Dictionary = {}
var scenario_items_by_id: Dictionary = {}
var item_texts_by_id: Dictionary = {}
var monsters_by_id: Dictionary = {}
var monsters_by_name_id: Dictionary = {}
var simple_encounters_by_id: Dictionary = {}
var complex_encounters_by_id: Dictionary = {}
var thief_encounters_by_id: Dictionary = {}
var timed_encounters_by_id: Dictionary = {}
var spell_overrides_by_id: Dictionary = {}
var spell_overrides_by_record_id: Dictionary = {}
var spell_overrides_by_record_reference: Dictionary = {}
var maps_by_id: Dictionary = {}
var player_maps_by_id: Dictionary = {}
var scrolling_texts_by_id: Dictionary = {}
var random_levels_by_id: Dictionary = {}
var pictures_by_id: Dictionary = {}
var sounds_by_id: Dictionary = {}
var dispatcher_noop_keys: Dictionary = {}
var extension_registry: ScenarioExtensionRegistry
var _evidence_records_by_key: Dictionary = {}
var _evidence_loaded := false


func _required_documents() -> Array[String]:
	var required: Array[String] = []
	required.assign(CLASSIC_DOCUMENTS)
	if campaign_kind == CAMPAIGN_KIND_CLASSIC_ENHANCED:
		required.append("remakeLogic")
	return required


func _required_manifest_files() -> Array[String]:
	var required := _required_documents()
	required.append("evidence")
	return required


func load_from_directory(directory: String) -> bool:
	_reset()
	root_directory = directory.trim_suffix("/").trim_suffix("\\")
	var manifest_value: Variant = _read_json(root_directory.path_join("campaign.json"))
	if not (manifest_value is Dictionary):
		return _fail("campaign.json must contain a JSON object")
	manifest = manifest_value
	if not _validate_manifest_contract():
		return false
	if not _validate_integrity():
		return false
	extension_registry = ExtensionRegistryScript.new()
	if not extension_registry.load_builtin_catalog():
		return _fail(extension_registry.last_error)

	var file_map: Variant = manifest.get("files", {})
	for document_name: String in _required_documents():
		var document_value: Variant = _read_json(
			root_directory.path_join(str(file_map[document_name]))
		)
		if not (document_value is Dictionary):
			return _fail("The '%s' classic document must contain a JSON object" % document_name)
		documents[document_name] = document_value

	if not _validate_document_contract():
		return false
	_build_indexes()
	return true


func _validate_manifest_contract() -> bool:
	if str(manifest.get("format", "")) != FORMAT:
		return _fail(
			"Unsupported scenario campaign format: %s" % manifest.get("format", "<missing>")
		)
	var format_version: Variant = manifest.get("formatVersion")
	if not _is_integer(format_version) or int(format_version) != FORMAT_VERSION:
		return _fail(
			"Unsupported scenario campaign format version: %s" % \
				manifest.get("formatVersion", "<missing>")
		)
	campaign_kind = str(manifest.get("campaignKind", ""))
	if campaign_kind not in CLASSIC_CAMPAIGN_KINDS:
		return _fail(
			"campaign.json campaignKind must be '%s' or '%s'" % [
				CAMPAIGN_KIND_CLASSIC_INTERPRETED,
				CAMPAIGN_KIND_CLASSIC_ENHANCED,
			]
		)
	if str(manifest.get("compatibilityProfile", "")) != COMPATIBILITY_PROFILE:
		return _fail(
			"Unsupported classic compatibility profile: %s" % \
			manifest.get("compatibilityProfile", "<missing>")
		)
	for field_name: String in ["id", "name"]:
		var identity_value: Variant = manifest.get(field_name)
		if not (identity_value is String) or identity_value.strip_edges().is_empty():
			return _fail("campaign.json is missing the '%s' identity field" % field_name)

	var start: Variant = manifest.get("start", {})
	if not (start is Dictionary):
		return _fail("campaign.json start must be a JSON object")
	if str(start.get("levelType", "")) not in ["land", "dungeon"]:
		return _fail("campaign.json start.levelType must be 'land' or 'dungeon'")
	for field_name: String in ["levelIndex", "x", "y"]:
		if not _is_nonnegative_integer(start.get(field_name)):
			return _fail("campaign.json start.%s must be a non-negative integer" % field_name)

	var file_map: Variant = manifest.get("files", {})
	if not (file_map is Dictionary):
		return _fail("campaign.json files must be a JSON object")
	var seen_paths: Dictionary = {}
	for document_name: String in _required_manifest_files():
		if not file_map.has(document_name):
			return _fail("campaign.json is missing the '%s' document path" % document_name)
		var path_value: Variant = file_map[document_name]
		if not (path_value is String):
			return _fail("campaign.json files.%s must be a string" % document_name)
		var document_path: String = path_value
		if not _is_safe_document_path(document_path):
			return _fail(
				"campaign.json files.%s must be a campaign-relative JSON path" % document_name
			)
		var normalized_path := document_path.replace("\\", "/")
		var path_key := normalized_path.to_lower()
		if seen_paths.has(path_key):
			return _fail(
				"campaign.json files.%s duplicates the path used by '%s'" % [
					document_name,
					seen_paths[path_key],
				]
			)
		seen_paths[path_key] = document_name
	var shared_asset_error := SharedAssetStoreScript.validate_manifest_section(manifest)
	if not shared_asset_error.is_empty():
		return _fail(shared_asset_error)
	return true


func _validate_integrity() -> bool:
	var integrity: Variant = manifest.get("integrity")
	if not (integrity is Dictionary):
		return _fail("campaign.json integrity must be a JSON object")
	if str(integrity.get("algorithm", "")) != "sha256":
		return _fail("campaign.json integrity.algorithm must be sha256")
	var entries: Variant = integrity.get("files")
	if not (entries is Dictionary) or entries.is_empty():
		return _fail("campaign.json integrity.files must describe the package payload")
	for required_name: String in _required_manifest_files():
		var required_path := str(manifest["files"].get(required_name, ""))
		if not entries.has(required_path):
			return _fail(
				"campaign.json integrity.files is missing '%s'" % required_path
			)
	var paths: Array = entries.keys()
	paths.sort()
	for path_value: Variant in paths:
		var relative_path := str(path_value)
		if not _is_safe_campaign_path(relative_path):
			return _fail("Bundle integrity path is unsafe: %s" % relative_path)
		var descriptor: Variant = entries[relative_path]
		if not (descriptor is Dictionary):
			return _fail("Bundle integrity entry '%s' must be an object" % relative_path)
		var expected_bytes: Variant = descriptor.get("bytes")
		var expected_sha := str(descriptor.get("sha256", "")).to_lower()
		if not _is_nonnegative_integer(expected_bytes) or expected_sha.length() != 64:
			return _fail("Bundle integrity entry '%s' is invalid" % relative_path)
		var absolute_path := root_directory.path_join(relative_path)
		if not FileAccess.file_exists(absolute_path):
			return _fail("Missing campaign payload: %s" % relative_path)
		var payload := FileAccess.get_file_as_bytes(absolute_path)
		if payload.size() != int(expected_bytes):
			return _fail("Campaign payload size mismatch: %s" % relative_path)
		var actual_sha := _sha256_hex(payload)
		if actual_sha != expected_sha:
			return _fail("Campaign payload hash mismatch: %s" % relative_path)
	var manifest_without_hash: Dictionary = manifest.duplicate(true)
	manifest_without_hash["integrity"].erase("packageHash")
	var canonical_manifest := JSON.stringify(_canonical_value(manifest_without_hash))
	var actual_package_hash := _sha256_hex(canonical_manifest.to_utf8_buffer())
	if actual_package_hash != str(integrity.get("packageHash", "")).to_lower():
		return _fail(
			"Campaign package hash does not match its canonical manifest "
			+ "(expected %s, calculated %s)" % [
				str(integrity.get("packageHash", "")).to_lower(),
				actual_package_hash,
			]
		)
	return true


func package_hash() -> String:
	var integrity: Variant = manifest.get("integrity", {})
	return str(integrity.get("packageHash", "")) if integrity is Dictionary else ""


static func _canonical_value(value: Variant) -> Variant:
	if value is float and value == floor(value):
		return int(value)
	if value is Array:
		var array: Array = []
		for child: Variant in value:
			array.append(_canonical_value(child))
		return array
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			result[str(key)] = _canonical_value(value[key])
		return result
	return value


func declared_script_sources() -> Dictionary:
	var result: Dictionary = {}
	var script_document: Variant = documents.get("remakeScripts", {})
	if not (script_document is Dictionary):
		return result
	for script_value: Variant in script_document.get("scripts", []):
		if not (script_value is Dictionary):
			continue
		var source_path := str(script_value.get("sourcePath", ""))
		if not source_path.is_empty():
			result[source_path] = str(script_value.get("tier", ""))
	return result


func evidence_record(record_kind: String, stable_id: Variant) -> Dictionary:
	_load_evidence_for_debug()
	var record: Variant = _evidence_records_by_key.get(
		_evidence_record_key(record_kind, stable_id),
		{}
	)
	return record if record is Dictionary else {}


func _load_evidence_for_debug() -> void:
	if _evidence_loaded:
		return
	_evidence_loaded = true
	if root_directory.is_empty():
		return
	var file_map: Variant = manifest.get("files", {})
	if not (file_map is Dictionary):
		return
	var evidence_path := root_directory.path_join(str(file_map.get("evidence", "")))
	if not FileAccess.file_exists(evidence_path):
		return
	var evidence_value: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(evidence_path)
	)
	if not (evidence_value is Dictionary):
		return
	var catalog: Variant = evidence_value.get("recordCatalog", {})
	if not (catalog is Dictionary) or not (catalog.get("records") is Array):
		return
	for record_value: Variant in catalog["records"]:
		if not (record_value is Dictionary):
			continue
		var record_kind := str(record_value.get("kind", ""))
		var stable_id: Variant = record_value.get("id")
		if record_kind.is_empty() or stable_id == null:
			continue
		_evidence_records_by_key[
			_evidence_record_key(record_kind, stable_id)
		] = record_value


func _evidence_record_key(record_kind: String, stable_id: Variant) -> String:
	var canonical_id := str(stable_id)
	if stable_id is float and is_equal_approx(stable_id, float(int(stable_id))):
		canonical_id = str(int(stable_id))
	return "%s:%s" % [record_kind, canonical_id]


func _validate_document_contract() -> bool:
	if extension_registry == null:
		extension_registry = ExtensionRegistryScript.new()
		if not extension_registry.load_builtin_catalog():
			return _fail(extension_registry.last_error)
	for document_name: String in _required_documents():
		var document: Variant = documents.get(document_name, {})
		if not (document is Dictionary):
			return _fail("The '%s' classic document must contain a JSON object" % document_name)
		var schema_version: Variant = document.get("schemaVersion")
		var expected_schema_version := (
			ScenarioScriptRuntimeScript.SCHEMA_VERSION
			if document_name == "remakeScripts"
			else DOCUMENT_SCHEMA_VERSION
		)
		if not _is_integer(schema_version) or int(schema_version) != expected_schema_version:
			return _fail(
				"%s.schemaVersion must be %d, got %s" % [
					document_name,
					expected_schema_version,
					document.get("schemaVersion", "<missing>"),
				]
			)

	if not _validate_scenario_identity():
		return false
	if not _validate_scenario_selection_metadata():
		return false
	if not _validate_runtime_document():
		return false
	if campaign_kind == CAMPAIGN_KIND_CLASSIC_ENHANCED \
			and not _validate_remake_logic_document():
		return false
	var script_validation: Dictionary = ScenarioScriptRuntimeScript.validate_document(
		documents.get("remakeScripts"),
		self
	)
	if not bool(script_validation.get("valid", false)):
		return _fail(str(script_validation.get(
			"message",
			"Remake scenario scripts are invalid"
		)))
	if not _validate_rule_table_selection():
		return false
	for specification: Array in [
		["scripts", "triggers", "id", true],
		["scripts", "extraCodes", "id", false],
		["scripts", "messages", "id", false],
		["scripts", "optionLabels", "id", false],
		["scripts", "randomLevels", "id", true],
		["encounters", "battles", "id", false],
		["encounters", "treasures", "id", false],
		["encounters", "shops", "id", false],
		["encounters", "simpleEncounters", "id", false],
		["encounters", "complexEncounters", "id", false],
		["encounters", "thiefEncounters", "id", false],
		["encounters", "timedEncounters", "id", false],
		["content", "monsters", "id", false],
		["content", "scenarioItems", "id", false],
		["content", "itemTexts", "itemId", false],
		["rules", "spellOverrides", "id", false],
		["rules", "raceOverrides", "id", false],
		["rules", "casteOverrides", "id", false],
		["maps", "maps", "id", true],
		["assets", "managedAssets", "id", true],
	]:
		if not _validate_record_collection(
			str(specification[0]),
			str(specification[1]),
			str(specification[2]),
			bool(specification[3])
		):
			return false
	if not _validate_nested_record_collection(
		"assets",
		documents["assets"],
		"scrollingTexts",
		"resourceId",
		false,
		true
	):
		return false
	if not _validate_spell_override_identities():
		return false
	if not _validate_trigger_actions():
		return false
	for collection_name: String in ["simpleEncounters", "complexEncounters"]:
		if not _validate_encounter_actions(collection_name):
			return false
	for collection_name: String in ["battles", "simpleEncounters", "complexEncounters"]:
		if not _validate_optional_callability(collection_name):
			return false
	if documents["maps"].has("mapRecords") and not _validate_record_collection(
		"maps", "mapRecords", "id", false
	):
		return false
	if not _validate_scrolling_text_player_maps():
		return false

	var catalog: Variant = documents["assets"].get("catalog", {})
	if not (catalog is Dictionary):
		return _fail("assets.catalog must be a JSON object")
	for specification: Array in [
		["tilesets", "id", true],
		["pictures", "resourceId", false],
		["icons", "resourceId", false],
		["sounds", "resourceId", false],
	]:
		if not _validate_nested_record_collection(
			"assets.catalog",
			catalog,
			str(specification[0]),
			str(specification[1]),
			bool(specification[2])
		):
			return false
	if not _validate_nested_record_collection(
		"assets.catalog", catalog, "specialLandTiles", "resourceId", false, true
	):
		return false
	if not _validate_media_paths_in_collection(
		"assets", documents["assets"], "managedAssets", ""
	):
		return false
	for media_specification: Array in [
		["tilesets", "image/"],
		["pictures", "image/"],
		["icons", "image/"],
		["sounds", "audio/"],
		["specialLandTiles", "image/"],
	]:
		if not _validate_media_paths_in_collection(
			"assets.catalog",
			catalog,
			str(media_specification[0]),
			str(media_specification[1])
		):
			return false
	if not _validate_media_paths_in_collection(
		"maps", documents["maps"], "mapRecords", "image/"
	):
		return false

	var dispatcher_noops: Variant = documents["scripts"].get("dispatcherNoops", [])
	if not _validate_dispatcher_noops({"dispatcherNoops": dispatcher_noops}):
		return false
	return true


func _validate_scrolling_text_player_maps() -> bool:
	var asset_records: Array = documents["assets"].get("scrollingTexts", [])
	for index: int in range(asset_records.size()):
		var asset_context := "assets.scrollingTexts[%d]" % index
		var asset_record: Variant = asset_records[index]
		if not (asset_record is Dictionary):
			return _fail("%s must be a JSON object" % asset_context)
		if not _validate_scrolling_text_record(asset_context, asset_record):
			return false

	var records: Array = documents["maps"].get("mapRecords", [])
	for index: int in range(records.size()):
		var record: Dictionary = records[index]
		if not record.has("scrollingText"):
			continue
		var record_context := "maps.mapRecords[%d].scrollingText" % index
		var scrolling_text: Variant = record.get("scrollingText")
		if not (scrolling_text is Dictionary):
			return _fail("%s must be a JSON object" % record_context)
		if not _validate_scrolling_text_record(
			record_context,
			scrolling_text,
			record.get("show", 0)
		):
			return false
	return true


func _validate_scrolling_text_record(
	context: String,
	scrolling_text: Dictionary,
	expected_resource_id: Variant = null
) -> bool:
	if str(scrolling_text.get("resourceType", "")) != "TEXT":
		return _fail("%s.resourceType must be TEXT" % context)
	if not _is_integer(scrolling_text.get("resourceId")):
		return _fail("%s.resourceId must be an integer" % context)
	if expected_resource_id != null \
			and int(scrolling_text["resourceId"]) != int(expected_resource_id):
		return _fail("%s.resourceId must match the map record show value" % context)
	if not (scrolling_text.get("text") is String):
		return _fail("%s.text must be a string" % context)
	if not _validate_classic_payload_reference(context, scrolling_text):
		return false
	if not scrolling_text.has("presentation"):
		return true
	return _validate_scrolling_text_presentation(
		"%s.presentation" % context,
		scrolling_text["presentation"],
		str(scrolling_text["text"]).length()
	)


func _validate_scrolling_text_presentation(
	context: String,
	presentation_value: Variant,
	text_length: int
) -> bool:
	if not (presentation_value is Dictionary):
		return _fail("%s must be a JSON object" % context)
	var presentation: Dictionary = presentation_value
	if str(presentation.get("format", "")) != "portable-rich-text-v1":
		return _fail("%s.format must be portable-rich-text-v1" % context)
	var runs_value: Variant = presentation.get("runs")
	if not (runs_value is Array):
		return _fail("%s.runs must be a JSON array" % context)
	var previous_end := 0
	for index: int in range(runs_value.size()):
		var run_context := "%s.runs[%d]" % [context, index]
		var run_value: Variant = runs_value[index]
		if not (run_value is Dictionary):
			return _fail("%s must be a JSON object" % run_context)
		var run: Dictionary = run_value
		if not _is_nonnegative_integer(run.get("start")) \
				or not _is_nonnegative_integer(run.get("end")):
			return _fail("%s start and end must be non-negative integers" % run_context)
		var start := int(run["start"])
		var end := int(run["end"])
		if start < previous_end or end <= start or end > text_length:
			return _fail(
				"%s must be ordered, non-overlapping, and within the decoded text" % run_context
			)
		if not _is_integer(run.get("fontId")):
			return _fail("%s.fontId must be an integer" % run_context)
		if not _is_integer(run.get("fontSize")) or int(run["fontSize"]) < 1:
			return _fail("%s.fontSize must be a positive integer" % run_context)
		var color_value: Variant = run.get("color")
		if not (color_value is String) or not _is_hex_color(color_value):
			return _fail("%s.color must be a #RRGGBB value" % run_context)
		for field_name: String in [
			"bold", "italic", "underline", "outline", "shadow",
		]:
			if not (run.get(field_name) is bool):
				return _fail("%s.%s must be a boolean" % [run_context, field_name])
		if str(run.get("stretch", "")) not in ["normal", "condensed", "expanded"]:
			return _fail(
				"%s.stretch must be normal, condensed, or expanded" % run_context
			)
		previous_end = end
	return true


func _validate_classic_payload_reference(context: String, record: Dictionary) -> bool:
	if str(record.get("payloadEncoding", "")) != "classic-resource-data":
		return _fail("%s.payloadEncoding must be classic-resource-data" % context)
	var path_value: Variant = record.get("payloadPath")
	if not (path_value is String) or not _is_safe_campaign_path(path_value):
		return _fail("%s.payloadPath must be a campaign-relative path" % context)
	if not _is_nonnegative_integer(record.get("payloadBytes")):
		return _fail("%s.payloadBytes must be a non-negative integer" % context)
	var sha256_value: Variant = record.get("payloadSha256")
	if not (sha256_value is String) or not _is_sha256(sha256_value):
		return _fail("%s.payloadSha256 must be a 64-digit hexadecimal hash" % context)
	return true


func _validate_scenario_identity() -> bool:
	var identity: Variant = documents["scenario"].get("identity", {})
	if not (identity is Dictionary):
		return _fail("scenario.identity must be a JSON object")
	for field_name: String in ["id", "name"]:
		var identity_value: Variant = identity.get(field_name)
		if not (identity_value is String) or identity_value.strip_edges().is_empty():
			return _fail("scenario.identity.%s must not be empty" % field_name)
		if identity_value.strip_edges() != str(manifest[field_name]).strip_edges():
			return _fail(
				"scenario.identity.%s must match campaign.json %s" % [field_name, field_name]
			)
	return true


func _validate_scenario_selection_metadata() -> bool:
	var scenario: Dictionary = documents["scenario"]
	var shell_value: Variant = scenario.get("shell")
	if shell_value != null:
		if not (shell_value is Dictionary):
			return _fail("scenario.shell must be a JSON object")
		for field_name: String in ["recLevel", "maxLevel"]:
			if shell_value.has(field_name) and not _is_nonnegative_integer(
				shell_value[field_name]
			):
				return _fail("scenario.shell.%s must be a non-negative integer" % field_name)

	var restrictions_value: Variant = scenario.get("restrictions")
	if restrictions_value == null:
		return true
	if not (restrictions_value is Dictionary):
		return _fail("scenario.restrictions must be a JSON object")
	if restrictions_value.has("description") and not (
		restrictions_value["description"] is String
	):
		return _fail("scenario.restrictions.description must be a string")
	for field_name: String in ["maxPartyCharacters", "maxPartyLevel"]:
		if restrictions_value.has(field_name) and not _is_nonnegative_integer(
			restrictions_value[field_name]
		):
			return _fail(
				"scenario.restrictions.%s must be a non-negative integer" % field_name
			)
	for field_name: String in ["bannedRaces", "bannedCastes"]:
		if not _validate_restriction_ids(restrictions_value, field_name):
			return false
	return true


func _validate_restriction_ids(restrictions: Dictionary, field_name: String) -> bool:
	if not restrictions.has(field_name):
		return true
	var ids_value: Variant = restrictions[field_name]
	if not (ids_value is Array):
		return _fail("scenario.restrictions.%s must be an array" % field_name)
	var seen: Dictionary = {}
	for index: int in range(ids_value.size()):
		var id_value: Variant = ids_value[index]
		if not _is_integer(id_value) or int(id_value) < 1 or int(id_value) > 30:
			return _fail(
				"scenario.restrictions.%s[%d] must be an integer from 1 through 30" % [
					field_name,
					index,
				]
			)
		if seen.has(int(id_value)):
			return _fail(
				"scenario.restrictions.%s contains duplicate ID %d" % [
					field_name,
					int(id_value),
				]
			)
		seen[int(id_value)] = true
	return true


func _validate_rule_table_selection() -> bool:
	var rules: Dictionary = documents["rules"]
	if not rules.has("tableSelection"):
		return true
	var selection_value: Variant = rules.get("tableSelection")
	if not (selection_value is Dictionary):
		return _fail("rules.tableSelection must be a JSON object")
	var selection: Dictionary = selection_value
	for specification: Array in [
		["races", "raceOverrides"],
		["castes", "casteOverrides"],
	]:
		var table_name := str(specification[0])
		if not selection.has(table_name):
			continue
		var table_value: Variant = selection[table_name]
		var table_context := "rules.tableSelection.%s" % table_name
		if not (table_value is Dictionary):
			return _fail("%s must be a JSON object" % table_context)
		var table: Dictionary = table_value
		var source := str(table.get("source", ""))
		if source not in RULE_TABLE_SOURCES:
			return _fail(
				"%s.source must be 'shared', 'scenario-local', or 'unresolved'" % \
				table_context
			)
		if not table.has("changedRecordIds"):
			continue
		if source != "scenario-local":
			return _fail(
				"%s.changedRecordIds is only valid for a scenario-local table" % \
				table_context
			)
		var changed_value: Variant = table["changedRecordIds"]
		if not (changed_value is Array):
			return _fail("%s.changedRecordIds must be a JSON array" % table_context)
		var record_ids: Dictionary = {}
		for record: Variant in _array_value(rules, str(specification[1])):
			record_ids[int(record.get("id", -1))] = true
		var seen: Dictionary = {}
		for index: int in range(changed_value.size()):
			var id_value: Variant = changed_value[index]
			if not _is_integer(id_value) or int(id_value) < 0 or int(id_value) > 29:
				return _fail(
					"%s.changedRecordIds[%d] must be an integer from 0 through 29" % [
						table_context,
						index,
					]
				)
			var record_id := int(id_value)
			if seen.has(record_id):
				return _fail(
					"%s.changedRecordIds contains duplicate ID %d" % [
						table_context,
						record_id,
					]
				)
			if not record_ids.has(record_id):
				return _fail(
					"%s.changedRecordIds[%d] references missing override record %d" % [
						table_context,
						index,
						record_id,
					]
				)
			seen[record_id] = true
	return true


func _validate_trigger_actions() -> bool:
	var triggers: Variant = documents["scripts"].get("triggers", [])
	if not (triggers is Array):
		return false
	for trigger_index: int in range(triggers.size()):
		var trigger: Dictionary = triggers[trigger_index]
		var trigger_context := "scripts.triggers[%d]" % trigger_index
		if str(trigger.get("id", "")).strip_edges().is_empty():
			return _fail("%s is missing stable record identity" % trigger_context)
		if trigger.has("callable") and not (trigger["callable"] is bool):
			return _fail("%s.callable must be a boolean" % trigger_context)
		if not _validate_action_array(trigger.get("actions"), trigger_context, 7):
			return false
	return true


func _validate_encounter_actions(collection_name: String) -> bool:
	var encounters: Variant = documents["encounters"].get(collection_name, [])
	if not (encounters is Array):
		return false
	for encounter_index: int in range(encounters.size()):
		var encounter: Dictionary = encounters[encounter_index]
		var encounter_context := "encounters.%s[%d]" % [collection_name, encounter_index]
		if not _validate_action_array(encounter.get("actions"), encounter_context, 31):
			return false
	return true


func _validate_optional_callability(collection_name: String) -> bool:
	var records: Variant = documents["encounters"].get(collection_name, [])
	if not (records is Array):
		return false
	for record_index: int in range(records.size()):
		var record: Dictionary = records[record_index]
		if record.has("callable") and not (record["callable"] is bool):
			return _fail(
				"encounters.%s[%d].callable must be a boolean" % [
					collection_name,
					record_index,
				]
			)
	return true


func _validate_action_array(
	actions_value: Variant,
	record_context: String,
	max_slot: int
) -> bool:
	if not (actions_value is Array):
		return _fail("%s.actions must be a JSON array" % record_context)
	var actions: Array = actions_value
	var seen_slots: Dictionary = {}
	for action_index: int in range(actions.size()):
		var action: Variant = actions[action_index]
		var action_context := "%s.actions[%d]" % [record_context, action_index]
		if not (action is Dictionary):
			return _fail("%s must be a JSON object" % action_context)
		if not _is_nonnegative_integer(action.get("slot")):
			return _fail("%s.slot must be a non-negative integer" % action_context)
		var slot := int(action["slot"])
		if slot > max_slot:
			return _fail("%s.slot must be between 0 and %d" % [action_context, max_slot])
		if seen_slots.has(slot):
			return _fail("%s duplicates action slot %d" % [action_context, slot])
		seen_slots[slot] = action_index
		var kind := str(action.get("kind", ""))
		if kind == "classic":
			for field_name: String in ["rawCode", "code", "id"]:
				if not _is_integer(action.get(field_name)):
					return _fail("%s.%s must be an integer" % [action_context, field_name])
			var raw_code := int(action["rawCode"])
			var expected_code: int = (
				abs(raw_code) if raw_code < 0 and raw_code not in [-14, -23] else raw_code
			)
			if int(action["code"]) != expected_code:
				return _fail(
					"%s.code must preserve normalized rawCode %d" % [
						action_context,
						expected_code,
					]
				)
			var expected_gosub: bool = raw_code < 0 and raw_code not in [-14, -23]
			if not (action.get("gosub") is bool) or bool(action["gosub"]) != expected_gosub:
				return _fail(
					"%s.gosub must preserve the sign semantics of rawCode" % action_context
				)
		elif kind == "semantic":
			var operation: Variant = action.get("operation")
			if not (operation is String) or not _is_namespaced_identifier(operation):
				return _fail("%s.operation must be a namespaced semantic ID" % action_context)
			if str(operation).begins_with("core.") and str(operation) != "core.script.call":
				return _fail("%s.operation cannot target the reserved core namespace" % action_context)
			if not (action.get("parameters") is Dictionary):
				return _fail("%s.parameters must be a JSON object" % action_context)
			if str(operation) == "core.script.call":
				var parameters: Dictionary = action.get("parameters")
				if str(parameters.get("behaviorId", "")).is_empty() \
						or not (parameters.get("argumentBindings", {}) is Dictionary):
					return _fail(
						"%s core.script.call requires a behavior ID and argument bindings"
						% action_context
					)
			else:
				var semantic_validation := extension_registry.validate_semantic_operation(
					str(operation),
					action.get("parameters"),
					_runtime_extension_ids()
				)
				if not bool(semantic_validation.get("valid", false)):
					return _fail(
						"%s: %s" % [
							action_context,
							semantic_validation.get("message", "Invalid semantic operation"),
						]
					)
		else:
			return _fail("%s.kind must be 'classic' or 'semantic'" % action_context)
		if action.has("mediaRequiredForProgression") \
				and not (action["mediaRequiredForProgression"] is bool):
			return _fail(
				"%s.mediaRequiredForProgression must be a boolean" % action_context
			)
	return true


func _validate_runtime_document() -> bool:
	var runtime: Variant = documents.get("runtime")
	if not (runtime is Dictionary):
		return _fail("runtime document must be a JSON object")
	if int(runtime.get("schemaVersion", 0)) != RUNTIME_DOCUMENT_SCHEMA_VERSION:
		return _fail(
			"runtime.schemaVersion must be %d" % RUNTIME_DOCUMENT_SCHEMA_VERSION
		)
	var expected_logic := (
		CAMPAIGN_KIND_CLASSIC_ENHANCED
		if campaign_kind == CAMPAIGN_KIND_CLASSIC_ENHANCED
		else "classic"
	)
	if str(runtime.get("scenarioLogic", "")) != expected_logic:
		return _fail("runtime.scenarioLogic must be '%s'" % expected_logic)
	var recommended_profile: Variant = runtime.get("recommendedGameplayProfile")
	if not (recommended_profile is String) \
			or not _is_namespaced_identifier(recommended_profile):
		return _fail("runtime.recommendedGameplayProfile must be a namespaced preset ID")
	var extension_validation := extension_registry.validate_requirements(
		runtime.get("requiredExtensions")
	)
	if not bool(extension_validation.get("valid", false)):
		return _fail(str(extension_validation.get("message", "Invalid extension requirements")))
	var plugin_requirements: Variant = runtime.get("requiredPlugins", [])
	if not (plugin_requirements is Array):
		return _fail("runtime.requiredPlugins must be an array")
	var plugin_ids: Dictionary = {}
	for plugin_requirement_value: Variant in plugin_requirements:
		if not (plugin_requirement_value is Dictionary):
			return _fail("runtime.requiredPlugins contains an invalid requirement")
		var plugin_requirement: Dictionary = plugin_requirement_value
		var plugin_id := str(plugin_requirement.get("id", ""))
		if not _is_namespaced_identifier(plugin_id) \
				or int(plugin_requirement.get("apiVersion", 0)) <= 0 \
				or plugin_ids.has(plugin_id):
			return _fail(
				"runtime.requiredPlugins needs unique namespaced IDs and API versions"
			)
		plugin_ids[plugin_id] = true
	var bindings: Variant = runtime.get("bindings")
	if not (bindings is Dictionary):
		return _fail("runtime.bindings must be a JSON object")
	for binding_name: String in [
		"spells",
		"items",
		"encounters",
		"monsterAi",
		"lifecycle",
		"ruleModifiers",
	]:
		if not (bindings.get(binding_name) is Dictionary):
			return _fail("runtime.bindings.%s must be a JSON object" % binding_name)
	var capability_by_binding := {
		"spells": "spells",
		"items": "itemBehaviors",
		"encounters": "encounterResolvers",
		"monsterAi": "monsterAiProviders",
		"lifecycle": "lifecycleHooks",
		"ruleModifiers": "gameplayRuleProviders",
	}
	var role_by_binding := {
		"spells": "spell",
		"items": "item",
		"encounters": "encounter",
		"monsterAi": "monster-ai",
		"lifecycle": "lifecycle",
		"ruleModifiers": "rule-modifier",
	}
	var required_extension_ids := _runtime_extension_ids()
	var script_document: Dictionary = documents.get("remakeScripts", {})
	var behavior_ids: Dictionary = {}
	for behavior_value: Variant in script_document.get("behaviors", []):
		if behavior_value is Dictionary:
			behavior_ids[str(behavior_value.get("id", ""))] = str(
				behavior_value.get("role", "")
			)
	for binding_name: String in capability_by_binding:
		for binding_key: Variant in bindings[binding_name]:
			var binding_value: Variant = bindings[binding_name][binding_key]
			if not (binding_value is Dictionary):
				return _fail(
					"runtime.bindings.%s.%s must select a script or extension"
					% [binding_name, binding_key]
				)
			var binding: Dictionary = binding_value
			if str(binding.get("kind", "")) == "script":
				var behavior_id := str(binding.get("behaviorId", ""))
				if not behavior_ids.has(behavior_id):
					return _fail(
						"runtime.bindings.%s.%s references missing behavior '%s'"
						% [binding_name, binding_key, behavior_id]
					)
				if str(behavior_ids[behavior_id]) != str(role_by_binding[binding_name]):
					return _fail(
						"runtime.bindings.%s.%s behavior '%s' has role '%s', not '%s'"
						% [
							binding_name,
							binding_key,
							behavior_id,
							behavior_ids[behavior_id],
							role_by_binding[binding_name],
						]
					)
				continue
			if str(binding.get("kind", "")) != "extension":
				return _fail(
					"runtime.bindings.%s.%s has an unknown implementation kind"
					% [binding_name, binding_key]
				)
			var binding_id := str(binding.get("providerId", ""))
			var binding_validation := extension_registry.validate_binding_reference(
				capability_by_binding[binding_name],
				binding_id,
				required_extension_ids
			)
			if not bool(binding_validation.get("valid", false)):
				return _fail(
					"runtime.bindings.%s.%s: %s" % [
						binding_name,
						binding_key,
						binding_validation.get("message", "Invalid extension binding"),
					]
				)
	var target_support: Variant = runtime.get("targetSupport")
	if not (target_support is Dictionary):
		return _fail("runtime.targetSupport must be a JSON object")
	for target_name: String in ["realmzRemake", "nativeRealmz"]:
		if not (target_support.get(target_name) is bool):
			return _fail("runtime.targetSupport.%s must be a boolean" % target_name)
	if not (target_support.get("remakeOnlyReasons") is Array):
		return _fail("runtime.targetSupport.remakeOnlyReasons must be an array")
	return true


func _validate_remake_logic_document() -> bool:
	var logic: Variant = documents.get("remakeLogic")
	if not (logic is Dictionary):
		return _fail("remake/logic.json must contain a JSON object")
	if int(logic.get("schemaVersion", 0)) != DOCUMENT_SCHEMA_VERSION:
		return _fail(
			"remakeLogic.schemaVersion must be %d" % DOCUMENT_SCHEMA_VERSION
		)
	if str(logic.get("kind", "")) != CAMPAIGN_KIND_CLASSIC_ENHANCED:
		return _fail("remakeLogic.kind must be 'classic-enhanced'")
	for collection_name: String in [
		"replacements",
		"mapTriggers",
		"eventTriggers",
		"scheduledTriggers",
		"encounters",
	]:
		if not (logic.get(collection_name) is Array):
			return _fail("remakeLogic.%s must be an array" % collection_name)
	return true


func _runtime_extension_ids() -> Dictionary:
	var result: Dictionary = {}
	var runtime: Variant = documents.get("runtime", {})
	if not (runtime is Dictionary):
		return result
	var requirements: Variant = runtime.get("requiredExtensions", [])
	if not (requirements is Array):
		return result
	for requirement: Variant in requirements:
		if requirement is Dictionary:
			result[str(requirement.get("id", ""))] = true
	return result


func required_extension_ids() -> Dictionary:
	return _runtime_extension_ids()


func _is_namespaced_identifier(value: String) -> bool:
	var separator := value.find(".")
	return separator > 0 and separator < value.length() - 1


func _validate_record_collection(
	document_name: String,
	collection_name: String,
	identity_field: String,
	string_identity: bool
) -> bool:
	return _validate_nested_record_collection(
		document_name,
		documents[document_name],
		collection_name,
		identity_field,
		string_identity
	)


func _validate_spell_override_identities() -> bool:
	var records: Array = _array_value(documents["rules"], "spellOverrides")
	for index: int in range(records.size()):
		var record: Dictionary = records[index]
		var record_id := int(record.get("id", -1))
		if record_id > 104:
			return _fail(
				"rules.spellOverrides[%d].id must be between 0 and 104" % index
			)
		var expected_packed_id := packed_spell_id_for_record_id(record_id)
		if record.has("packedSpellId") and (
			not _is_integer(record["packedSpellId"])
			or int(record["packedSpellId"]) != expected_packed_id
		):
			return _fail(
				"rules.spellOverrides[%d].packedSpellId must be %d for Data Spell record %d" % [
					index,
					expected_packed_id,
					record_id,
				]
			)
	return true


static func packed_spell_id_for_record_id(record_id: int) -> int:
	return 5101 + floori(float(record_id) / 15.0) * 100 + record_id % 15


func _validate_nested_record_collection(
	context: String,
	container: Dictionary,
	collection_name: String,
	identity_field: String,
	string_identity: bool,
	integer_identity_may_be_negative := false
) -> bool:
	if not container.has(collection_name):
		return true
	var collection: Variant = container.get(collection_name)
	if not (collection is Array):
		return _fail("%s.%s must be a JSON array" % [context, collection_name])
	var seen_identities: Dictionary = {}
	for index: int in range(collection.size()):
		var record: Variant = collection[index]
		var record_context := "%s.%s[%d]" % [context, collection_name, index]
		if not (record is Dictionary):
			return _fail("%s must be a JSON object" % record_context)
		var identity: Variant = record.get(identity_field)
		if string_identity:
			if not (identity is String) or identity.strip_edges().is_empty():
				return _fail("%s is missing stable field '%s'" % [record_context, identity_field])
		else:
			if integer_identity_may_be_negative and not _is_integer(identity):
				return _fail("%s.%s must be an integer" % [record_context, identity_field])
			if not integer_identity_may_be_negative and not _is_nonnegative_integer(identity):
				return _fail(
					"%s.%s must be a non-negative integer" % [record_context, identity_field]
				)
		var identity_key := str(identity)
		if seen_identities.has(identity_key):
			return _fail(
				"%s duplicates %s '%s' from index %d" % [
					record_context,
					identity_field,
					identity_key,
					seen_identities[identity_key],
				]
			)
		seen_identities[identity_key] = index
	return true


func _validate_dispatcher_noops(semantic_decoding: Dictionary) -> bool:
	var rows: Variant = semantic_decoding.get("dispatcherNoops")
	if not (rows is Array):
		return _fail("scripts.dispatcherNoops must be a JSON array")
	for index: int in range(rows.size()):
		var row: Variant = rows[index]
		var context := "scripts.dispatcherNoops[%d]" % index
		if not (row is Dictionary):
			return _fail("%s must be a JSON object" % context)
		if str(row.get("triggerId", "")).strip_edges().is_empty():
			return _fail("%s is missing trigger identity" % context)
		if not _is_nonnegative_integer(row.get("slot")):
			return _fail("%s.slot must be a non-negative integer" % context)
		if not _is_integer(row.get("rawCode")):
			return _fail("%s.rawCode must be an integer" % context)
	return true


func _validate_media_paths_in_collection(
	context: String,
	container: Dictionary,
	collection_name: String,
	expected_media_prefix: String
) -> bool:
	if not container.has(collection_name):
		return true
	var records: Array = container[collection_name]
	for index: int in range(records.size()):
		var record: Dictionary = records[index]
		var record_context := "%s.%s[%d]" % [context, collection_name, index]
		if record.has("payloadPath"):
			var path_value: Variant = record["payloadPath"]
			if not (path_value is String) or not _is_safe_campaign_path(path_value):
				return _fail(
					"%s.payloadPath must be a campaign-relative path" % record_context
				)
		if not _validate_runtime_media(record_context, record, expected_media_prefix):
			return false
	return true


func _validate_runtime_media(
	record_context: String,
	record: Dictionary,
	expected_media_prefix: String
) -> bool:
	if not record.has("runtimeMedia"):
		return true
	var runtime_media: Variant = record.get("runtimeMedia")
	if not (runtime_media is Dictionary):
		return _fail("%s.runtimeMedia must be a JSON object" % record_context)
	var path_value: Variant = runtime_media.get("path")
	if not (path_value is String) or not _is_safe_campaign_path(path_value):
		return _fail(
			"%s.runtimeMedia.path must be a campaign-relative path" % record_context
		)
	var media_type_value: Variant = runtime_media.get("mediaType")
	if not (media_type_value is String) or media_type_value.strip_edges().is_empty():
		return _fail("%s.runtimeMedia.mediaType must not be empty" % record_context)
	if not expected_media_prefix.is_empty() \
			and not media_type_value.to_lower().begins_with(expected_media_prefix):
		return _fail(
			"%s.runtimeMedia.mediaType must begin with '%s'" % [
				record_context,
				expected_media_prefix,
			]
		)
	if not _is_nonnegative_integer(runtime_media.get("bytes")):
		return _fail("%s.runtimeMedia.bytes must be a non-negative integer" % record_context)
	var sha256_value: Variant = runtime_media.get("sha256")
	if not (sha256_value is String) or not _is_sha256(sha256_value):
		return _fail("%s.runtimeMedia.sha256 must be a 64-digit hexadecimal hash" % record_context)
	return true


func _is_sha256(value: String) -> bool:
	var expression := RegEx.new()
	if expression.compile("^[0-9a-fA-F]{64}$") != OK:
		return false
	return expression.search(value) != null


func _is_hex_color(value: String) -> bool:
	var expression := RegEx.new()
	if expression.compile("^#[0-9a-fA-F]{6}$") != OK:
		return false
	return expression.search(value) != null


func _is_safe_document_path(path: String) -> bool:
	return _is_safe_campaign_path(path) and path.get_extension().to_lower() == "json"


func _is_safe_campaign_path(path: String) -> bool:
	var normalized := path.strip_edges().replace("\\", "/")
	if (
		normalized.is_empty()
		or normalized.ends_with("/")
		or normalized.is_absolute_path()
		or normalized.contains(":")
	):
		return false
	for component: String in normalized.split("/", false):
		if component in [".", ".."]:
			return false
	return true


func _is_nonnegative_integer(value: Variant) -> bool:
	return _is_integer(value) and int(value) >= 0


func _is_integer(value: Variant) -> bool:
	return (value is int or value is float) and is_equal_approx(float(value), float(int(value)))


func get_trigger(trigger_id: String) -> Dictionary:
	return triggers_by_id.get(trigger_id, {})


func get_extra_action_point(record_id: int) -> Dictionary:
	return extra_action_points_by_id.get(record_id, {})


func get_triggers_at(level_type: String, level_index: int, x: int, y: int) -> Array:
	return triggers_by_coordinate.get(_coordinate_key(level_type, level_index, x, y), []).duplicate()


func get_extra_code(record_id: int) -> Dictionary:
	return extra_codes_by_id.get(record_id, {})


func get_message(message_id: int) -> Dictionary:
	return messages_by_id.get(abs(message_id), {})


func get_option_label(label_id: int) -> Dictionary:
	return option_labels_by_id.get(abs(label_id), {})


func get_battle(battle_id: int) -> Dictionary:
	return battles_by_id.get(abs(battle_id), {})


func get_treasure(treasure_id: int) -> Dictionary:
	return treasures_by_id.get(treasure_id, {})


func get_shop(shop_id: int) -> Dictionary:
	return shops_by_id.get(abs(shop_id), {})


func get_item_text(item_id: int) -> Dictionary:
	return item_texts_by_id.get(abs(item_id), {})


func get_scenario_item(item_id: int) -> Dictionary:
	return scenario_items_by_id.get(abs(item_id), {})


func is_empty_scenario_item(item_id: int) -> bool:
	var scenario_item := get_scenario_item(item_id)
	if scenario_item.is_empty():
		return false
	var item_text := get_item_text(item_id)
	for text_field: String in ["identifiedName", "unidentifiedName", "description"]:
		if not str(item_text.get(text_field, "")).strip_edges().is_empty():
			return false
	for key_value: Variant in scenario_item.keys():
		var key := str(key_value)
		if key in ["id", "itemId", "authored", "provenance", "rawBytes"]:
			continue
		if _value_has_content(scenario_item[key_value]):
			return false
	return true


func _value_has_content(value: Variant) -> bool:
	if value is bool:
		return value
	if value is int or value is float:
		return value != 0
	if value is String:
		return not value.strip_edges().is_empty()
	if value is Array:
		for nested_value: Variant in value:
			if _value_has_content(nested_value):
				return true
		return false
	if value is Dictionary:
		for nested_value: Variant in value.values():
			if _value_has_content(nested_value):
				return true
	return false


func get_monster(monster_id: int) -> Dictionary:
	return monsters_by_id.get(abs(monster_id), {})


func get_monsters_by_name_id(name_id: int) -> Array:
	return monsters_by_name_id.get(name_id, [])


func get_encounter(encounter_kind: String, encounter_id: int) -> Dictionary:
	match encounter_kind:
		"simple":
			return simple_encounters_by_id.get(encounter_id, {})
		"complex":
			return complex_encounters_by_id.get(encounter_id, {})
		_:
			return {}


func get_thief_encounter(encounter_id: int) -> Dictionary:
	return thief_encounters_by_id.get(encounter_id, {})


func get_timed_encounter(encounter_id: int) -> Dictionary:
	return timed_encounters_by_id.get(encounter_id, {})


func get_spell_override(spell_id: int) -> Dictionary:
	if spell_overrides_by_id.has(spell_id):
		return spell_overrides_by_id[spell_id]
	return spell_overrides_by_record_reference.get(spell_id, {})


func get_spell_override_by_record_id(record_id: int) -> Dictionary:
	return spell_overrides_by_record_id.get(record_id, {})


func get_map(map_id: String) -> Dictionary:
	return maps_by_id.get(map_id, {})


func get_land_layout() -> Dictionary:
	var maps_document: Variant = documents.get("maps", {})
	if not (maps_document is Dictionary):
		return {}
	var layout: Variant = maps_document.get("landLayout", {})
	return layout if layout is Dictionary else {}


func get_map_tile(
	level_type: String,
	level_index: int,
	tile_x: int,
	tile_y: int
) -> Dictionary:
	var map := get_map("%s:%d" % [level_type, level_index])
	if map.is_empty():
		return {}
	var width := int(map.get("width", 0))
	var height := int(map.get("height", 0))
	var tiles: Variant = map.get("tiles", [])
	if (
		not (tiles is Array)
		or tile_x < 0
		or tile_y < 0
		or tile_x >= width
		or tile_y >= height
	):
		return {}
	# Classic map fields are column-major.
	var tile_index := tile_x * height + tile_y
	if tile_index < 0 or tile_index >= tiles.size():
		return {}
	return {
		"map": map,
		"value": int(tiles[tile_index]),
	}


func get_land_tile_attribute(landlook: int, tile_id: int) -> Dictionary:
	var maps_document: Variant = documents.get("maps", {})
	if not (maps_document is Dictionary):
		return {}
	var attributes: Variant = maps_document.get("tileAttributes", [])
	if attributes is Array:
		for attribute_value: Variant in attributes:
			if not (attribute_value is Dictionary):
				continue
			var attribute: Dictionary = attribute_value
			var attribute_landlook: Variant = attribute.get("landlook")
			if (
				attribute_landlook != null
				and int(attribute_landlook) == landlook
				and int(attribute.get("tile", 0)) == absi(tile_id)
			):
				return attribute
	var custom_landlooks: Variant = maps_document.get("customLandlooks", [])
	if not (custom_landlooks is Array):
		return {}
	for custom_value: Variant in custom_landlooks:
		if not (custom_value is Dictionary):
			continue
		var custom: Dictionary = custom_value
		if int(custom.get("landlook", -1)) != landlook:
			continue
		var records: Variant = custom.get("records", [])
		if records is Array:
			for record_value: Variant in records:
				if (
					record_value is Dictionary
					and int(record_value.get("tile", 0)) == absi(tile_id)
				):
					return record_value
		break
	return {}


func get_player_map(map_id: int) -> Dictionary:
	return player_maps_by_id.get(abs(map_id), {})


func get_scrolling_text(resource_id: int) -> Dictionary:
	return scrolling_texts_by_id.get(abs(resource_id), {})


func get_random_level(level_type: String, level_index: int) -> Dictionary:
	return random_levels_by_id.get("%s:%d:randlevel" % [level_type, level_index], {})


func get_picture(picture_id: int) -> Dictionary:
	return pictures_by_id.get(abs(picture_id), {})


func get_sound(sound_id: int) -> Dictionary:
	return sounds_by_id.get(abs(sound_id), {})


func get_random_rectangle(level_type: String, level_index: int, rect_index: int) -> Dictionary:
	var random_level := get_random_level(level_type, level_index)
	var rectangles: Variant = random_level.get("rects", [])
	if not (rectangles is Array):
		return {}
	for rectangle: Variant in rectangles:
		if rectangle is Dictionary and int(rectangle.get("rectIndex", -1)) == rect_index:
			return rectangle
	return {}


func get_start() -> Dictionary:
	var start: Variant = manifest.get("start", {})
	return start if start is Dictionary else {}


func start_location() -> Dictionary:
	return get_start()


func is_dispatcher_noop(trigger: Dictionary, action: Dictionary) -> bool:
	return dispatcher_noop_keys.has(_dispatcher_noop_key(
		str(trigger.get("id", "")),
		int(action.get("slot", -1)),
		int(action.get("rawCode", 0))
	))


func _reset() -> void:
	root_directory = ""
	campaign_kind = ""
	manifest.clear()
	documents.clear()
	last_error = ""
	triggers_by_id.clear()
	extra_action_points_by_id.clear()
	triggers_by_coordinate.clear()
	extra_codes_by_id.clear()
	messages_by_id.clear()
	option_labels_by_id.clear()
	battles_by_id.clear()
	treasures_by_id.clear()
	shops_by_id.clear()
	scenario_items_by_id.clear()
	item_texts_by_id.clear()
	monsters_by_id.clear()
	monsters_by_name_id.clear()
	simple_encounters_by_id.clear()
	complex_encounters_by_id.clear()
	thief_encounters_by_id.clear()
	timed_encounters_by_id.clear()
	spell_overrides_by_id.clear()
	spell_overrides_by_record_id.clear()
	spell_overrides_by_record_reference.clear()
	maps_by_id.clear()
	player_maps_by_id.clear()
	scrolling_texts_by_id.clear()
	random_levels_by_id.clear()
	pictures_by_id.clear()
	sounds_by_id.clear()
	dispatcher_noop_keys.clear()
	_evidence_records_by_key.clear()
	_evidence_loaded = false


func _build_indexes() -> void:
	var script_document: Dictionary = documents["scripts"]
	for trigger: Variant in _array_value(script_document, "triggers"):
		if not (trigger is Dictionary):
			continue
		_hydrate_trigger_identity(trigger)
		var trigger_id := str(trigger.get("id", ""))
		if not trigger_id.is_empty():
			triggers_by_id[trigger_id] = trigger
		if trigger.has("macroId"):
			extra_action_points_by_id[int(trigger.get("macroId", -1))] = trigger
		if not bool(trigger.get("active", false)):
			continue
		var coordinate: Variant = trigger.get("coordinate")
		if not (coordinate is Dictionary):
			continue
		var level_type := str(trigger.get("levelType", ""))
		var level_index := int(trigger.get("levelIndex", -1))
		var key := _coordinate_key(
			level_type,
			level_index,
			int(coordinate.get("x", -1)),
			int(coordinate.get("y", -1))
		)
		if not triggers_by_coordinate.has(key):
			triggers_by_coordinate[key] = []
		triggers_by_coordinate[key].append(trigger)

	for row: Variant in _array_value(script_document, "extraCodes"):
		if row is Dictionary:
			extra_codes_by_id[int(row.get("id", -1))] = row
	for message: Variant in _array_value(script_document, "messages"):
		if message is Dictionary:
			messages_by_id[int(message.get("id", -1))] = message
	for option_label: Variant in _array_value(script_document, "optionLabels"):
		if option_label is Dictionary:
			option_labels_by_id[int(option_label.get("id", -1))] = option_label
	for random_level: Variant in _array_value(script_document, "randomLevels"):
		if not (random_level is Dictionary):
			continue
		var random_level_id := str(random_level.get("id", ""))
		if not random_level_id.is_empty():
			random_levels_by_id[random_level_id] = random_level

	var encounter_document: Dictionary = documents["encounters"]
	for battle: Variant in _array_value(encounter_document, "battles"):
		if battle is Dictionary:
			battles_by_id[int(battle.get("id", -1))] = battle
	for treasure: Variant in _array_value(encounter_document, "treasures"):
		if treasure is Dictionary:
			treasures_by_id[int(treasure.get("id", -1))] = treasure
	for shop: Variant in _array_value(encounter_document, "shops"):
		if shop is Dictionary:
			shops_by_id[int(shop.get("id", -1))] = shop

	var content_document: Dictionary = documents["content"]
	for scenario_item: Variant in _array_value(content_document, "scenarioItems"):
		if scenario_item is Dictionary:
			var item_id := int(scenario_item.get("itemId", -1))
			if item_id >= 0:
				scenario_items_by_id[abs(item_id)] = scenario_item
	for item_text: Variant in _array_value(content_document, "itemTexts"):
		if item_text is Dictionary:
			item_texts_by_id[int(item_text.get("itemId", -1))] = item_text
	for monster: Variant in _array_value(content_document, "monsters"):
		if monster is Dictionary:
			monsters_by_id[int(monster.get("id", -1))] = monster
			var name_id := int(monster.get("nameId", -1))
			if name_id >= 0:
				if not monsters_by_name_id.has(name_id):
					monsters_by_name_id[name_id] = []
				monsters_by_name_id[name_id].append(monster)
	for encounter: Variant in _array_value(encounter_document, "simpleEncounters"):
		if encounter is Dictionary:
			simple_encounters_by_id[int(encounter.get("id", -1))] = encounter
	for encounter: Variant in _array_value(encounter_document, "complexEncounters"):
		if encounter is Dictionary:
			complex_encounters_by_id[int(encounter.get("id", -1))] = encounter
	for encounter: Variant in _array_value(encounter_document, "thiefEncounters"):
		if encounter is Dictionary:
			thief_encounters_by_id[int(encounter.get("id", -1))] = encounter
	for encounter: Variant in _array_value(encounter_document, "timedEncounters"):
		if encounter is Dictionary:
			timed_encounters_by_id[int(encounter.get("id", -1))] = encounter

	var rules_document: Dictionary = documents["rules"]
	for spell_override: Variant in _array_value(rules_document, "spellOverrides"):
		if spell_override is Dictionary:
			var record_id := int(spell_override.get("id", -1))
			spell_overrides_by_record_id[record_id] = spell_override
			spell_overrides_by_id[packed_spell_id_for_record_id(record_id)] = spell_override
			# Encounter records store Data Spell references as one-based row numbers.
			spell_overrides_by_record_reference[record_id + 1] = spell_override

	var map_document: Dictionary = documents["maps"]
	for map: Variant in _array_value(map_document, "maps"):
		if map is Dictionary:
			maps_by_id[str(map.get("id", ""))] = map
	for map_record: Variant in _array_value(map_document, "mapRecords"):
		if map_record is Dictionary:
			player_maps_by_id[int(map_record.get("id", -1))] = map_record
			var scrolling_text: Variant = map_record.get("scrollingText")
			if scrolling_text is Dictionary:
				scrolling_texts_by_id[abs(int(
					scrolling_text.get("resourceId", 0)
				))] = scrolling_text

	var asset_document: Dictionary = documents["assets"]
	for scrolling_text: Variant in _array_value(asset_document, "scrollingTexts"):
		if scrolling_text is Dictionary:
			scrolling_texts_by_id[abs(int(
				scrolling_text.get("resourceId", 0)
			))] = scrolling_text
	var asset_catalog: Variant = asset_document.get("catalog", {})
	if asset_catalog is Dictionary:
		for picture: Variant in _array_value(asset_catalog, "pictures"):
			if picture is Dictionary:
				pictures_by_id[int(picture.get("resourceId", -1))] = picture
		for sound: Variant in _array_value(asset_catalog, "sounds"):
			if sound is Dictionary:
				sounds_by_id[int(sound.get("resourceId", -1))] = sound

	for row: Variant in _array_value(script_document, "dispatcherNoops"):
		if row is Dictionary:
			dispatcher_noop_keys[_dispatcher_noop_key(
				str(row.get("triggerId", "")),
				int(row.get("slot", -1)),
				int(row.get("rawCode", 0))
			)] = true


func _hydrate_trigger_identity(trigger: Dictionary) -> void:
	if trigger.has("source") and trigger.has("recordIndex"):
		return
	var trigger_id := str(trigger.get("id", ""))
	var parts := trigger_id.split(":")
	if parts.size() < 3:
		return
	if parts[0] == "Data ED3" and parts.size() == 3 and parts[1] == "macro":
		if parts[2].is_valid_int():
			trigger["source"] = "Data ED3"
			trigger["recordIndex"] = int(parts[2])
			if not trigger.has("macroId"):
				trigger["macroId"] = int(parts[2])
		return
	if parts.size() == 4 \
			and parts[0] in ["land", "dungeon"] \
			and parts[1].is_valid_int() \
			and parts[2] == "ap" \
			and parts[3].is_valid_int():
		trigger["source"] = "Data DD" if parts[0] == "land" else "Data DDD"
		trigger["recordIndex"] = int(parts[3])
		return
	if parts[0] not in ["Data DD", "Data DDD"] or not parts[-1].is_valid_int():
		return
	trigger["source"] = parts[0]
	trigger["recordIndex"] = int(parts[-1])


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		last_error = "Missing classic campaign file: %s" % path
		return null
	var parser := JSON.new()
	var parse_error := parser.parse(FileAccess.get_file_as_string(path))
	if parse_error != OK:
		last_error = "Invalid JSON in %s at line %d: %s" % [
			path,
			parser.get_error_line(),
			parser.get_error_message(),
		]
		return null
	return parser.data


func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _array_value(document: Dictionary, key: String) -> Array:
	var value: Variant = document.get(key, [])
	return value if value is Array else []


func _coordinate_key(level_type: String, level_index: int, x: int, y: int) -> String:
	return "%s:%d:%d:%d" % [level_type, level_index, x, y]


func _dispatcher_noop_key(trigger_id: String, slot: int, raw_code: int) -> String:
	return "%s:%d:%d" % [trigger_id, slot, raw_code]


func _fail(message: String) -> bool:
	if last_error.is_empty():
		last_error = message
	return false
