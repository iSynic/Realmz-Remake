class_name ScenarioEnginePluginStore
extends RefCounted

const RegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_registry.gd"
)

const PACKAGE_SCHEMA_VERSION := 1
const PACKAGE_MANIFEST_NAME := "plugin.json"

var catalog_path := RegistryScript.INSTALLED_CATALOG_PATH
var install_root := RegistryScript.INSTALL_ROOT
var last_error := ""
var _document := _empty_document()


func refresh() -> bool:
	last_error = ""
	var loaded := _read_catalog()
	if not bool(loaded.get("valid", false)):
		return _fail(str(loaded.get("message", "Could not read plug-in catalog")))
	var candidate: Dictionary = loaded["document"]
	var validation := _validate_catalog(candidate)
	if not bool(validation.get("valid", false)):
		return _fail(str(validation.get("message", "Plug-in catalog is invalid")))
	_document = candidate
	return true


func plugin_descriptors() -> Array:
	if not refresh():
		return []
	var result: Array = _document.get("plugins", []).duplicate(true)
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return str(left.get("id", "")) < str(right.get("id", ""))
	)
	return result


func descriptor(plugin_id: String) -> Dictionary:
	if not refresh():
		return {}
	for descriptor_value: Variant in _document.get("plugins", []):
		if descriptor_value is Dictionary \
				and str(descriptor_value.get("id", "")) == plugin_id:
			return descriptor_value.duplicate(true)
	return {}


func inspect_manifest(manifest_path: String) -> Dictionary:
	last_error = ""
	if manifest_path.get_file().to_lower() != PACKAGE_MANIFEST_NAME:
		return _error("Choose a plug-in package's plugin.json manifest")
	if not FileAccess.file_exists(manifest_path):
		return _error("The selected plug-in manifest does not exist")
	var parser := JSON.new()
	var parse_error := parser.parse(FileAccess.get_file_as_string(manifest_path))
	if parse_error != OK or not (parser.data is Dictionary):
		return _error("The selected plug-in manifest is not valid JSON")
	var package_document: Dictionary = parser.data
	if int(package_document.get("packageSchemaVersion", 0)) \
			!= PACKAGE_SCHEMA_VERSION:
		return _error(
			"Scenario engine plug-in package version is unsupported"
		)
	var candidate: Dictionary = package_document.duplicate(true)
	candidate.erase("packageSchemaVersion")
	candidate["approved"] = false
	candidate["approvedHash"] = ""
	var validation := _validate_catalog({
		"schemaVersion": RegistryScript.SCHEMA_VERSION,
		"plugins": [candidate],
	})
	if not bool(validation.get("valid", false)):
		return _error(str(validation.get("message", "Plug-in is invalid")))
	var package_root := manifest_path.get_base_dir()
	var file_validation := RegistryScript.verify_package_files(
		candidate,
		package_root
	)
	if not bool(file_validation.get("valid", false)):
		return _error(str(file_validation.get("message", "Plug-in files are invalid")))
	return {
		"status": "ok",
		"descriptor": candidate,
		"packageRoot": package_root,
		"manifestPath": manifest_path,
	}


