class_name ScenarioScriptRuntime
extends RefCounted

const StepResultScript = preload(
	"res://scripts/scenario_runtime/scenario_step_result.gd"
)
const CapabilityCatalogScript = preload(
	"res://scripts/scenario_runtime/scenario_capability_catalog.gd"
)
const TrustedExecutorScript = preload(
	"res://scripts/scenario_runtime/scenario_trusted_executor.gd"
)
const SandboxClientScript = preload(
	"res://scripts/scenario_runtime/scenario_sandbox_client.gd"
)

const SCHEMA_VERSION := 2
const API_VERSION := 1
const SNAPSHOT_SCHEMA_VERSION := 1
const MAX_ARRAY_LENGTH := 256
const MAX_STEPS := 256
const MAX_CALL_DEPTH := 32
const MAX_REDUCER_STEPS := 32

var scripts_by_id: Dictionary = {}
var variable_definitions: Dictionary = {}
var persistent_values: Dictionary = {}
var full_script_states: Dictionary = {}
var active_full_script_id := ""
var trace: Array = []
var frames: Array = []
var pending_operation: Dictionary = {}
var runtime_state: ClassicRuntimeState
var bundle: ClassicCampaignBundle
var capability_catalog: ScenarioCapabilityCatalog
var trusted_executor: ScenarioTrustedExecutor
var sandbox_client: ScenarioSandboxClient
var rng_state := 1
var last_error := ""


static func empty_document() -> Dictionary:
	var catalog := CapabilityCatalogScript.new()
	if not catalog.load_builtin():
		return {}
	return {
		"schemaVersion": SCHEMA_VERSION,
		"apiVersion": API_VERSION,
		"capabilityCatalogHash": catalog.catalog_hash(),
		"scripts": [],
		"attachments": [],
		"persistentVariables": [],
	}


func configure(
	script_document: Dictionary,
	classic_state: ClassicRuntimeState,
	campaign_bundle: ClassicCampaignBundle
) -> bool:
	clear()
	var validation := validate_document(script_document, campaign_bundle)
	if not bool(validation.get("valid", false)):
		last_error = str(validation.get("message", "Invalid scenario script document"))
		return false
	runtime_state = classic_state
	bundle = campaign_bundle
	capability_catalog = CapabilityCatalogScript.new()
	if not capability_catalog.load_builtin():
		last_error = capability_catalog.last_error
		return false
	trusted_executor = TrustedExecutorScript.new()
	trusted_executor.configure(bundle, capability_catalog)
	sandbox_client = SandboxClientScript.new()
	for script_value: Variant in script_document.get("scripts", []):
		var script: Dictionary = script_value
		scripts_by_id[str(script.get("id", ""))] = script.duplicate(true)
	for variable_value: Variant in script_document.get("persistentVariables", []):
		var variable: Dictionary = variable_value
		var name := str(variable.get("name", ""))
		variable_definitions[name] = variable.duplicate(true)
		persistent_values[name] = variable.get("defaultValue")
	var hash_text := campaign_bundle.package_hash()
	if hash_text.length() >= 8:
		rng_state = maxi(1, hash_text.substr(0, 8).hex_to_int() & 0x7fffffff)
	return true


func invoke(script_id: String, arguments := {}) -> ScenarioStepResult:
	if not pending_operation.is_empty():
		return StepResultScript.failed("Scenario script runtime is waiting for a command")
	if not scripts_by_id.has(script_id):
		return StepResultScript.failed("Scenario script '%s' is unavailable" % script_id)
	if not frames.is_empty():
		return StepResultScript.failed("Scenario script runtime is already executing")
	var script: Dictionary = scripts_by_id[script_id]
	if str(script.get("tier", "")) != "safe":
		active_full_script_id = script_id
		return _drive_full_script({
			"kind": "invoke",
			"arguments": arguments.duplicate(true) if arguments is Dictionary else {},
		})
	var frame_result := _make_frame(script, arguments, "")
	if str(frame_result.get("status", "")) == "error":
		return StepResultScript.failed(str(frame_result.get("message", "")))
	frames.append(frame_result["frame"])
	return _run()


