class_name ScenarioEnginePluginRegistry
extends RefCounted

const INSTALLED_CATALOG_PATH := "user://scenario_plugins/installed.json"
const INSTALL_ROOT := "user://scenario_plugins"
const SCHEMA_VERSION := 1
const CORE_PREFIX := "core."
const PORT_ID := "engine.plugins"
const MAX_PLUGIN_FILES := 256
const MAX_PLUGIN_FILE_BYTES := 8 * 1024 * 1024
const MAX_PLUGIN_TOTAL_BYTES := 32 * 1024 * 1024
const REQUIRED_OPERATION_FIELDS := [
	"label",
	"category",
	"minimumTier",
	"roles",
	"yields",
	"mutates",
	"parameters",
	"result",
	"summary",
	"reference",
	"example",
]

var installed: Dictionary = {}
var providers: Dictionary = {}
var operations: Dictionary = {}
var command_providers: Dictionary = {}
var active_plugins: Dictionary = {}
var last_error := ""
var install_root := INSTALL_ROOT


func load_installed_catalog() -> bool:
	_clear()
	if not FileAccess.file_exists(INSTALLED_CATALOG_PATH):
		return true
	var parser := JSON.new()
	var error := parser.parse(FileAccess.get_file_as_string(INSTALLED_CATALOG_PATH))
	if error != OK or not (parser.data is Dictionary):
		return _fail("Installed scenario plug-in catalog is invalid")
	return load_catalog_document(parser.data)


func load_catalog_document(document: Variant) -> bool:
	_clear()
	if not (document is Dictionary):
		return _fail("Installed scenario plug-in catalog is invalid")
	if int(document.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return _fail("Installed scenario plug-in catalog version is unsupported")
	var entries: Variant = document.get("plugins", [])
	if not (entries is Array):
		return _fail("Installed scenario plug-in catalog has no plug-in list")
	for entry_value: Variant in entries:
		if not (entry_value is Dictionary):
			return _fail("Installed scenario plug-in descriptor is invalid")
		var entry: Dictionary = entry_value.duplicate(true)
		var plugin_id := str(entry.get("id", ""))
		if not _is_namespaced_id(plugin_id) or installed.has(plugin_id):
			return _fail(
				"Installed scenario plug-in IDs must be unique and namespaced"
			)
		if int(entry.get("apiVersion", 0)) <= 0:
			return _fail(
				"Installed scenario plug-in '%s' has no API version" % plugin_id
			)
		if not (entry.get("approved") is bool):
			return _fail(
				"Installed scenario plug-in '%s' has no approval state" % plugin_id
			)
		var entry_point := str(entry.get("entryPoint", ""))
		if not _is_safe_entry_point(entry_point):
			return _fail(
				"Installed scenario plug-in '%s' has an invalid entry point"
				% plugin_id
			)
		if not _is_sha256(str(entry.get("contentHash", ""))):
			return _fail(
				"Installed scenario plug-in '%s' has an invalid content hash"
				% plugin_id
			)
		var file_validation := validate_file_manifest(entry)
		if not bool(file_validation.get("valid", false)):
			return _fail(
				"Installed scenario plug-in '%s' %s"
				% [plugin_id, file_validation.get("message", "is invalid")]
			)
		var operation_rows: Variant = entry.get("operations", [])
		if not (operation_rows is Array):
			return _fail(
				"Installed scenario plug-in '%s' has invalid operations"
				% plugin_id
			)
		var provider_rows: Variant = entry.get("providers", [])
		if not (provider_rows is Array):
			return _fail(
				"Installed scenario plug-in '%s' has invalid providers"
				% plugin_id
			)
		for provider_value: Variant in provider_rows:
			if not (provider_value is Dictionary):
				return _fail(
					"Installed scenario plug-in '%s' has an invalid provider"
					% plugin_id
				)
			var provider_id := str(provider_value.get("id", ""))
			var method_name := str(provider_value.get("method", ""))
			if not provider_id.begins_with(plugin_id + ".") \
					or not method_name.is_valid_identifier():
				return _fail(
					"Installed scenario plug-in '%s' has an invalid provider"
					% plugin_id
				)
		for operation_value: Variant in operation_rows:
			if not (operation_value is Dictionary):
				return _fail(
					"Installed scenario plug-in '%s' has an invalid operation"
					% plugin_id
				)
			var validation := _validate_operation(
				plugin_id,
				operation_value
			)
			if not bool(validation.get("valid", false)):
				return _fail(str(validation.get("message", "")))
			var operation_id := str(operation_value.get("id", ""))
			if operations.has(operation_id):
				return _fail(
					"Scenario engine operation '%s' is already installed"
					% operation_id
				)
			var registered_operation: Dictionary = operation_value.duplicate(
				true
			)
			registered_operation["pluginId"] = plugin_id
			operations[operation_id] = registered_operation
		var expected_approval := approval_hash(entry)
		if bool(entry.get("approved", false)) \
				and str(entry.get("approvedHash", "")) != expected_approval:
			return _fail(
				"Installed scenario plug-in '%s' changed after approval"
				% plugin_id
			)
		installed[plugin_id] = entry
	return true


func validate_requirements(requirements: Variant) -> Dictionary:
	if not (requirements is Array):
		return {
			"valid": false,
			"message": "runtime.requiredPlugins must be an array",
		}
	var seen: Dictionary = {}
	for requirement_value: Variant in requirements:
		if not (requirement_value is Dictionary):
			return {
				"valid": false,
				"message": "Scenario plug-in requirement is invalid",
			}
		var requirement: Dictionary = requirement_value
		var plugin_id := str(requirement.get("id", ""))
		var api_version := int(requirement.get("apiVersion", 0))
		if not _is_namespaced_id(plugin_id) or api_version <= 0 \
				or seen.has(plugin_id):
			return {
				"valid": false,
				"message": (
					"Scenario plug-in requirements need unique namespaced "
					+ "IDs and API versions"
				),
			}
		seen[plugin_id] = true
		if not installed.has(plugin_id):
			return {
				"valid": false,
				"message": "Required engine plug-in '%s' is not installed"
					% plugin_id,
			}
		var descriptor: Dictionary = installed[plugin_id]
		if int(descriptor.get("apiVersion", 0)) != api_version:
			return {
				"valid": false,
				"message": "Required engine plug-in '%s' needs API %d" % [
					plugin_id,
					api_version,
				],
			}
		if not bool(descriptor.get("approved", false)):
			return {
				"valid": false,
				"message": (
					"Required engine plug-in '%s' is installed but not approved"
					% plugin_id
				),
			}
	return {"valid": true}


func operation_descriptors(requirements: Variant) -> Array:
	var result: Array = []
	var required_ids := _required_ids(requirements)
	for operation_value: Variant in operations.values():
		if not (operation_value is Dictionary):
			continue
		var plugin_id := str(operation_value.get("pluginId", ""))
		if plugin_id in required_ids:
			result.append(operation_value.duplicate(true))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return str(left.get("id", "")) < str(right.get("id", ""))
	)
	return result