func install_from_manifest(
	manifest_path: String,
	allow_update := false
) -> Dictionary:
	if not refresh():
		return _error(last_error)
	var inspection := inspect_manifest(manifest_path)
	if inspection.get("status") != "ok":
		return inspection
	var candidate: Dictionary = inspection["descriptor"]
	var plugin_id := str(candidate.get("id", ""))
	var existing_index := _plugin_index(_document, plugin_id)
	if existing_index >= 0 and not allow_update:
		return _error(
			"Scenario engine plug-in '%s' is already installed" % plugin_id
		)
	var root_error := DirAccess.make_dir_recursive_absolute(
		_global_path(install_root)
	)
	if root_error != OK:
		return _error("Could not create the scenario plug-in directory")
	var transaction_id := "%s-%d" % [
		plugin_id.replace(".", "-"),
		Time.get_ticks_usec(),
	]
	var staging_path := install_root.path_join(".installing-" + transaction_id)
	var final_path := install_root.path_join(plugin_id)
	var backup_path := install_root.path_join(".previous-" + transaction_id)
	if not _copy_package_files(
		str(inspection.get("packageRoot", "")),
		staging_path,
		candidate
	):
		_remove_tree(staging_path)
		return _error(last_error)
	var staged_validation := RegistryScript.verify_package_files(
		candidate,
		staging_path
	)
	if not bool(staged_validation.get("valid", false)):
		_remove_tree(staging_path)
		return _error(
			str(staged_validation.get("message", "Copied plug-in is invalid"))
		)
	if FileAccess.file_exists(final_path) or DirAccess.dir_exists_absolute(
		_global_path(final_path)
	):
		if DirAccess.rename_absolute(
			_global_path(final_path),
			_global_path(backup_path)
		) != OK:
			_remove_tree(staging_path)
			return _error("Could not stage the installed plug-in update")
	if DirAccess.rename_absolute(
		_global_path(staging_path),
		_global_path(final_path)
	) != OK:
		if DirAccess.dir_exists_absolute(_global_path(backup_path)):
			DirAccess.rename_absolute(
				_global_path(backup_path),
				_global_path(final_path)
			)
		_remove_tree(staging_path)
		return _error("Could not install the scenario engine plug-in")
	var next_document: Dictionary = _document.duplicate(true)
	var plugins: Array = next_document.get("plugins", [])
	if existing_index >= 0:
		plugins[existing_index] = candidate
	else:
		plugins.append(candidate)
	next_document["plugins"] = plugins
	var validation := _validate_catalog(next_document)
	if not bool(validation.get("valid", false)) \
			or not _write_catalog(next_document):
		_remove_tree(final_path)
		if DirAccess.dir_exists_absolute(_global_path(backup_path)):
			DirAccess.rename_absolute(
				_global_path(backup_path),
				_global_path(final_path)
			)
		return _error(
			str(
				validation.get(
					"message",
					last_error if not last_error.is_empty() \
						else "Could not save the plug-in catalog"
				)
			)
		)
	_remove_tree(backup_path)
	_document = next_document
	return {
		"status": "ok",
		"id": plugin_id,
		"updated": existing_index >= 0,
		"message": (
			"Updated '%s'; approval was revoked" % plugin_id
			if existing_index >= 0
			else "Installed '%s'; approve it before use" % plugin_id
		),
	}


func approve(plugin_id: String) -> bool:
	if not refresh():
		return false
	var index := _plugin_index(_document, plugin_id)
	if index < 0:
		return _fail("Scenario engine plug-in '%s' is not installed" % plugin_id)
	var next_document: Dictionary = _document.duplicate(true)
	var candidate: Dictionary = next_document["plugins"][index].duplicate(true)
	var file_validation := RegistryScript.verify_descriptor_files(
		candidate,
		install_root
	)
	if not bool(file_validation.get("valid", false)):
		return _fail(str(file_validation.get("message", "Plug-in files changed")))
	candidate["approved"] = false
	candidate["approvedHash"] = RegistryScript.approval_hash(candidate)
	candidate["approved"] = true
	next_document["plugins"][index] = candidate
	var validation := _validate_catalog(next_document)
	if not bool(validation.get("valid", false)):
		return _fail(str(validation.get("message", "Plug-in approval is invalid")))
	if not _write_catalog(next_document):
		return false
	_document = next_document
	return true


func revoke(plugin_id: String) -> bool:
	if not refresh():
		return false
	var index := _plugin_index(_document, plugin_id)
	if index < 0:
		return _fail("Scenario engine plug-in '%s' is not installed" % plugin_id)
	var next_document: Dictionary = _document.duplicate(true)
	var candidate: Dictionary = next_document["plugins"][index].duplicate(true)
	candidate["approved"] = false
	candidate["approvedHash"] = ""
	next_document["plugins"][index] = candidate
	if not _write_catalog(next_document):
		return false
	_document = next_document
	return true


func remove(plugin_id: String) -> bool:
	if not refresh():
		return false
	var index := _plugin_index(_document, plugin_id)
	if index < 0:
		return _fail("Scenario engine plug-in '%s' is not installed" % plugin_id)
	var final_path := install_root.path_join(plugin_id)
	var removed_path := install_root.path_join(
		".removing-%s-%d"
		% [plugin_id.replace(".", "-"), Time.get_ticks_usec()]
	)
	var has_directory := DirAccess.dir_exists_absolute(_global_path(final_path))
	if has_directory and DirAccess.rename_absolute(
		_global_path(final_path),
		_global_path(removed_path)
	) != OK:
		return _fail("Could not stage the scenario engine plug-in for removal")
	var next_document: Dictionary = _document.duplicate(true)
	next_document["plugins"].remove_at(index)
	if not _write_catalog(next_document):
		if has_directory:
			DirAccess.rename_absolute(
				_global_path(removed_path),
				_global_path(final_path)
			)
		return false
	_remove_tree(removed_path)
	_document = next_document
	return true


func _read_catalog() -> Dictionary:
	if not FileAccess.file_exists(catalog_path):
		return {"valid": true, "document": _empty_document()}
	var parser := JSON.new()
	var parse_error := parser.parse(FileAccess.get_file_as_string(catalog_path))
	if parse_error != OK or not (parser.data is Dictionary):
		return {
			"valid": false,
			"message": "Installed scenario plug-in catalog is invalid",
		}
	return {"valid": true, "document": parser.data.duplicate(true)}


