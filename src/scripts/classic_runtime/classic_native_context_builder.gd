class_name ClassicNativeContextBuilder
extends RefCounted

const SpellResourceCatalogScript = preload(
	"res://scripts/classic_runtime/classic_spell_resource_catalog.gd"
)
const ClassicItemIdsScript = preload("res://scripts/item_id_divinity.gd")

const SCHEMA_VERSION := 1
const DEFAULT_SHARED_DIRECTORY := "res://shared_assets"
const PREPARATION_ERROR := "preparation-error"

var _diagnostics: Array = []
var _sources: Array = []
static var _shared_context_cache: Dictionary = {}
static var _shared_diagnostics_cache: Array = []
static var _shared_sources_cache: Array = []
static var _shared_cache_directory := ""


func build(
	campaign_directory: String,
	shared_directory := DEFAULT_SHARED_DIRECTORY
) -> Dictionary:
	_diagnostics.clear()
	_sources.clear()
	var context := _empty_context()
	var normalized_shared := _normalized_directory(shared_directory)
	if not _has_shared_cache(normalized_shared):
		_merge_shared_context(normalized_shared, context)
		_store_shared_cache(context, normalized_shared)
	else:
		context = _copy_shared_context()
		_diagnostics.append_array(_shared_diagnostics_cache.duplicate(true))
		_sources.append_array(_shared_sources_cache.duplicate(true))
	_merge_campaign_context(_normalized_directory(campaign_directory), context)
	return _result(context)


func warm_shared_cache_async(
	tree: SceneTree,
	shared_directory := DEFAULT_SHARED_DIRECTORY
) -> void:
	var normalized_shared := _normalized_directory(shared_directory)
	if _has_shared_cache(normalized_shared):
		return
	var worker_thread := Thread.new()
	var worker_error := worker_thread.start(
		_build_shared_file_context_worker.bind(normalized_shared),
		Thread.PRIORITY_LOW,
	)
	if worker_error != OK:
		return
	while worker_thread.is_alive():
		await tree.process_frame
	if _has_shared_cache(normalized_shared):
		worker_thread.wait_to_finish()
		return
	var worker_value: Variant = worker_thread.wait_to_finish()
	if not (worker_value is Dictionary):
		return
	var worker_result: Dictionary = worker_value
	var context: Dictionary = worker_result.get("context", _empty_context())
	_diagnostics = worker_result.get("diagnostics", []).duplicate(true)
	_sources = worker_result.get("sources", []).duplicate(true)
	await _merge_spell_directory_async(
		normalized_shared,
		"spells",
		"shared",
		context["spells"],
		tree,
	)
	_store_shared_cache(context, normalized_shared)


static func _build_shared_file_context_worker(
	normalized_shared: String
) -> Dictionary:
	var builder := ClassicNativeContextBuilder.new()
	var context := _empty_context()
	builder._merge_resource_book(
		normalized_shared,
		"items/stuff_book.json",
		"shared",
		"items",
		context["items"],
		true,
	)
	builder._merge_resource_book(
		normalized_shared,
		"Bestiary/stuff_book.json",
		"shared",
		"bestiary",
		context["bestiary"],
	)
	builder._merge_sound_directory(
		normalized_shared,
		"sounds",
		"shared",
		context["sounds"],
	)
	return {
		"context": context,
		"diagnostics": builder._diagnostics.duplicate(true),
		"sources": builder._sources.duplicate(true),
	}


func build_campaign_file_context_worker(campaign_directory: String) -> Dictionary:
	_diagnostics.clear()
	_sources.clear()
	var context := _empty_context()
	var normalized_campaign := _normalized_directory(campaign_directory)
	_merge_resource_book(
		normalized_campaign,
		"Items/stuff_book.json",
		"campaign",
		"items",
		context["items"]
	)
	_merge_resource_book(
		normalized_campaign,
		"Bestiary/stuff_book.json",
		"campaign",
		"bestiary",
		context["bestiary"]
	)
	_merge_sound_directory(
		normalized_campaign,
		"Sounds",
		"campaign",
		context["sounds"]
	)
	return _result(context)


