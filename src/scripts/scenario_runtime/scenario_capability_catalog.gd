class_name ScenarioCapabilityCatalog
extends RefCounted

const CATALOG_PATH := "res://Data/remake-scenario-capabilities.v1.json"
const SCHEMA_VERSION := 1
const API_VERSION := 1

var document: Dictionary = {}
var operations: Dictionary = {}
var last_error := ""


func load_builtin() -> bool:
	document.clear()
	operations.clear()
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
		operations[operation_id] = row.duplicate(true)
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