func _validate_catalog(document: Dictionary) -> Dictionary:
	var registry := RegistryScript.new()
	registry.install_root = install_root
	if not registry.load_catalog_document(document):
		return {"valid": false, "message": registry.last_error}
	return {"valid": true}


func _copy_package_files(
	source_root: String,
	target_root: String,
	descriptor: Dictionary
) -> bool:
	if DirAccess.make_dir_recursive_absolute(_global_path(target_root)) != OK:
		return _fail("Could not create the plug-in staging directory")
	for file_value: Variant in descriptor.get("files", []):
		var file: Dictionary = file_value
		var relative_path := str(file.get("path", ""))
		var source_path := source_root.path_join(relative_path)
		var target_path := target_root.path_join(relative_path)
		if DirAccess.make_dir_recursive_absolute(
			_global_path(target_path.get_base_dir())
		) != OK:
			return _fail(
				"Could not create a directory for '%s'" % relative_path
			)
		var source_bytes := FileAccess.get_file_as_bytes(source_path)
		var target := FileAccess.open(target_path, FileAccess.WRITE)
		if target == null:
			return _fail("Could not copy plug-in file '%s'" % relative_path)
		target.store_buffer(source_bytes)
		target.flush()
	return true


func _write_catalog(document: Dictionary) -> bool:
	var parent_path := catalog_path.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(_global_path(parent_path)) != OK:
		return _fail("Could not create the scenario plug-in catalog directory")
	var temporary_path := catalog_path + ".installing"
	var backup_path := catalog_path + ".previous"
	_remove_file(temporary_path)
	_remove_file(backup_path)
	var output := FileAccess.open(temporary_path, FileAccess.WRITE)
	if output == null:
		return _fail("Could not write the scenario plug-in catalog")
	output.store_string(JSON.stringify(_canonical_value(document), "\t") + "\n")
	output.flush()
	output = null
	var had_catalog := FileAccess.file_exists(catalog_path)
	if had_catalog and DirAccess.rename_absolute(
		_global_path(catalog_path),
		_global_path(backup_path)
	) != OK:
		_remove_file(temporary_path)
		return _fail("Could not replace the scenario plug-in catalog")
	if DirAccess.rename_absolute(
		_global_path(temporary_path),
		_global_path(catalog_path)
	) != OK:
		if had_catalog:
			DirAccess.rename_absolute(
				_global_path(backup_path),
				_global_path(catalog_path)
			)
		_remove_file(temporary_path)
		return _fail("Could not replace the scenario plug-in catalog")
	_remove_file(backup_path)
	return true


func _remove_tree(path: String) -> bool:
	if path.is_empty() or not _is_managed_path(path):
		return false
	var global_path := _global_path(path)
	if not DirAccess.dir_exists_absolute(global_path):
		return true
	var directory := DirAccess.open(global_path)
	if directory == null:
		return false
	for file_name: String in directory.get_files():
		if DirAccess.remove_absolute(global_path.path_join(file_name)) != OK:
			return false
	for directory_name: String in directory.get_directories():
		if not _remove_tree(path.path_join(directory_name)):
			return false
	return DirAccess.remove_absolute(global_path) == OK


func _remove_file(path: String) -> void:
	var global_path := _global_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(global_path)


func _is_managed_path(path: String) -> bool:
	var root := _global_path(install_root).replace("\\", "/").trim_suffix("/")
	var candidate := _global_path(path).replace("\\", "/")
	if OS.get_name() == "Windows":
		root = root.to_lower()
		candidate = candidate.to_lower()
	return candidate.begins_with(root + "/") and candidate != root


func _global_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


static func _plugin_index(document: Dictionary, plugin_id: String) -> int:
	var plugins: Variant = document.get("plugins", [])
	if not (plugins is Array):
		return -1
	for index: int in range(plugins.size()):
		if plugins[index] is Dictionary \
				and str(plugins[index].get("id", "")) == plugin_id:
			return index
	return -1


static func _canonical_value(value: Variant) -> Variant:
	if value is Array:
		var result: Array = []
		for child: Variant in value:
			result.append(_canonical_value(child))
		return result
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			result[str(key)] = _canonical_value(value[key])
		return result
	return value


static func _empty_document() -> Dictionary:
	return {
		"schemaVersion": RegistryScript.SCHEMA_VERSION,
		"plugins": [],
	}


func _error(message: String) -> Dictionary:
	last_error = message
	return {"status": "error", "message": message}


func _fail(message: String) -> bool:
	last_error = message
	return false