func resume(response: Dictionary) -> ScenarioStepResult:
	if pending_operation.is_empty():
		return StepResultScript.failed("No scenario script operation is waiting")
	if frames.is_empty():
		if active_full_script_id.is_empty():
			return StepResultScript.failed("Scenario script continuation has no frame")
		var capability := str(pending_operation.get("capability", ""))
		pending_operation.clear()
		return _drive_full_script({
			"kind": "command-result",
			"capability": capability,
			"response": response.duplicate(true),
		})
	var result_name := str(pending_operation.get("result", ""))
	if not result_name.is_empty():
		var value: Variant = response
		if response.has("accepted"):
			value = bool(response["accepted"])
		elif response.has("choice"):
			value = response["choice"]
		_set_local(result_name, value)
	pending_operation.clear()
	return _run()


func snapshot() -> Dictionary:
	return {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"persistentValues": persistent_values.duplicate(true),
		"fullScriptStates": full_script_states.duplicate(true),
		"activeFullScriptId": active_full_script_id,
		"trace": trace.duplicate(true),
		"frames": frames.duplicate(true),
		"pendingOperation": pending_operation.duplicate(true),
		"rngState": rng_state,
	}


func restore(value: Variant) -> Dictionary:
	var validation := validate_snapshot(value)
	if not bool(validation.get("valid", false)):
		return {
			"status": "error",
			"message": validation.get("message", "Invalid scenario script snapshot"),
		}
	var saved: Dictionary = value
	for name: Variant in saved["persistentValues"]:
		if not variable_definitions.has(str(name)):
			return {
				"status": "error",
				"message": "Saved scenario variable '%s' is unavailable" % name,
			}
	persistent_values = saved["persistentValues"].duplicate(true)
	full_script_states = saved["fullScriptStates"].duplicate(true)
	active_full_script_id = str(saved["activeFullScriptId"])
	trace = saved["trace"].duplicate(true)
	frames = saved["frames"].duplicate(true)
	pending_operation = saved["pendingOperation"].duplicate(true)
	rng_state = int(saved["rngState"])
	return {"status": "ok"}


static func validate_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _invalid("Scenario script snapshot must be an object")
	var saved: Dictionary = value
	if int(saved.get("schemaVersion", 0)) != SNAPSHOT_SCHEMA_VERSION:
		return _invalid("Scenario script snapshot schema is unsupported")
	for field_name: String in [
		"persistentValues",
		"fullScriptStates",
		"pendingOperation",
	]:
		if not (saved.get(field_name) is Dictionary):
			return _invalid("Scenario script snapshot.%s must be an object" % field_name)
	if not (saved.get("frames") is Array):
		return _invalid("Scenario script snapshot.frames must be an array")
	if not (saved.get("trace") is Array):
		return _invalid("Scenario script snapshot.trace must be an array")
	if not (saved.get("activeFullScriptId") is String):
		return _invalid("Scenario script snapshot active script ID is invalid")
	if saved["frames"].size() > MAX_CALL_DEPTH:
		return _invalid("Scenario script snapshot exceeds the call-depth limit")
	if not _is_integer(saved.get("rngState")):
		return _invalid("Scenario script snapshot RNG state is invalid")
	if not _is_json_value(saved):
		return _invalid("Scenario script snapshot contains an unsupported value")
	return {"valid": true}