func activate_required(requirements: Variant) -> bool:
	providers.clear()
	command_providers.clear()
	active_plugins.clear()
	var validation := validate_requirements(requirements)
	if not bool(validation.get("valid", false)):
		return _fail(str(validation.get("message", "")))
	for plugin_id: String in _required_ids(requirements):
		var descriptor: Dictionary = installed[plugin_id]
		var file_validation := verify_descriptor_files(descriptor, install_root)
		if not bool(file_validation.get("valid", false)):
			return _fail(
				"Scenario engine plug-in '%s' no longer matches its approval: %s"
				% [plugin_id, file_validation.get("message", "invalid package")]
			)
		var script_path := (
			"%s/%s/%s"
			% [install_root, plugin_id, descriptor.get("entryPoint", "")]
		)
		var script: Script = load(script_path)
		if script == null:
			return _fail(
				"Scenario engine plug-in '%s' could not be loaded" % plugin_id
			)
		var instance: Object = script.new()
		if instance == null \
				or not instance.has_method("plugin_id") \
				or not instance.has_method("api_version"):
			return _fail(
				"Scenario engine plug-in '%s' has an invalid entry point"
				% plugin_id
			)
		if str(instance.call("plugin_id")) != plugin_id \
				or int(instance.call("api_version")) \
					!= int(descriptor.get("apiVersion", 0)):
			return _fail(
				"Scenario engine plug-in '%s' reported the wrong identity"
				% plugin_id
			)
		active_plugins[plugin_id] = instance
		for provider_value: Variant in descriptor.get("providers", []):
			var provider_id := str(provider_value.get("id", ""))
			var method_name := str(provider_value.get("method", ""))
			if not instance.has_method(method_name) \
					or not register_provider(
						plugin_id,
						provider_id,
						Callable(instance, method_name)
					):
				return false
		for operation_value: Variant in descriptor.get("operations", []):
			var command_id := str(operation_value.get("commandId", ""))
			var provider_id := str(operation_value.get("providerId", ""))
			if not providers.has(provider_id) \
					or command_providers.has(command_id):
				return _fail(
					"Scenario engine operation '%s' has an unavailable provider"
					% operation_value.get("id", "")
				)
			command_providers[command_id] = provider_id
	return true


