class_name ScenarioScriptPolicy
extends RefCounted

const SETTINGS_PATH := "user://scenario-script-policy.cfg"
const SETTINGS_SECTION := "developerScripting"
const APPROVAL_SECTION := "trustedPackageApprovals"


func developer_scripting_enabled() -> bool:
	var config := _load()
	return bool(config.get_value(SETTINGS_SECTION, "enabled", false))


func set_developer_scripting_enabled(enabled: bool) -> bool:
	var config := _load()
	config.set_value(SETTINGS_SECTION, "enabled", enabled)
	if not enabled:
		config.erase_section(APPROVAL_SECTION)
	return config.save(SETTINGS_PATH) == OK


func approve_trusted_package(package_hash: String, capabilities: Array) -> bool:
	if not developer_scripting_enabled() or package_hash.length() != 64:
		return false
	var config := _load()
	config.set_value(
		APPROVAL_SECTION,
		package_hash.to_lower(),
		_capability_signature(capabilities)
	)
	return config.save(SETTINGS_PATH) == OK


func revoke_trusted_package(package_hash: String) -> bool:
	var config := _load()
	config.erase_section_key(APPROVAL_SECTION, package_hash.to_lower())
	return config.save(SETTINGS_PATH) == OK


func is_trusted_package_approved(package_hash: String, capabilities: Array) -> bool:
	if not developer_scripting_enabled() or package_hash.length() != 64:
		return false
	var config := _load()
	return str(config.get_value(
		APPROVAL_SECTION,
		package_hash.to_lower(),
		""
	)) == _capability_signature(capabilities)


static func _capability_signature(capabilities: Array) -> String:
	var normalized: Array = []
	for capability: Variant in capabilities:
		normalized.append(str(capability))
	normalized.sort()
	return "|".join(normalized)


static func _load() -> ConfigFile:
	var config := ConfigFile.new()
	if FileAccess.file_exists(SETTINGS_PATH):
		config.load(SETTINGS_PATH)
	return config