static func validate_document(
	document: Variant,
	campaign_bundle: ClassicCampaignBundle = null
) -> Dictionary:
	if not (document is Dictionary):
		return _invalid("remake/scripts.json must contain an object")
	if int(document.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return _invalid("remake/scripts.json schemaVersion must be %d" % SCHEMA_VERSION)
	if int(document.get("apiVersion", 0)) != API_VERSION:
		return _invalid("remake/scripts.json apiVersion must be %d" % API_VERSION)
	for field_name: String in ["scripts", "attachments", "persistentVariables"]:
		if not (document.get(field_name) is Array):
			return _invalid("remake/scripts.json.%s must be an array" % field_name)
	var catalog := CapabilityCatalogScript.new()
	if not catalog.load_builtin():
		return _invalid(catalog.last_error)
	if str(document.get("capabilityCatalogHash", "")) != catalog.catalog_hash():
		return _invalid("Scenario capability catalog hash does not match this runtime")
	var seen_scripts: Dictionary = {}
	var declared_sources: Dictionary = {}
	for index: int in range(document["scripts"].size()):
		var script_value: Variant = document["scripts"][index]
		var context := "remake/scripts.json.scripts[%d]" % index
		if not (script_value is Dictionary):
			return _invalid("%s must be an object" % context)
		var script: Dictionary = script_value
		var script_id := str(script.get("id", ""))
		if script_id.is_empty() or seen_scripts.has(script_id):
			return _invalid("%s has a missing or duplicate ID" % context)
		seen_scripts[script_id] = true
		if int(script.get("apiVersion", 0)) != API_VERSION:
			return _invalid("%s has an unsupported API version" % context)
		var tier := str(script.get("tier", ""))
		if tier not in ["safe", "sandboxed", "trusted"]:
			return _invalid("%s has an unsupported execution tier" % context)
		if not (script.get("requestedCapabilities") is Array):
			return _invalid("%s.requestedCapabilities must be an array" % context)
		for capability: Variant in script["requestedCapabilities"]:
			if not catalog.has_operation(str(capability)):
				return _invalid(
					"%s requests unavailable capability '%s'" % [context, capability]
				)
		if str(script.get("contentHash", "")).length() != 64 \
				or str(script.get("stateSchemaHash", "")).length() != 64:
			return _invalid("%s has invalid content or state hashes" % context)
		if not (script.get("parameters") is Array) \
				or not (script.get("stateSchema") is Dictionary) \
				or not (script.get("sourceMap") is Dictionary):
			return _invalid("%s has invalid signature, state schema, or source map" % context)
		if _sha256_json(script["stateSchema"]) != str(script["stateSchemaHash"]):
			return _invalid("%s state schema hash does not match" % context)
		if tier == "safe":
			if not (script.get("program") is Dictionary):
				return _invalid("%s requires a safe program" % context)
			if _sha256_json(script["program"]) != str(script["contentHash"]):
				return _invalid("%s safe program hash does not match" % context)
			if script.has("sourcePath"):
				return _invalid("%s cannot declare GDScript source" % context)
		else:
			var source_path := str(script.get("sourcePath", ""))
			if not _is_safe_source_path(source_path) or declared_sources.has(source_path):
				return _invalid("%s has an invalid or duplicate sourcePath" % context)
			declared_sources[source_path] = true
			if campaign_bundle != null and not _source_hash_matches(
				campaign_bundle,
				source_path,
				str(script.get("contentHash", ""))
			):
				return _invalid("%s source hash does not match its manifest" % context)
	for attachment_value: Variant in document["attachments"]:
		if not (attachment_value is Dictionary):
			return _invalid("Scenario script attachment must be an object")
		if not seen_scripts.has(str(attachment_value.get("scriptId", ""))):
			return _invalid("Scenario script attachment references a missing script")
	return {"valid": true}


func declared_sources() -> Dictionary:
	var result: Dictionary = {}
	for script: Variant in scripts_by_id.values():
		var source_path := str(script.get("sourcePath", ""))
		if not source_path.is_empty():
			result[source_path] = str(script.get("tier", ""))
	return result


func required_execution_tiers() -> Array:
	var result: Array = []
	for script: Variant in scripts_by_id.values():
		var tier := str(script.get("tier", ""))
		if not tier.is_empty() and tier not in result:
			result.append(tier)
	result.sort()
	return result


func _drive_full_script(event: Dictionary) -> ScenarioStepResult:
	if active_full_script_id.is_empty() or not scripts_by_id.has(active_full_script_id):
		return StepResultScript.failed("Full scenario script identity is unavailable")
	var script: Dictionary = scripts_by_id[active_full_script_id]
	for _step: int in range(MAX_REDUCER_STEPS):
		var previous_state: Variant = full_script_states.get(active_full_script_id, {})
		var reduced: Dictionary
		match str(script.get("tier", "")):
			"trusted":
				reduced = trusted_executor.step(script, event, previous_state)
			"sandboxed":
				if sandbox_client.process.is_empty() and not sandbox_client.start(bundle):
					return StepResultScript.failed(sandbox_client.last_error)
				reduced = sandbox_client.step(script, event, previous_state)
			_:
				return StepResultScript.failed("Full scenario script tier is invalid")
		var validation := _validate_full_reducer_response(script, reduced)
		if str(validation.get("status", "")) == "error":
			return StepResultScript.failed(str(validation.get("message", "")))
		full_script_states[active_full_script_id] = validation.get("state", {})
		var result: Dictionary = validation.get("result", {})
		trace.append({
			"event": "script-reducer",
			"scriptId": active_full_script_id,
			"tier": str(script.get("tier", "")),
			"resultKind": str(result.get("kind", "")),
			"capability": str(result.get("capability", "")),
		})
		match str(result.get("kind", "")):
			"continue":
				active_full_script_id = ""
				return StepResultScript.continued({"value": result.get("value")})
			"halt":
				active_full_script_id = ""
				return StepResultScript.halted({"value": result.get("value")})
			"error":
				active_full_script_id = ""
				return StepResultScript.failed(str(result.get("message", "Scenario script failed")))
			"yield":
				var capability := str(result.get("capability", ""))
				var arguments: Dictionary = result.get("arguments", {})
				var local_result := _execute_local_full_capability(
					capability,
					arguments
				)
				if str(local_result.get("status", "")) == "handled":
					event = {
						"kind": "operation-result",
						"capability": capability,
						"response": local_result.get("value"),
					}
					continue
				var operation := capability_catalog.operation(capability)
				var command_id := str(operation.get("commandId", ""))
				if command_id.is_empty():
					return StepResultScript.failed(
						"Scenario capability '%s' has no routed command" % capability
					)
				pending_operation = {
					"fullTier": true,
					"scriptId": active_full_script_id,
					"capability": capability,
				}
				return StepResultScript.yielded(
					command_id,
					arguments,
					{"scriptRuntime": true, "scriptId": active_full_script_id}
				)
	return StepResultScript.failed(
		"Scenario script reducer exceeded %d internal steps" % MAX_REDUCER_STEPS
	)


func _execute_local_full_capability(
	capability: String,
	arguments: Dictionary
) -> Dictionary:
	match capability:
		"core.state.read":
			var read_result := _read_state(arguments)
			return (
				{"status": "handled", "value": read_result.get("value")}
				if str(read_result.get("status", "")) == "ok"
				else read_result
			)
		"core.state.write":
			var write_result := _write_state(arguments)
			return (
				{"status": "handled", "value": null}
				if str(write_result.get("status", "")) == "ok"
				else write_result
			)
		"core.rng.roll":
			var maximum := maxi(1, int(arguments.get("maximum", 100)))
			rng_state = int((1103515245 * rng_state + 12345) & 0x7fffffff)
			return {"status": "handled", "value": (rng_state % maximum) + 1}
	return {"status": "external"}


func _validate_full_reducer_response(
	script: Dictionary,
	value: Variant
) -> Dictionary:
	if not (value is Dictionary):
		return {"status": "error", "message": "Scenario reducer response must be an object"}
	if str(value.get("status", "")) == "error":
		return value
	var state: Variant = value.get("state", {})
	var result: Variant = value.get("result", {})
	if not _is_json_value(state) or not (result is Dictionary) \
			or not _is_json_value(result):
		return {"status": "error", "message": "Scenario reducer response must be bounded JSON"}
	if not _state_matches_schema(state, script.get("stateSchema", {})):
		return {
			"status": "error",
			"message": "Scenario reducer state does not match its declared schema",
		}
	var kind := str(result.get("kind", ""))
	if kind not in ["continue", "yield", "halt", "error"]:
		return {"status": "error", "message": "Scenario reducer result is unsupported"}
	if kind == "yield":
		var capability := str(result.get("capability", ""))
		if capability not in script.get("requestedCapabilities", []):
			return {
				"status": "error",
				"message": "Scenario reducer used undeclared capability '%s'" % capability,
			}
		if not capability_catalog.has_operation(capability):
			return {
				"status": "error",
				"message": "Scenario reducer capability '%s' is unavailable" % capability,
			}
		if not (result.get("arguments", {}) is Dictionary):
			return {"status": "error", "message": "Scenario reducer arguments must be an object"}
	return {"status": "ok", "state": state, "result": result}


func _run() -> ScenarioStepResult:
	for _step: int in range(MAX_STEPS):
		if frames.is_empty():
			return StepResultScript.continued()
		var frame: Dictionary = frames[-1]
		var blocks: Array = frame["blocks"]
		if blocks.is_empty():
			_return_from_frame(null)
			continue
		var block: Dictionary = blocks[-1]
		var statements: Array = block.get("statements", [])
		var index := int(block.get("index", 0))
		if index >= statements.size():
			blocks.pop_back()
			frame["blocks"] = blocks
			frames[-1] = frame
			continue
		var statement_value: Variant = statements[index]
		block["index"] = index + 1
		blocks[-1] = block
		frame["blocks"] = blocks
		frames[-1] = frame
		if not (statement_value is Dictionary):
			return StepResultScript.failed("Safe script statement must be an object")
		trace.append({
			"event": "script-execute",
			"scriptId": str(frame.get("scriptId", "")),
			"sourceNode": str(statement_value.get("sourceNode", "")),
			"statementKind": str(statement_value.get("kind", "")),
			"capability": str(statement_value.get("capability", "")),
		})
		var result := _execute_statement(statement_value)
		if result != null:
			return result
	return StepResultScript.failed(
		"Scenario script exceeded %d internal steps" % MAX_STEPS
	)


func _execute_statement(statement: Dictionary) -> ScenarioStepResult:
	match str(statement.get("kind", "")):
		"declare", "assign":
			var name := str(statement.get("name", ""))
			var value_result := _evaluate(statement.get("value"))
			if str(value_result.get("status", "")) == "error":
				return StepResultScript.failed(str(value_result.get("message", "")))
			if str(statement.get("scope", "local")) == "persistent":
				if not variable_definitions.has(name):
					return StepResultScript.failed(
						"Persistent scenario variable '%s' is unavailable" % name
					)
				persistent_values[name] = value_result.get("value")
			else:
				_set_local(name, value_result.get("value"))
		"if":
			var condition := _evaluate(statement.get("condition"))
			if str(condition.get("status", "")) == "error":
				return StepResultScript.failed(str(condition.get("message", "")))
			var selected: Variant = (
				statement.get("then", [])
				if bool(condition.get("value", false))
				else statement.get("else", [])
			)
			if not (selected is Array):
				return StepResultScript.failed("Safe script branch must contain statements")
			_push_block(selected)
		"operation":
			return _execute_operation(statement)
		"call":
			var target_id := str(statement.get("scriptId", ""))
			if not scripts_by_id.has(target_id):
				return StepResultScript.failed(
					"Scenario script '%s' is unavailable" % target_id
				)
			if frames.size() >= MAX_CALL_DEPTH:
				return StepResultScript.failed("Scenario script call depth exceeded")
			var arguments_result := _evaluate_arguments(statement.get("arguments", {}))
			if str(arguments_result.get("status", "")) == "error":
				return StepResultScript.failed(str(arguments_result.get("message", "")))
			var frame_result := _make_frame(
				scripts_by_id[target_id],
				arguments_result.get("value", {}),
				str(statement.get("result", ""))
			)
			if str(frame_result.get("status", "")) == "error":
				return StepResultScript.failed(str(frame_result.get("message", "")))
			frames.append(frame_result["frame"])
		"return":
			var returned: Variant = null
			if statement.has("value"):
				var value_result := _evaluate(statement.get("value"))
				if str(value_result.get("status", "")) == "error":
					return StepResultScript.failed(str(value_result.get("message", "")))
				returned = value_result.get("value")
			_return_from_frame(returned)
		_:
			return StepResultScript.failed(
				"Unsupported safe script statement '%s'" % statement.get("kind", "")
			)
	return null


func _execute_operation(statement: Dictionary) -> ScenarioStepResult:
	var capability := str(statement.get("capability", ""))
	var arguments_result := _evaluate_arguments(statement.get("arguments", {}))
	if str(arguments_result.get("status", "")) == "error":
		return StepResultScript.failed(str(arguments_result.get("message", "")))
	var arguments: Dictionary = arguments_result.get("value", {})
	var result_name := str(statement.get("result", ""))
	match capability:
		"core.state.read":
			var read_result := _read_state(arguments)
			if str(read_result.get("status", "")) == "error":
				return StepResultScript.failed(str(read_result.get("message", "")))
			if not result_name.is_empty():
				_set_local(result_name, read_result.get("value"))
			return null
		"core.state.write":
			var write_result := _write_state(arguments)
			if str(write_result.get("status", "")) == "error":
				return StepResultScript.failed(str(write_result.get("message", "")))
			return null
		"core.rng.roll":
			var maximum := maxi(1, int(arguments.get("maximum", 100)))
			rng_state = int((1103515245 * rng_state + 12345) & 0x7fffffff)
			if not result_name.is_empty():
				_set_local(result_name, (rng_state % maximum) + 1)
			return null
	var command_id := str(capability_catalog.operation(capability).get("commandId", ""))
	if command_id.is_empty():
		return StepResultScript.failed(
			"Scenario script capability '%s' is unavailable" % capability
		)
	pending_operation = {
		"capability": capability,
		"result": result_name,
		"scriptId": str(frames[-1].get("scriptId", "")) if not frames.is_empty() else "",
		"sourceNode": str(statement.get("sourceNode", "")),
	}
	return StepResultScript.yielded(
		command_id,
		arguments,
		{"scriptRuntime": true}
	)


func _read_state(arguments: Dictionary) -> Dictionary:
	match str(arguments.get("scope", "")):
		"quest":
			return {
				"status": "ok",
				"value": runtime_state.get_quest_value(int(arguments.get("id", 0))),
			}
		"persistent":
			var name := str(arguments.get("name", ""))
			if not persistent_values.has(name):
				return {"status": "error", "message": "Unknown variable '%s'" % name}
			return {"status": "ok", "value": persistent_values[name]}
	return {"status": "error", "message": "Unsupported scenario state scope"}


func _write_state(arguments: Dictionary) -> Dictionary:
	match str(arguments.get("scope", "")):
		"quest":
			runtime_state.set_quest_value(
				int(arguments.get("id", 0)),
				int(arguments.get("value", 0))
			)
			return {"status": "ok"}
		"persistent":
			var name := str(arguments.get("name", ""))
			if not persistent_values.has(name):
				return {"status": "error", "message": "Unknown variable '%s'" % name}
			persistent_values[name] = arguments.get("value")
			return {"status": "ok"}
	return {"status": "error", "message": "Unsupported scenario state scope"}


func _evaluate(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"status": "ok", "value": value}
	var expression: Dictionary = value
	match str(expression.get("kind", "")):
		"literal":
			return {"status": "ok", "value": expression.get("value")}
		"variable":
			var name := str(expression.get("name", ""))
			match str(expression.get("scope", "local")):
				"local":
					var locals: Dictionary = frames[-1].get("locals", {})
					if not locals.has(name):
						return {"status": "error", "message": "Unknown local '%s'" % name}
					return {"status": "ok", "value": locals[name]}
				"persistent":
					if not persistent_values.has(name):
						return {"status": "error", "message": "Unknown variable '%s'" % name}
					return {"status": "ok", "value": persistent_values[name]}
				"quest":
					return {
						"status": "ok",
						"value": runtime_state.get_quest_value(int(expression.get("id", 0))),
					}
		"array":
			var values: Array = []
			for child: Variant in expression.get("values", []):
				var child_result := _evaluate(child)
				if str(child_result.get("status", "")) == "error":
					return child_result
				values.append(child_result.get("value"))
			if values.size() > MAX_ARRAY_LENGTH:
				return {"status": "error", "message": "Safe script array exceeds its limit"}
			return {"status": "ok", "value": values}
		"unary":
			var operand := _evaluate(expression.get("operand"))
			if str(operand.get("status", "")) == "error":
				return operand
			match str(expression.get("operator", "")):
				"not":
					return {"status": "ok", "value": not bool(operand.get("value"))}
				"-":
					return {"status": "ok", "value": -operand.get("value")}
		"binary":
			var left := _evaluate(expression.get("left"))
			if str(left.get("status", "")) == "error":
				return left
			var right := _evaluate(expression.get("right"))
			if str(right.get("status", "")) == "error":
				return right
			return _binary(
				str(expression.get("operator", "")),
				left.get("value"),
				right.get("value")
			)
	return {"status": "error", "message": "Unsupported safe script expression"}


func _binary(operator: String, left: Variant, right: Variant) -> Dictionary:
	match operator:
		"+":
			return {"status": "ok", "value": left + right}
		"-":
			return {"status": "ok", "value": left - right}
		"*":
			return {"status": "ok", "value": left * right}
		"/":
			if float(right) == 0.0:
				return {"status": "error", "message": "Safe script divided by zero"}
			return {"status": "ok", "value": left / right}
		"%":
			if int(right) == 0:
				return {"status": "error", "message": "Safe script divided by zero"}
			return {"status": "ok", "value": int(left) % int(right)}
		"==":
			return {"status": "ok", "value": left == right}
		"!=":
			return {"status": "ok", "value": left != right}
		"<":
			return {"status": "ok", "value": left < right}
		"<=":
			return {"status": "ok", "value": left <= right}
		">":
			return {"status": "ok", "value": left > right}
		">=":
			return {"status": "ok", "value": left >= right}
		"and":
			return {"status": "ok", "value": bool(left) and bool(right)}
		"or":
			return {"status": "ok", "value": bool(left) or bool(right)}
	return {"status": "error", "message": "Unsupported safe script operator '%s'" % operator}


func _evaluate_arguments(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {"status": "error", "message": "Script arguments must be an object"}
	var result: Dictionary = {}
	for name: Variant in value:
		var evaluated := _evaluate(value[name])
		if str(evaluated.get("status", "")) == "error":
			return evaluated
		result[str(name)] = evaluated.get("value")
	return {"status": "ok", "value": result}


func _make_frame(script: Dictionary, arguments: Variant, result_target: String) -> Dictionary:
	if not (arguments is Dictionary):
		return {"status": "error", "message": "Script arguments must be an object"}
	var locals: Dictionary = {}
	for parameter_value: Variant in script.get("parameters", []):
		var parameter: Dictionary = parameter_value
		var name := str(parameter.get("name", ""))
		if not arguments.has(name):
			return {
				"status": "error",
				"message": "Scenario script '%s' requires argument '%s'" % [
					script.get("id", ""),
					name,
				],
			}
		locals[name] = arguments[name]
	var program: Dictionary = script.get("program", {})
	var body: Variant = program.get("body", [])
	if not (body is Array):
		return {"status": "error", "message": "Safe script program has no body"}
	return {
		"status": "ok",
		"frame": {
			"scriptId": str(script.get("id", "")),
			"locals": locals,
			"blocks": [{"statements": body.duplicate(true), "index": 0}],
			"resultTarget": result_target,
		},
	}


func _push_block(statements: Array) -> void:
	var frame: Dictionary = frames[-1]
	var blocks: Array = frame["blocks"]
	blocks.append({"statements": statements.duplicate(true), "index": 0})
	frame["blocks"] = blocks
	frames[-1] = frame


func _set_local(name: String, value: Variant) -> void:
	var frame: Dictionary = frames[-1]
	var locals: Dictionary = frame.get("locals", {})
	locals[name] = value
	frame["locals"] = locals
	frames[-1] = frame


func _return_from_frame(value: Variant) -> void:
	var completed: Dictionary = frames.pop_back()
	if frames.is_empty():
		return
	var target := str(completed.get("resultTarget", ""))
	if not target.is_empty():
		_set_local(target, value)


func clear() -> void:
	scripts_by_id.clear()
	variable_definitions.clear()
	persistent_values.clear()
	full_script_states.clear()
	active_full_script_id = ""
	trace.clear()
	frames.clear()
	pending_operation.clear()
	runtime_state = null
	bundle = null
	capability_catalog = null
	trusted_executor = null
	if sandbox_client != null:
		sandbox_client.close()
	sandbox_client = null
	rng_state = 1
	last_error = ""


static func _source_hash_matches(
	campaign_bundle: ClassicCampaignBundle,
	source_path: String,
	content_hash: String
) -> bool:
	var integrity: Variant = campaign_bundle.manifest.get("integrity", {})
	var entries: Variant = integrity.get("files", {}) if integrity is Dictionary else {}
	return entries is Dictionary \
		and entries.has(source_path) \
		and str(entries[source_path].get("sha256", "")).to_lower() == content_hash.to_lower()


static func _sha256_json(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(
		JSON.stringify(_canonical_value(value)).to_utf8_buffer()
	) != OK:
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


static func _is_safe_source_path(path: String) -> bool:
	var normalized := path.replace("\\", "/")
	return normalized.begins_with("remake/source/") \
		and normalized.ends_with(".gd") \
		and not normalized.contains("..") \
		and not normalized.is_absolute_path() \
		and not normalized.contains(":")


static func _is_json_value(value: Variant, depth := 0) -> bool:
	if depth > 16:
		return false
	if value == null or value is bool or value is int or value is float or value is String:
		return true
	if value is Array:
		if value.size() > MAX_ARRAY_LENGTH:
			return false
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


static func _state_matches_schema(value: Variant, schema_value: Variant) -> bool:
	if not (schema_value is Dictionary):
		return false
	var schema: Dictionary = schema_value
	if schema.is_empty():
		return true
	var expected_type := str(schema.get("type", "object"))
	match expected_type:
		"object":
			if not (value is Dictionary):
				return false
			var properties: Variant = schema.get("properties", {})
			if not (properties is Dictionary):
				return false
			var required: Variant = schema.get("required", [])
			if not (required is Array):
				return false
			for field_name: Variant in required:
				if not value.has(str(field_name)):
					return false
			if not bool(schema.get("additionalProperties", true)):
				for field_name: Variant in value:
					if not properties.has(str(field_name)):
						return false
			for field_name: Variant in properties:
				if value.has(field_name) \
						and not _state_matches_schema(value[field_name], properties[field_name]):
					return false
			return true
		"array":
			if not (value is Array):
				return false
			if value.size() > mini(MAX_ARRAY_LENGTH, int(schema.get("maxItems", MAX_ARRAY_LENGTH))):
				return false
			var item_schema: Variant = schema.get("items", {})
			for child: Variant in value:
				if not _state_matches_schema(child, item_schema):
					return false
			return true
		"boolean":
			return value is bool
		"integer":
			return value is int
		"number":
			return value is int or value is float
		"string":
			return value is String \
				and value.length() <= int(schema.get("maxLength", 262144))
		"null":
			return value == null
	return false


static func _is_integer(value: Variant) -> bool:
	return value is int or (value is float and float(value) == floor(float(value)))


static func _invalid(message: String) -> Dictionary:
	return {"valid": false, "message": message}