func build_from_campaign_file_context(
	campaign_directory: String,
	campaign_result: Dictionary
) -> Dictionary:
	_diagnostics.clear()
	_sources.clear()
	var normalized_shared := _normalized_directory(DEFAULT_SHARED_DIRECTORY)
	if not _has_shared_cache(normalized_shared):
		var shared_context := _empty_context()
		_merge_shared_context(normalized_shared, shared_context)
		_store_shared_cache(shared_context, normalized_shared)
	var context := _copy_shared_context()
	_diagnostics.append_array(_shared_diagnostics_cache.duplicate(true))
	_sources.append_array(_shared_sources_cache.duplicate(true))
	var campaign_context: Variant = campaign_result.get("context", {})
	if campaign_context is Dictionary:
		for resource_kind: String in ["items", "bestiary", "sounds"]:
			var entries: Variant = campaign_context.get(resource_kind, {})
			if entries is Dictionary:
				context[resource_kind].merge(entries, true)
	_sources.append_array(campaign_result.get("sources", []).duplicate(true))
	_diagnostics.append_array(
		campaign_result.get("diagnostics", []).duplicate(true)
	)
	# Script-backed spell metadata remains a main-thread ResourceLoader concern.
	_merge_spell_directory(
		_normalized_directory(campaign_directory),
		"Spells",
		"campaign",
		context["spells"]
	)
	return _result(context)


func _merge_shared_context(normalized_shared: String, context: Dictionary) -> void:
	_merge_resource_book(
		normalized_shared,
		"items/stuff_book.json",
		"shared",
		"items",
		context["items"],
		true
	)
	_merge_resource_book(
		normalized_shared,
		"Bestiary/stuff_book.json",
		"shared",
		"bestiary",
		context["bestiary"]
	)
	_merge_spell_directory(
		normalized_shared,
		"spells",
		"shared",
		context["spells"]
	)
	_merge_sound_directory(
		normalized_shared,
		"sounds",
		"shared",
		context["sounds"]
	)


func _merge_campaign_context(normalized_campaign: String, context: Dictionary) -> void:
	_merge_resource_book(
		normalized_campaign,
		"Items/stuff_book.json",
		"campaign",
		"items",
		context["items"]
	)
	_merge_resource_book(
		normalized_campaign,
		"Bestiary/stuff_book.json",
		"campaign",
		"bestiary",
		context["bestiary"]
	)
	_merge_spell_directory(
		normalized_campaign,
		"Spells",
		"campaign",
		context["spells"]
	)
	_merge_sound_directory(
		normalized_campaign,
		"Sounds",
		"campaign",
		context["sounds"]
	)


func _store_shared_cache(context: Dictionary, normalized_shared: String) -> void:
	_shared_context_cache = context.duplicate(true)
	_shared_diagnostics_cache = _diagnostics.duplicate(true)
	_shared_sources_cache = _sources.duplicate(true)
	_shared_cache_directory = normalized_shared


static func _has_shared_cache(normalized_shared: String) -> bool:
	return (
		not _shared_context_cache.is_empty()
		and _shared_cache_directory == normalized_shared
	)


func _result(context: Dictionary) -> Dictionary:
	var error_count := 0
	for diagnostic_value: Variant in _diagnostics:
		if (
			diagnostic_value is Dictionary
			and str(diagnostic_value.get("classification", "")) == PREPARATION_ERROR
		):
			error_count += 1
	var ok := error_count == 0
	return {
		"schemaVersion": SCHEMA_VERSION,
		"ok": ok,
		"status": "ready" if ok else "preparation-failed",
		"context": context,
		"totals": {
			"preparationErrors": error_count,
			"sources": _sources.size(),
			"items": context["items"].size(),
			"bestiary": context["bestiary"].size(),
			"spells": context["spells"].size(),
			"sounds": context["sounds"].size(),
		},
		"sources": _sources.duplicate(true),
		"diagnostics": _diagnostics.duplicate(true),
	}


static func _empty_context() -> Dictionary:
	return {"items": {}, "bestiary": {}, "spells": {}, "sounds": {}}


static func _copy_shared_context() -> Dictionary:
	var context := _empty_context()
	for resource_kind: String in context:
		var source: Variant = _shared_context_cache.get(resource_kind, {})
		context[resource_kind] = (
			source.duplicate(false) if source is Dictionary else {}
		)
	return context


static func clear_shared_cache_for_tests() -> void:
	_shared_context_cache.clear()
	_shared_diagnostics_cache.clear()
	_shared_sources_cache.clear()
	_shared_cache_directory = ""


static func public_report(result: Dictionary) -> Dictionary:
	# Avoid recursively copying the large private context only to discard it.
	var report := result.duplicate(false)
	report.erase("context")
	return report.duplicate(true)


static func first_error(result: Dictionary) -> String:
	for diagnostic_value: Variant in result.get("diagnostics", []):
		if (
			diagnostic_value is Dictionary
			and str(diagnostic_value.get("classification", "")) == PREPARATION_ERROR
		):
			return str(
				diagnostic_value.get(
					"message",
					"Classic native resource preparation failed"
				)
			)
	return "Classic native resource preparation failed"


