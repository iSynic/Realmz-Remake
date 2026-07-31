class_name ScenarioSaveContract
extends RefCounted

const SCHEMA_VERSION := 7
const REQUIRED_FIELDS := [
	"schemaVersion",
	"campaignId",
	"campaignKind",
	"implementationKind",
	"contentVersion",
	"packageHash",
	"capabilityCatalogHash",
	"behaviorHashes",
	"stateSchemaVersions",
	"interpreter",
	"pendingCommand",
	"activeResponseRef",
	"activeResultRef",
	"mixedSequenceCursor",
	"resultTransitionCount",
	"attachmentOrder",
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
		"mixedSequenceCursor",
		"resolvedGameplayRules",
	]:
		if not (payload.get(object_field) is Dictionary):
			return _error("Scenario save field '%s' must be an object" % object_field)
	if not (payload.get("requiredPlugins") is Array):
		return _error("Scenario save requiredPlugins must be an array")
	if not (payload.get("attachmentOrder") is Array):
		return _error("Scenario save attachmentOrder must be an array")
	if payload.get("activeResponseRef") != null \
			and not (payload.get("activeResponseRef") is Dictionary):
		return _error("Scenario save activeResponseRef must be an object or null")
	if payload.get("activeResultRef") != null \
			and not (payload.get("activeResultRef") is Dictionary):
		return _error("Scenario save activeResultRef must be an object or null")
	if not (payload.get("resultTransitionCount") is int) \
			or int(payload.get("resultTransitionCount", -1)) < 0:
		return _error("Scenario save resultTransitionCount must be a non-negative integer")
	if str(payload.get("campaignKind", "")) not in [
		"classic-interpreted",
		"classic-enhanced",
		"remake-authored",
	]:
		return _error("Scenario save campaignKind is unsupported")
	if str(payload.get("implementationKind", "")) != "scenario-interpreter":
		return _error("Scenario save interpreter implementation is unsupported")
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
