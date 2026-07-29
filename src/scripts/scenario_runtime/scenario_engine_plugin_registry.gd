class_name ScenarioEnginePluginRegistry
extends RefCounted

const INSTALLED_CATALOG_PATH := "user://scenario_plugins/installed.json"
const SCHEMA_VERSION := 1

var installed: Dictionary = {}
var providers: Dictionary = {}
var last_error := ""


func load_installed_catalog() -> bool:
	installed.clear()
	providers.clear()
	last_error = ""
	if not FileAccess.file_exists(INSTALLED_CATALOG_PATH):
		return true
	var parser := JSON.new()
	var error := parser.parse(FileAccess.get_file_as_string(INSTALLED_CATALOG_PATH))
	if error != OK or not (parser.data is Dictionary):
		return _fail("Installed scenario plug-in catalog is invalid")
	var document: Dictionary = parser.data
	if int(document.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return _fail("Installed scenario plug-in catalog version is unsupported")
	var entries: Variant = document.get("plugins", [])
	if not (entries is Array):
		return _fail("Installed scenario plug-in catalog has no plug-in list")
	for entry_value: Variant in entries:
		if not (entry_value is Dictionary):
			return _fail("Installed scenario plug-in descriptor is invalid")
		var entry: Dictionary = entry_value
		var plugin_id := str(entry.get("id", ""))
		if not _is_namespaced_id(plugin_id) or installed.has(plugin_id):
			return _fail("Installed scenario plug-in IDs must be unique and namespaced")
		if int(entry.get("apiVersion", 0)) <= 0:
			return _fail("Installed scenario plug-in '%s' has no API version" % plugin_id)
		if not (entry.get("approved") is bool):
			return _fail("Installed scenario plug-in '%s' has no approval state" % plugin_id)
		installed[plugin_id] = entry.duplicate(true)
	return true


func validate_requirements(requirements: Variant) -> Dictionary:
	if not (requirements is Array):
		return {
			"valid": false,
			"message": "runtime.requiredPlugins must be an array",
		}
	for requirement_value: Variant in requirements:
		if not (requirement_value is Dictionary):
			return {"valid": false, "message": "Scenario plug-in requirement is invalid"}
		var requirement: Dictionary = requirement_value
		var plugin_id := str(requirement.get("id", ""))
		var api_version := int(requirement.get("apiVersion", 0))
		if not _is_namespaced_id(plugin_id) or api_version <= 0:
			return {
				"valid": false,
				"message": "Scenario plug-in requirements need a namespaced ID and API version",
			}
		if not installed.has(plugin_id):
			return {
				"valid": false,
				"message": "Required engine plug-in '%s' is not installed" % plugin_id,
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
				"message": "Required engine plug-in '%s' is installed but not approved"
					% plugin_id,
			}
	return {"valid": true}


func register_provider(
	plugin_id: String,
	provider_id: String,
	provider: Callable
) -> bool:
	if not installed.has(plugin_id) or not bool(installed[plugin_id].get("approved", false)):
		return _fail("Scenario engine plug-in '%s' is not approved" % plugin_id)
	if not provider_id.begins_with(plugin_id + ".") or providers.has(provider_id):
		return _fail("Scenario engine plug-in provider IDs must be unique and namespaced")
	if not provider.is_valid():
		return _fail("Scenario engine plug-in provider '%s' is invalid" % provider_id)
	providers[provider_id] = provider
	return true


func invoke_provider(provider_id: String, request: Dictionary) -> Dictionary:
	var provider: Callable = providers.get(provider_id)
	if not provider.is_valid():
		return {
			"status": "error",
			"message": "Scenario engine provider '%s' is unavailable" % provider_id,
		}
	var result: Variant = provider.call(request.duplicate(true))
	return result if result is Dictionary else {
		"status": "error",
		"message": "Scenario engine provider '%s' returned an invalid result" % provider_id,
	}


static func _is_namespaced_id(value: String) -> bool:
	var separator := value.find(".")
	return separator > 0 and separator < value.length() - 1


func _fail(message: String) -> bool:
	last_error = message
	return false
