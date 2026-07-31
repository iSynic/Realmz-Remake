class_name ScenarioSaveContract
extends RefCounted

const SCHEMA_VERSION := 6
const REQUIRED_FIELDS := [
	"schemaVersion",
	"campaignId",
	"contentVersion",
	"packageHash",
	"capabilityCatalogHash",
	"behaviorHashes",
	"stateSchemaVersions",
	"interpreter",
	"pendingCommand",
	"resolvedGameplayRules",
	"requiredPlugins",
]


static func validate(payload: Variant) -> Dictionary:
	if not (payload is Dictionary):
		return _error("Scenario save payload must be an object")
	if int(payload.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return _error(
			"Scenario save schema %d is unsupported; this build requires schema %d"
			% [int(payload.get("schemaVersion", 0)), SCHEMA_VERSION]
		)
	for field: String in REQUIRED_FIELDS:
		if not payload.has(field):
			return _error("Scenario save payload is missing '%s'" % field)
	for hash_field: String in ["packageHash", "capabilityCatalogHash"]:
		if not _is_sha256(str(payload.get(hash_field, ""))):
			return _error("Scenario save field '%s' is not a SHA-256 hash" % hash_field)
	for object_field: String in [
		"behaviorHashes",
		"stateSchemaVersions",
		"interpreter",
		"resolvedGameplayRules",
	]:
		if not (payload.get(object_field) is Dictionary):
			return _error("Scenario save field '%s' must be an object" % object_field)
	if not (payload.get("requiredPlugins") is Array):
		return _error("Scenario save requiredPlugins must be an array")
	return {"valid": true, "message": ""}


static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _error(message: String) -> Dictionary:
	return {"valid": false, "message": message}