func register_provider(
	plugin_id: String,
	provider_id: String,
	provider: Callable
) -> bool:
	if not installed.has(plugin_id) \
			or not bool(installed[plugin_id].get("approved", false)):
		return _fail("Scenario engine plug-in '%s' is not approved" % plugin_id)
	if not provider_id.begins_with(plugin_id + ".") \
			or providers.has(provider_id):
		return _fail(
			"Scenario engine plug-in provider IDs must be unique and namespaced"
		)
	if not provider.is_valid():
		return _fail(
			"Scenario engine plug-in provider '%s' is invalid" % provider_id
		)
	providers[provider_id] = provider
	return true


func command_ids() -> Array:
	var result := command_providers.keys()
	result.sort()
	return result


func invoke_command(command_id: String, request: Dictionary) -> Dictionary:
	var provider_id := str(command_providers.get(command_id, ""))
	if provider_id.is_empty():
		return {
			"status": "error",
			"message": "Scenario engine command '%s' is unavailable" % command_id,
		}
	return await invoke_provider(provider_id, request)


func invoke_provider(provider_id: String, request: Dictionary) -> Dictionary:
	var provider: Variant = providers.get(provider_id)
	if not (provider is Callable) or not provider.is_valid():
		return {
			"status": "error",
			"message": "Scenario engine provider '%s' is unavailable" % provider_id,
		}
	var result: Variant = await provider.call(request.duplicate(true))
	if not (result is Dictionary) or not _is_json_value(result):
		return {
			"status": "error",
			"message": (
				"Scenario engine provider '%s' returned an invalid result"
				% provider_id
			),
		}
	return result


static func approval_hash(descriptor: Dictionary) -> String:
	var approved_shape := descriptor.duplicate(true)
	approved_shape.erase("approved")
	approved_shape.erase("approvedHash")
	return _sha256_bytes(
		JSON.stringify(_canonical_value(approved_shape)).to_utf8_buffer()
	)


static func content_hash_for_file(path: String) -> String:
	return _sha256_bytes(FileAccess.get_file_as_bytes(path))


static func content_hash_for_files(files: Array) -> String:
	var canonical_files: Array = []
	for file_value: Variant in files:
		if not (file_value is Dictionary):
			return ""
		canonical_files.append({
			"path": str(file_value.get("path", "")),
			"size": int(file_value.get("size", -1)),
			"sha256": str(file_value.get("sha256", "")).to_lower(),
		})
	canonical_files.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return str(left.get("path", "")) < str(right.get("path", ""))
	)
	return _sha256_bytes(
		JSON.stringify(_canonical_value(canonical_files)).to_utf8_buffer()
	)


static func validate_file_manifest(descriptor: Dictionary) -> Dictionary:
	var files_value: Variant = descriptor.get("files", [])
	if not (files_value is Array) or files_value.is_empty() \
			or files_value.size() > MAX_PLUGIN_FILES:
		return {
			"valid": false,
			"message": "needs between 1 and %d declared files" % MAX_PLUGIN_FILES,
		}
	var seen: Dictionary = {}
	var total_bytes := 0
	var entry_point := str(descriptor.get("entryPoint", ""))
	for file_value: Variant in files_value:
		if not (file_value is Dictionary):
			return {"valid": false, "message": "has an invalid file manifest"}
		var relative_path := str(file_value.get("path", ""))
		var size := int(file_value.get("size", -1))
		var sha256 := str(file_value.get("sha256", "")).to_lower()
		if not _is_safe_relative_path(relative_path) or seen.has(relative_path):
			return {
				"valid": false,
				"message": "has a duplicate or unsafe file path",
			}
		if size < 0 or size > MAX_PLUGIN_FILE_BYTES:
			return {
				"valid": false,
				"message": "has a file outside the allowed size limit",
			}
		if not _is_sha256(sha256):
			return {"valid": false, "message": "has an invalid file hash"}
		seen[relative_path] = true
		total_bytes += size
		if total_bytes > MAX_PLUGIN_TOTAL_BYTES:
			return {
				"valid": false,
				"message": "is larger than the allowed package size",
			}
	if not seen.has(entry_point):
		return {
			"valid": false,
			"message": "does not declare its entry point in files",
		}
	var expected_content_hash := content_hash_for_files(files_value)
	if expected_content_hash.is_empty() \
			or expected_content_hash \
				!= str(descriptor.get("contentHash", "")).to_lower():
		return {
			"valid": false,
			"message": "has a content hash that does not match its file manifest",
		}
	return {"valid": true}


