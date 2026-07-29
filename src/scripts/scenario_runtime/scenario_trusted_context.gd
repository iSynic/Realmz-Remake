class_name ScenarioTrustedContext
extends RefCounted

var _declared_capabilities: Dictionary = {}


func configure(capabilities: Array) -> void:
	_declared_capabilities.clear()
	for capability: Variant in capabilities:
		_declared_capabilities[str(capability)] = true


func command(capability: String, arguments := {}) -> Dictionary:
	if not _declared_capabilities.has(capability):
		return {
			"kind": "error",
			"message": "Scenario script requested undeclared capability '%s'" % capability,
		}
	if not (arguments is Dictionary):
		return {
			"kind": "error",
			"message": "Scenario script command arguments must be an object",
		}
	return {
		"kind": "yield",
		"capability": capability,
		"arguments": arguments.duplicate(true),
	}


func continued(value: Variant = null) -> Dictionary:
	return {"kind": "continue", "value": value}


func halted(value: Variant = null) -> Dictionary:
	return {"kind": "halt", "value": value}


func failed(message: String) -> Dictionary:
	return {"kind": "error", "message": message}
