class_name ScenarioTrustedExecutor
extends RefCounted

const PolicyScript = preload(
	"res://scripts/scenario_runtime/scenario_script_policy.gd"
)
const ContextScript = preload(
	"res://scripts/scenario_runtime/scenario_trusted_context.gd"
)
const MAX_STATE_BYTES := 262144
const MAX_JSON_DEPTH := 16

var bundle: ClassicCampaignBundle
var capability_catalog: ScenarioCapabilityCatalog
var instances: Dictionary = {}
var package_capabilities: Array = []
var last_error := ""


func configure(
	campaign_bundle: ClassicCampaignBundle,
	catalog: ScenarioCapabilityCatalog
) -> void:
	bundle = campaign_bundle
	capability_catalog = catalog
	instances.clear()
	package_capabilities.clear()
	var script_document: Variant = bundle.documents.get("remakeScripts", {})
	if script_document is Dictionary:
		for script_value: Variant in script_document.get("scripts", []):
			if not (script_value is Dictionary) \
					or str(script_value.get("tier", "")) != "trusted":
				continue
			for capability: Variant in script_value.get("requestedCapabilities", []):
				var capability_id := str(capability)
				if capability_id not in package_capabilities:
					package_capabilities.append(capability_id)
	package_capabilities.sort()
	last_error = ""


func step(script: Dictionary, event: Dictionary, previous_state: Variant) -> Dictionary:
	var capabilities: Array = script.get("requestedCapabilities", [])
	if not PolicyScript.new().is_trusted_package_approved(
		bundle.package_hash(),
		package_capabilities
	):
		return _error(
			"Trusted scenario script '%s' requires Developer Scripting and approval "
			+ "for package %s" % [script.get("id", ""), bundle.package_hash()]
		)
	var instance_result := _instance_for(script)
	if str(instance_result.get("status", "")) == "error":
		return instance_result
	var context := ContextScript.new()
	context.configure(capabilities)
	var returned: Variant = instance_result["instance"].call(
		"step",
		event.duplicate(true),
		previous_state,
		context
	)
	return _validate_reducer_result(script, returned)


func _instance_for(script: Dictionary) -> Dictionary:
	var script_id := str(script.get("id", ""))
	if instances.has(script_id):
		return {"status": "ok", "instance": instances[script_id]}
	var source_path := str(script.get("sourcePath", ""))
	var absolute_path := bundle.root_directory.path_join(source_path)
	var source := FileAccess.get_file_as_string(absolute_path)
	if source.is_empty() and FileAccess.get_open_error() != OK:
		return _error("Trusted scenario script source is unavailable")
	var compiled := GDScript.new()
	compiled.source_code = source
	var compile_error := compiled.reload()
	if compile_error != OK:
		return _error(
			"Trusted scenario script '%s' did not compile (%s)"
			% [script_id, error_string(compile_error)]
		)
	var instance: Object = compiled.new()
	if instance == null or not instance.has_method("step"):
		return _error("Trusted scenario script '%s' has no step reducer" % script_id)
	instances[script_id] = instance
	return {"status": "ok", "instance": instance}


func _validate_reducer_result(script: Dictionary, value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _error("Scenario script reducer must return an object")
	var state: Variant = value.get("state", {})
	var result: Variant = value.get("result", {})
	if not _is_json_value(state) or JSON.stringify(state).to_utf8_buffer().size() > MAX_STATE_BYTES:
		return _error("Scenario script reducer state exceeds JSON limits")
	if not (result is Dictionary) or not _is_json_value(result):
		return _error("Scenario script reducer result must be bounded JSON")
	var kind := str(result.get("kind", ""))
	if kind not in ["continue", "yield", "halt", "error"]:
		return _error("Scenario script reducer returned unsupported result '%s'" % kind)
	if kind == "yield":
		var capability := str(result.get("capability", ""))
		if capability not in script.get("requestedCapabilities", []):
			return _error(
				"Scenario script reducer returned undeclared capability '%s'" % capability
			)
		if not capability_catalog.has_operation(capability):
			return _error(
				"Scenario script reducer returned unavailable capability '%s'" % capability
			)
		if not (result.get("arguments", {}) is Dictionary):
			return _error("Scenario script reducer command arguments must be an object")
	return {
		"status": "ok",
		"state": state.duplicate(true) if state is Dictionary or state is Array else state,
		"result": result.duplicate(true),
	}


static func _is_json_value(value: Variant, depth := 0) -> bool:
	if depth > MAX_JSON_DEPTH:
		return false
	if value == null or value is bool or value is int or value is float or value is String:
		return true
	if value is Array:
		for child: Variant in value:
			if not _is_json_value(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not (key is String) or not _is_json_value(value[key], depth + 1):
				return false
		return true
	return false


static func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
