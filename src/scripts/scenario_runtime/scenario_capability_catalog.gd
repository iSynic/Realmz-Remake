class_name ScenarioCapabilityCatalog
extends RefCounted

const CATALOG_PATH := "res://Data/remake-scenario-capabilities.v2.json"
const SCHEMA_VERSION := 2
const API_VERSION := 2

var document: Dictionary = {}
var operations: Dictionary = {}
var roles: Dictionary = {}
var types: Dictionary = {}
var last_error := ""


func load_builtin() -> bool:
	document.clear()
	operations.clear()
	roles.clear()
	types.clear()
	last_error = ""
	var parser := JSON.new()
	var error := parser.parse(FileAccess.get_file_as_string(CATALOG_PATH))
	if error != OK or not (parser.data is Dictionary):
		return _fail("Built-in scenario capability catalog is invalid")
	document = parser.data
	if int(document.get("schemaVersion", 0)) != SCHEMA_VERSION \
			or int(document.get("apiVersion", 0)) != API_VERSION:
		return _fail("Built-in scenario capability catalog version is unsupported")
	var rows: Variant = document.get("operations", [])
	if not (rows is Array):
		return _fail("Built-in scenario capability operations must be an array")
	for row_value: Variant in rows:
		if not (row_value is Dictionary):
			return _fail("Built-in scenario capability must be an object")
		var row: Dictionary = row_value
		var operation_id := str(row.get("id", ""))
		if operation_id.is_empty() or operations.has(operation_id):
			return _fail("Built-in scenario capability IDs must be unique")
		for required_field: String in [
			"label",
			"category",
			"owningPort",
			"minimumTier",
			"roles",
			"yields",
			"mutates",
			"parameters",
			"result",
			"summary",
			"reference",
			"example",
		]:
			if not row.has(required_field):
				return _fail(
					"Built-in scenario capability '%s' has no %s"
					% [operation_id, required_field]
				)
		operations[operation_id] = row.duplicate(true)
	var role_rows: Variant = document.get("roles", [])
	if not (role_rows is Array):
		return _fail("Built-in scenario capability roles must be an array")
	for role_value: Variant in role_rows:
		if not (role_value is Dictionary):
			return _fail("Built-in scenario role must be an object")
		var role_id := str(role_value.get("id", ""))
		if role_id.is_empty() or roles.has(role_id):
			return _fail("Built-in scenario role IDs must be unique")
		roles[role_id] = role_value.duplicate(true)
	var type_rows: Variant = document.get("types", [])
	if not (type_rows is Array):
		return _fail("Built-in scenario capability types must be an array")
	for type_value: Variant in type_rows:
		if not (type_value is Dictionary):
			return _fail("Built-in scenario type must be an object")
		var type_id := str(type_value.get("id", ""))
		if type_id.is_empty() or types.has(type_id):
			return _fail("Built-in scenario type IDs must be unique")
		types[type_id] = type_value.duplicate(true)
	return true


func has_operation(operation_id: String) -> bool:
	return operations.has(operation_id)


func operation(operation_id: String) -> Dictionary:
	var value: Variant = operations.get(operation_id, {})
	return value.duplicate(true) if value is Dictionary else {}


func operation_ids() -> Array:
	var result := operations.keys()
	result.sort()
	return result


func register_external_operations(
	plugin_id: String,
	rows: Variant
) -> bool:
	if plugin_id.begins_with("core.") or not (rows is Array):
		return _fail("Scenario plug-in capability registration is invalid")
	for row_value: Variant in rows:
		if not (row_value is Dictionary):
			return _fail("Scenario plug-in capability must be an object")
		var row: Dictionary = row_value
		var operation_id := str(row.get("id", ""))
		if not operation_id.begins_with(plugin_id + ".") \
				or operations.has(operation_id):
			return _fail(
				"Scenario plug-in capability IDs must be unique and namespaced"
			)
		for required_field: String in [
			"label",
			"category",
			"owningPort",
			"minimumTier",
			"roles",
			"yields",
			"mutates",
			"parameters",
			"result",
			"summary",
			"reference",
			"example",
		]:
			if not row.has(required_field):
				return _fail(
					"Scenario plug-in capability '%s' has no %s"
					% [operation_id, required_field]
				)
		var allowed_roles: Variant = row.get("roles", [])
		if not (allowed_roles is Array):
			return _fail(
				"Scenario plug-in capability '%s' has invalid roles"
				% operation_id
			)
		for role_id: Variant in allowed_roles:
			if not roles.has(str(role_id)):
				return _fail(
					"Scenario plug-in capability '%s' uses an unknown role"
					% operation_id
				)
		operations[operation_id] = row.duplicate(true)
	return true


func has_role(role_id: String) -> bool:
	return roles.has(role_id)


func role(role_id: String) -> Dictionary:
	var value: Variant = roles.get(role_id, {})
	return value.duplicate(true) if value is Dictionary else {}


func operation_allowed_for_role(operation_id: String, role_id: String) -> bool:
	if not operations.has(operation_id):
		return false
	var allowed: Variant = operations[operation_id].get("roles", [])
	return allowed is Array and role_id in allowed


func execution_budget() -> int:
	return maxi(1, int(document.get("executionBudget", 65536)))


func catalog_hash() -> String:
	var bytes := JSON.stringify(_canonical_value(document)).to_utf8_buffer()
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


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


func _fail(message: String) -> bool:
	last_error = message
	return false