static func verify_descriptor_files(
	descriptor: Dictionary,
	root: String
) -> Dictionary:
	return verify_package_files(
		descriptor,
		root.path_join(str(descriptor.get("id", "")))
	)


static func verify_package_files(
	descriptor: Dictionary,
	package_root: String
) -> Dictionary:
	var manifest_validation := validate_file_manifest(descriptor)
	if not bool(manifest_validation.get("valid", false)):
		return manifest_validation
	for file_value: Variant in descriptor.get("files", []):
		var file: Dictionary = file_value
		var relative_path := str(file.get("path", ""))
		var path := package_root.path_join(relative_path)
		if not FileAccess.file_exists(path):
			return {
				"valid": false,
				"message": "is missing declared file '%s'" % relative_path,
			}
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.size() != int(file.get("size", -1)) \
				or _sha256_bytes(bytes) \
					!= str(file.get("sha256", "")).to_lower():
			return {
				"valid": false,
				"message": "declared file '%s' changed" % relative_path,
			}
	return {"valid": true}


static func _validate_operation(
	plugin_id: String,
	operation: Dictionary
) -> Dictionary:
	var operation_id := str(operation.get("id", ""))
	var command_id := str(operation.get("commandId", ""))
	var provider_id := str(operation.get("providerId", ""))
	if not operation_id.begins_with(plugin_id + ".") \
			or operation_id.begins_with(CORE_PREFIX):
		return {
			"valid": false,
			"message": "Scenario engine operation IDs must use their plug-in namespace",
		}
	if not command_id.begins_with(plugin_id + ".") \
			or not provider_id.begins_with(plugin_id + "."):
		return {
			"valid": false,
			"message": (
				"Scenario engine operation commands and providers must be namespaced"
			),
		}
	if str(operation.get("owningPort", "")) != PORT_ID:
		return {
			"valid": false,
			"message": "Scenario engine operations must use the plug-in bridge port",
		}
	for field_name: String in REQUIRED_OPERATION_FIELDS:
		if not operation.has(field_name):
			return {
				"valid": false,
				"message": "Scenario engine operation '%s' has no %s"
					% [operation_id, field_name],
			}
	return {"valid": true}


static func _required_ids(requirements: Variant) -> Array[String]:
	var result: Array[String] = []
	if requirements is Array:
		for requirement: Variant in requirements:
			if requirement is Dictionary:
				var plugin_id := str(requirement.get("id", ""))
				if not plugin_id.is_empty() and plugin_id not in result:
					result.append(plugin_id)
	result.sort()
	return result


static func _is_namespaced_id(value: String) -> bool:
	if value.contains("/") or value.contains("\\") or value.contains(":") \
			or value.contains(".."):
		return false
	var parts := value.split(".", false)
	if parts.size() < 2:
		return false
	for part: String in parts:
		if part.is_empty():
			return false
		for index: int in range(part.length()):
			var character := part.substr(index, 1).to_lower()
			if not "abcdefghijklmnopqrstuvwxyz0123456789_-".contains(
				character
			):
				return false
	return true


static func _is_safe_entry_point(value: String) -> bool:
	return _is_safe_relative_path(value) \
		and value.ends_with(".gd")


static func _is_safe_relative_path(value: String) -> bool:
	var normalized := value.replace("\\", "/")
	if normalized.is_empty() or normalized != value \
			or normalized.begins_with("/") or normalized.contains(":"):
		return false
	for segment: String in normalized.split("/", false):
		if segment.is_empty() or segment == "." or segment == "..":
			return false
	return true


static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	var lowered := value.to_lower()
	for index: int in range(lowered.length()):
		if not "0123456789abcdef".contains(lowered.substr(index, 1)):
			return false
	return true


static func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


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


static func _is_json_value(value: Variant, depth := 0) -> bool:
	if depth > 16:
		return false
	if value == null or value is bool or value is int \
			or value is float or value is String:
		return true
	if value is Array:
		if value.size() > 256:
			return false
		for child: Variant in value:
			if not _is_json_value(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		if value.size() > 256:
			return false
		for key: Variant in value:
			if not (key is String) \
					or not _is_json_value(value[key], depth + 1):
				return false
		return true
	return false


func _clear() -> void:
	installed.clear()
	providers.clear()
	operations.clear()
	command_providers.clear()
	active_plugins.clear()
	last_error = ""


func _fail(message: String) -> bool:
	last_error = message
	return false