func _merge_resource_book(
	base_directory: String,
	relative_path: String,
	scope: String,
	resource_kind: String,
	destination: Dictionary,
	enrich_classic_item_ids := false
) -> void:
	var path := base_directory.path_join(relative_path)
	var display_path := _display_path(scope, relative_path)
	if not FileAccess.file_exists(path):
		_sources.append(_source_row(
			scope,
			resource_kind,
			display_path,
			false,
			0
		))
		return
	var parser := JSON.new()
	var error := parser.parse(FileAccess.get_file_as_string(path))
	if error != OK or not (parser.data is Dictionary):
		var detail := parser.get_error_message()
		if error == OK:
			detail = "the document root is not a JSON object"
		elif parser.get_error_line() > 0:
			detail += " at line %d" % parser.get_error_line()
		_add_preparation_error(
			"invalid-native-%s-book" % resource_kind,
			resource_kind,
			scope,
			display_path,
			"Native %s book is invalid: %s (%s)" % [
				resource_kind,
				display_path,
				detail,
			]
		)
		_sources.append(_source_row(
			scope,
			resource_kind,
			display_path,
			true,
			0
		))
		return
	var value: Dictionary = parser.data
	if enrich_classic_item_ids:
		value = ClassicItemIdsScript.new().enrich_item_book(value)
	destination.merge(value, true)
	_sources.append(_source_row(
		scope,
		resource_kind,
		display_path,
		true,
		value.size()
	))


func _merge_spell_directory(
	base_directory: String,
	relative_path: String,
	scope: String,
	destination: Dictionary
) -> void:
	var path := base_directory.path_join(relative_path)
	var exists := _directory_exists(path)
	var source_entries: Dictionary = {}
	if exists:
		SpellResourceCatalogScript.merge_directory(path, source_entries)
		destination.merge(source_entries, true)
	_sources.append(_source_row(
		scope,
		"spells",
		_display_path(scope, relative_path),
		exists,
		source_entries.size()
	))


func _merge_spell_directory_async(
	base_directory: String,
	relative_path: String,
	scope: String,
	destination: Dictionary,
	tree: SceneTree,
) -> void:
	var path := base_directory.path_join(relative_path)
	var exists := _directory_exists(path)
	var source_entries: Dictionary = {}
	if exists:
		await SpellResourceCatalogScript.merge_directory_async(
			path,
			source_entries,
			tree,
		)
		destination.merge(source_entries, true)
	_sources.append(_source_row(
		scope,
		"spells",
		_display_path(scope, relative_path),
		exists,
		source_entries.size(),
	))


func _merge_sound_directory(
	base_directory: String,
	relative_path: String,
	scope: String,
	destination: Dictionary
) -> void:
	var path := base_directory.path_join(relative_path)
	var access := DirAccess.open(path)
	var entries_read := 0
	if access != null:
		access.list_dir_begin()
		var file_name := access.get_next()
		while not file_name.is_empty():
			if not access.current_is_dir():
				var resource_name := file_name.trim_suffix(".import")
				if not resource_name.ends_with(".uid"):
					destination[resource_name] = true
					entries_read += 1
			file_name = access.get_next()
		access.list_dir_end()
	_sources.append(_source_row(
		scope,
		"sounds",
		_display_path(scope, relative_path),
		access != null,
		entries_read
	))


func _add_preparation_error(
	code: String,
	resource_kind: String,
	scope: String,
	path: String,
	message: String
) -> void:
	_diagnostics.append({
		"severity": "error",
		"classification": PREPARATION_ERROR,
		"activity": "preparation",
		"code": code,
		"resourceKind": resource_kind,
		"scope": scope,
		"source": path,
		"recordIndex": -1,
		"message": message,
	})


static func _source_row(
	scope: String,
	resource_kind: String,
	path: String,
	exists: bool,
	entries_read: int
) -> Dictionary:
	return {
		"scope": scope,
		"resourceKind": resource_kind,
		"path": path,
		"exists": exists,
		"entriesRead": entries_read,
	}


static func _display_path(scope: String, relative_path: String) -> String:
	return "%s://%s" % [scope, relative_path.replace("\\", "/")]


static func _directory_exists(path: String) -> bool:
	var access := DirAccess.open(path)
	return access != null


static func _normalized_directory(directory: String) -> String:
	return directory.strip_edges().replace("\\", "/").trim_suffix("/")
