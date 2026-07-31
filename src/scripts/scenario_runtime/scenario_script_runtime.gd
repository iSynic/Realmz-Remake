class_name ScenarioScriptRuntime
extends RefCounted

const StepResultScript = preload(
	"res://scripts/scenario_runtime/scenario_step_result.gd"
)
const CapabilityCatalogScript = preload(
	"res://scripts/scenario_runtime/scenario_capability_catalog.gd"
)
const SandboxClientScript = preload(
	"res://scripts/scenario_runtime/scenario_sandbox_client.gd"
)
const EnginePluginRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_registry.gd"
)

const SCHEMA_VERSION := 2
const API_VERSION := 2
const SNAPSHOT_SCHEMA_VERSION := 3
const MAX_ARRAY_LENGTH := 256
const DEFAULT_MAX_STEPS := 65536
const MAX_CALL_DEPTH := 32
const MAX_REDUCER_STEPS := 32

var scripts_by_id: Dictionary = {}
var variable_definitions: Dictionary = {}
var persistent_values: Dictionary = {}
var transient_values: Dictionary = {}
var full_script_states: Dictionary = {}
var active_full_script_id := ""
var trace: Array = []
var frames: Array = []
var pending_operation: Dictionary = {}
var behavior_bindings: Array = []
var migrations: Array = []
var active_invocation: Dictionary = {}
var suspended_invocations: Array = []
var event_queue: Array = []
var active_spell_effects: Array = []
var next_spell_effect_sequence := 1
var campaign_completion: Dictionary = {}
var completed_value: Variant = null
var debug_enabled := false
var debug_breakpoints: Dictionary = {}
var debug_pause_on_invocation := false
var debug_step_mode := "run"
var debug_depth_target := -1
var debug_pause: Dictionary = {}
var runtime_state: Object
var bundle: Object
var capability_catalog: ScenarioCapabilityCatalog
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
		"behaviors": [],
		"bindings": [],
		"stateDefinitions": [],
		"migrations": [],
	}


func configure(
	script_document: Dictionary,
	scenario_state: Object,
	campaign_bundle: Object
) -> bool:
	clear()
	var validation := validate_document(script_document, campaign_bundle)
	if not bool(validation.get("valid", false)):
		last_error = str(validation.get("message", "Invalid scenario script document"))
		return false
	runtime_state = scenario_state
	bundle = campaign_bundle
	capability_catalog = CapabilityCatalogScript.new()
	if not capability_catalog.load_builtin():
		last_error = capability_catalog.last_error
		return false
	var plugin_catalog_result := _register_plugin_capabilities(
		capability_catalog,
		campaign_bundle
	)
	if not bool(plugin_catalog_result.get("valid", false)):
		last_error = str(plugin_catalog_result.get("message", ""))
		return false
	sandbox_client = SandboxClientScript.new()
	for script_value: Variant in script_document.get("behaviors", []):
		var script: Dictionary = script_value
		var runtime_script: Dictionary = script.duplicate(true)
		if str(runtime_script.get("tier", "")) == "safe" \
				and runtime_script.get("program") is Dictionary:
			var program: Dictionary = runtime_script["program"]
			_assign_debug_source_nodes(program.get("body", []), "/body")
		scripts_by_id[str(script.get("id", ""))] = runtime_script
	for variable_value: Variant in script_document.get("stateDefinitions", []):
		var variable: Dictionary = variable_value
		var key := _state_key(
			str(variable.get("scope", "campaign")),
			str(variable.get("ownerId", "")),
			str(variable.get("name", ""))
		)
		variable_definitions[key] = variable.duplicate(true)
		var default_value: Variant = _duplicate_state_value(
			variable.get("defaultValue")
		)
		if str(variable.get("scope", "campaign")) == "transient":
			transient_values[key] = default_value
		else:
			persistent_values[key] = default_value
	behavior_bindings = script_document.get("bindings", []).duplicate(true)
	migrations = script_document.get("migrations", []).duplicate(true)
	var hash_text := (
		str(campaign_bundle.call("package_hash"))
		if campaign_bundle != null and campaign_bundle.has_method("package_hash")
		else ""
	)
	if hash_text.length() >= 8:
		rng_state = maxi(1, hash_text.substr(0, 8).hex_to_int() & 0x7fffffff)
	return true


static func _assign_debug_source_nodes(statements_value: Variant, path: String) -> void:
	if not (statements_value is Array):
		return
	var statements: Array = statements_value
	for index: int in range(statements.size()):
		if not (statements[index] is Dictionary):
			continue
		var statement: Dictionary = statements[index]
		var statement_path := "%s/%d" % [path, index]
		if str(statement.get("sourceNode", "")).strip_edges().is_empty():
			statement["sourceNode"] = "guided%s" % statement_path
		match str(statement.get("kind", "")):
			"if":
				_assign_debug_source_nodes(
					statement.get("then", []),
					"%s/then" % statement_path
				)
				_assign_debug_source_nodes(
					statement.get("else", []),
					"%s/else" % statement_path
				)
			"for":
				_assign_debug_source_nodes(
					statement.get("body", []),
					"%s/body" % statement_path
				)
			"match":
				var cases_value: Variant = statement.get("cases", [])
				if cases_value is Array:
					for case_index: int in range(cases_value.size()):
						if cases_value[case_index] is Dictionary:
							var case_value: Dictionary = cases_value[case_index]
							_assign_debug_source_nodes(
								case_value.get("body", []),
								"%s/cases/%d/body" % [statement_path, case_index]
							)
				_assign_debug_source_nodes(
					statement.get("default", []),
					"%s/default" % statement_path
				)


func invoke(
	script_id: String,
	arguments := {},
	invocation_context := {}
) -> ScenarioStepResult:
	if not pending_operation.is_empty():
		return StepResultScript.failed("Scenario script runtime is waiting for a command")
	if not scripts_by_id.has(script_id):
		return StepResultScript.failed("Scenario script '%s' is unavailable" % script_id)
	if not frames.is_empty():
		return StepResultScript.failed("Scenario script runtime is already executing")
	completed_value = null
	var script: Dictionary = scripts_by_id[script_id]
	active_invocation = {
		"behaviorId": script_id,
		"role": str(script.get("role", "helper")),
		"hook": str(script.get("hook", "")),
		"context": invocation_context.duplicate(true)
			if invocation_context is Dictionary else {},
	}
	if str(script.get("tier", "")) != "safe":
		active_full_script_id = script_id
		return _drive_full_script({
			"kind": "invoke",
			"arguments": arguments.duplicate(true) if arguments is Dictionary else {},
			"context": active_invocation.get("context", {}),
			"role": active_invocation.get("role", "helper"),
			"hook": active_invocation.get("hook", ""),
		})
	var frame_result := _make_frame(script, arguments, "")
	if str(frame_result.get("status", "")) == "error":
		return StepResultScript.failed(str(frame_result.get("message", "")))
	frames.append(frame_result["frame"])
	if debug_pause_on_invocation:
		debug_step_mode = "into"
	return _run()


func invoke_nested(
	script_id: String,
	arguments := {},
	invocation_context := {}
) -> ScenarioStepResult:
	if _execution_context_active():
		if suspended_invocations.size() >= MAX_CALL_DEPTH:
			return StepResultScript.failed(
				"Scenario behavior nesting exceeded %d suspended invocations"
				% MAX_CALL_DEPTH
			)
		suspended_invocations.append(_capture_execution_context())
		_clear_execution_context()
	return invoke(script_id, arguments, invocation_context)


func behavior_hook_is_pure(script_id: String) -> bool:
	var value: Variant = scripts_by_id.get(script_id, {})
	return value is Dictionary and _behavior_hook_is_pure(value)


func complete_nested_invocation() -> Dictionary:
	_clear_execution_context()
	if suspended_invocations.is_empty():
		return {"status": "ok", "restored": false}
	var saved: Variant = suspended_invocations.pop_back()
	if not (saved is Dictionary):
		return {
			"status": "error",
			"message": "Suspended scenario behavior state is invalid",
		}
	_restore_execution_context(saved)
	return {"status": "ok", "restored": true}


func _execution_context_active() -> bool:
	return (
		not frames.is_empty()
		or not pending_operation.is_empty()
		or not active_full_script_id.is_empty()
		or not active_invocation.is_empty()
	)


func _capture_execution_context() -> Dictionary:
	return {
		"activeFullScriptId": active_full_script_id,
		"activeInvocation": active_invocation.duplicate(true),
		"completedValue": completed_value,
		"frames": frames.duplicate(true),
		"pendingOperation": pending_operation.duplicate(true),
		"debugPause": debug_pause.duplicate(true),
		"debugStepMode": debug_step_mode,
		"debugDepthTarget": debug_depth_target,
	}


func _clear_execution_context() -> void:
	active_full_script_id = ""
	active_invocation.clear()
	completed_value = null
	frames.clear()
	pending_operation.clear()
	debug_pause.clear()
	debug_step_mode = "run"
	debug_depth_target = -1


func _restore_execution_context(saved: Dictionary) -> void:
	active_full_script_id = str(saved.get("activeFullScriptId", ""))
	active_invocation = saved.get("activeInvocation", {}).duplicate(true)
	completed_value = saved.get("completedValue")
	frames = saved.get("frames", []).duplicate(true)
	pending_operation = saved.get("pendingOperation", {}).duplicate(true)
	debug_pause = saved.get("debugPause", {}).duplicate(true)
	debug_step_mode = str(saved.get("debugStepMode", "run"))
	debug_depth_target = int(saved.get("debugDepthTarget", -1))


func resolve_argument_bindings(
	bindings: Variant,
	invocation_context := {}
) -> Dictionary:
	if not (bindings is Dictionary):
		return {
			"status": "error",
			"message": "Behavior argument bindings must be an object",
		}
	var resolved: Dictionary = {}
	for name: Variant in bindings:
		var binding_value: Variant = bindings[name]
		if not (binding_value is Dictionary):
			return {
				"status": "error",
				"message": "Behavior argument '%s' has an invalid binding" % name,
			}
		var binding: Dictionary = binding_value
		match str(binding.get("kind", "")):
			"constant":
				resolved[str(name)] = binding.get("value")
			"record":
				resolved[str(name)] = binding.get("value")
			"context":
				var context_value := _read_context_path(
					invocation_context,
					str(binding.get("value", ""))
				)
				if str(context_value.get("status", "")) != "ok":
					return context_value
				resolved[str(name)] = context_value.get("value")
			"state":
				var state_binding: Variant = binding.get("value")
				var state_arguments := {
					"scope": "campaign",
					"name": str(state_binding),
				}
				if state_binding is Dictionary:
					state_arguments = state_binding.duplicate(true)
				var state_result := _read_state(state_arguments)
				if str(state_result.get("status", "")) != "ok":
					return state_result
				resolved[str(name)] = state_result.get("value")
			_:
				return {
					"status": "error",
					"message": "Behavior argument '%s' uses an unknown binding kind"
						% name,
				}
	return {"status": "ok", "arguments": resolved}


func matching_bindings(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	slot := -1
) -> Array:
	var matches: Array = []
	var normalized_target_ids: Array = []
	for target_id_value: Variant in target_ids:
		normalized_target_ids.append(str(target_id_value))
	for binding_value: Variant in behavior_bindings:
		if not (binding_value is Dictionary):
			continue
		var binding: Dictionary = binding_value
		if str(binding.get("role", "")) != role \
				or str(binding.get("hook", "")) != hook \
				or str(binding.get("targetKind", "")) != target_kind \
				or str(binding.get("recordId", "")) not in normalized_target_ids:
			continue
		if int(slot) >= 0:
			if binding.get("slot") == null \
					or int(binding.get("slot", -1)) != int(slot):
				continue
		elif binding.get("slot") != null:
			continue
		matches.append(binding.duplicate(true))
	matches.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_priority := int(left.get("priority", 0))
		var right_priority := int(right.get("priority", 0))
		return (
			left_priority < right_priority
			or (
				left_priority == right_priority
				and str(left.get("id", "")) < str(right.get("id", ""))
			)
		)
	)
	return matches


func register_spell_effect(
	target_ids: Array,
	request: Dictionary,
	outcome: Dictionary
) -> Dictionary:
	var duration := int(outcome.get("duration", 0))
	if duration <= 0:
		return {"status": "ok", "registered": false}
	if duration > 1000000:
		return {
			"status": "error",
			"message": "Scenario spell-effect duration exceeds the runtime limit",
		}
	var interval := str(outcome.get("interval", ""))
	if interval.is_empty():
		interval = (
			"round"
			if str(request.get("cast", {}).get("mode", "")) == "combat"
			else "minute"
		)
	if interval not in ["round", "move", "minute", "hour", "day"]:
		return {
			"status": "error",
			"message": "Scenario spell effect has an invalid interval",
		}
	var normalized_ids: Array = []
	for target_id_value: Variant in target_ids:
		var target_id := str(target_id_value)
		if not target_id.is_empty() and target_id not in normalized_ids:
			normalized_ids.append(target_id)
	normalized_ids.sort()
	if normalized_ids.is_empty():
		return {
			"status": "error",
			"message": "Scenario spell effect has no stable spell identity",
		}
	var effect_key := str(outcome.get("effectKey", "")).strip_edges()
	if effect_key.is_empty():
		var spell_identity: Dictionary = {}
		var spell_value: Variant = request.get("spell", {})
		if spell_value is Dictionary:
			for field: String in ["id", "stableId", "recordId", "name"]:
				if spell_value.has(field):
					spell_identity[field] = spell_value[field]
		effect_key = _sha256_json({
			"spell": spell_identity,
			"spellTargetIds": normalized_ids,
		}).substr(0, 24)
	var identity_key := _sha256_json({
		"effectKey": effect_key,
		"spellTargetIds": normalized_ids,
	})
	var stacking := str(outcome.get("stacking", "refresh"))
	if stacking not in ["refresh", "replace", "stack"]:
		return {
			"status": "error",
			"message": "Scenario spell effect has an invalid stacking policy",
		}
	if stacking in ["refresh", "replace"]:
		for index: int in range(active_spell_effects.size() - 1, -1, -1):
			var existing: Variant = active_spell_effects[index]
			if not (existing is Dictionary) \
					or str(existing.get("identityKey", "")) != identity_key:
				continue
			if stacking == "refresh":
				existing["remainingTicks"] = duration
				existing["elapsedSeconds"] = 0
				existing["request"] = request.duplicate(true)
				existing["interval"] = interval
				return {
					"status": "ok",
					"registered": true,
					"refreshed": true,
					"effectId": existing.get("id", ""),
				}
			active_spell_effects.remove_at(index)
	var effect_id := "scenario-effect:%d" % next_spell_effect_sequence
	next_spell_effect_sequence += 1
	active_spell_effects.append({
		"id": effect_id,
		"effectKey": effect_key,
		"identityKey": identity_key,
		"spellTargetIds": normalized_ids,
		"request": request.duplicate(true),
		"interval": interval,
		"remainingTicks": duration,
		"elapsedSeconds": 0,
	})
	return {
		"status": "ok",
		"registered": true,
		"effectId": effect_id,
	}


func advance_spell_effects(event_kind: String, event := {}) -> Dictionary:
	if event_kind not in ["round", "move", "time"]:
		return {
			"status": "error",
			"message": "Scenario spell-effect event kind is invalid",
		}
	var event_data: Dictionary = event.duplicate(true) if event is Dictionary else {}
	var deliveries: Array = []
	var survivors: Array = []
	for effect_value: Variant in active_spell_effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value.duplicate(true)
		var remaining := maxi(0, int(effect.get("remainingTicks", 0)))
		var tick_count := 0
		var interval := str(effect.get("interval", ""))
		if remaining > 0 and interval == event_kind:
			tick_count = 1
		elif remaining > 0 and event_kind == "time" \
				and interval in ["minute", "hour", "day"]:
			var interval_seconds := int({
				"minute": 60,
				"hour": 3600,
				"day": 86400,
			}[interval])
			var elapsed := (
				int(effect.get("elapsedSeconds", 0))
				+ maxi(0, int(event_data.get("elapsedSeconds", 0)))
			)
			tick_count = mini(
				remaining,
				mini(
					floori(float(elapsed) / float(interval_seconds)),
					256 - deliveries.size()
				)
			)
			effect["elapsedSeconds"] = (
				elapsed - tick_count * interval_seconds
			)
		tick_count = mini(
			tick_count,
			mini(remaining, 256 - deliveries.size())
		)
		for _tick: int in range(tick_count):
			deliveries.append({
				"hook": "tick",
				"effect": effect.duplicate(true),
				"event": event_data.duplicate(true),
			})
			remaining -= 1
		effect["remainingTicks"] = remaining
		if remaining <= 0:
			deliveries.append({
				"hook": "expire",
				"effect": effect.duplicate(true),
				"event": event_data.duplicate(true),
			})
		else:
			survivors.append(effect)
	active_spell_effects = survivors
	return {
		"status": "ok",
		"deliveries": deliveries,
		"activeCount": active_spell_effects.size(),
	}


func expire_spell_effects(intervals: Array) -> Dictionary:
	var normalized: Array = []
	for interval_value: Variant in intervals:
		var interval := str(interval_value)
		if interval in ["round", "move", "minute", "hour", "day"] \
				and interval not in normalized:
			normalized.append(interval)
	var deliveries: Array = []
	var survivors: Array = []
	for effect_value: Variant in active_spell_effects:
		if not (effect_value is Dictionary):
			continue
		var effect: Dictionary = effect_value
		if str(effect.get("interval", "")) in normalized:
			deliveries.append({
				"hook": "expire",
				"effect": effect.duplicate(true),
				"event": {"reason": "scope-ended"},
			})
		else:
			survivors.append(effect.duplicate(true))
	active_spell_effects = survivors
	return {
		"status": "ok",
		"deliveries": deliveries,
		"activeCount": active_spell_effects.size(),
	}


func mark_campaign_complete(details := {}) -> Dictionary:
	if not campaign_completion.is_empty():
		return {
			"status": "ok",
			"completed": true,
			"alreadyCompleted": true,
			"completion": campaign_completion.duplicate(true),
		}
	var completion_details: Dictionary = (
		details.duplicate(true) if details is Dictionary else {}
	)
	campaign_completion = {
		"completed": true,
		"ending": str(completion_details.get("ending", "complete")),
		"details": completion_details,
	}
	return {
		"status": "ok",
		"completed": true,
		"alreadyCompleted": false,
		"completion": campaign_completion.duplicate(true),
	}


func resume(response: Dictionary) -> ScenarioStepResult:
	if pending_operation.is_empty():
		return StepResultScript.failed("No scenario script operation is waiting")
	if bool(pending_operation.get("debugPause", false)):
		var statement: Dictionary = pending_operation.get("statement", {}).duplicate(true)
		pending_operation.clear()
		debug_pause.clear()
		var statement_result := _execute_statement(statement)
		if statement_result != null:
			return statement_result
		return _run()
	if frames.is_empty():
		if active_full_script_id.is_empty():
			return StepResultScript.failed("Scenario script continuation has no frame")
		var capability := str(pending_operation.get("capability", ""))
		if str(response.get("status", "")) == "error":
			pending_operation.clear()
			return StepResultScript.failed(str(response.get(
				"message",
				"Scenario capability '%s' failed" % capability
			)))
		var full_response := _operation_response_value(capability, response)
		if str(full_response.get("status", "")) != "ok":
			pending_operation.clear()
			return StepResultScript.failed(str(full_response.get(
				"message",
				"Scenario capability returned an invalid result"
			)))
		pending_operation.clear()
		return _drive_full_script({
			"kind": "command-result",
			"capability": capability,
			"response": response.duplicate(true),
			"value": full_response.get("value"),
		})
	if str(response.get("status", "")) == "error":
		var capability_id := str(pending_operation.get("capability", ""))
		pending_operation.clear()
		return StepResultScript.failed(
			str(response.get(
				"message",
				"Scenario capability '%s' failed" % capability_id
			))
		)
	var response_result := _operation_response_value(
		str(pending_operation.get("capability", "")),
		response
	)
	if str(response_result.get("status", "")) != "ok":
		pending_operation.clear()
		return StepResultScript.failed(str(response_result.get(
			"message",
			"Scenario capability returned an invalid result"
		)))
	var result_name := str(pending_operation.get("result", ""))
	if not result_name.is_empty():
		_set_local(result_name, response_result.get("value"))
	pending_operation.clear()
	return _run()


func configure_debugger(breakpoint_values: Variant, pause_on_start := false) -> Dictionary:
	debug_breakpoints.clear()
	if not (breakpoint_values is Array):
		return {
			"status": "error",
			"message": "Scenario debugger breakpoints must be an array",
		}
	for value: Variant in breakpoint_values:
		if not (value is Dictionary):
			return {
				"status": "error",
				"message": "Scenario debugger breakpoint must be an object",
			}
		var behavior_id := str(value.get("behaviorId", ""))
		var source_node := str(value.get("sourceNode", ""))
		if behavior_id.is_empty() or source_node.is_empty():
			return {
				"status": "error",
				"message": "Scenario debugger breakpoint needs behavior and source-node IDs",
			}
		if not debug_breakpoints.has(behavior_id):
			debug_breakpoints[behavior_id] = {}
		debug_breakpoints[behavior_id][source_node] = true
	debug_enabled = pause_on_start or not debug_breakpoints.is_empty()
	debug_pause_on_invocation = pause_on_start
	debug_step_mode = "into" if pause_on_start else "run"
	debug_depth_target = -1
	debug_pause.clear()
	return {"status": "ok"}


func debugger_resume(action: String) -> Dictionary:
	if debug_pause.is_empty():
		return {
			"status": "error",
			"message": "Scenario debugger is not paused",
		}
	match action:
		"step-into":
			debug_step_mode = "into"
		"step-over":
			debug_step_mode = "over"
			debug_depth_target = frames.size()
		"step-out":
			debug_step_mode = "out"
			debug_depth_target = frames.size()
		"resume":
			debug_step_mode = "run"
		_:
			return {
				"status": "error",
				"message": "Scenario debugger action is unsupported",
			}
	return {"status": "ok"}


func debugger_snapshot() -> Dictionary:
	var stack: Array = []
	for suspended_value: Variant in suspended_invocations:
		if not (suspended_value is Dictionary):
			continue
		for frame_value: Variant in suspended_value.get("frames", []):
			if frame_value is Dictionary:
				stack.append(_debug_frame_snapshot(frame_value, true))
	for frame_value: Variant in frames:
		if not (frame_value is Dictionary):
			continue
		stack.append(_debug_frame_snapshot(frame_value, false))
	return {
		"enabled": debug_enabled,
		"paused": not debug_pause.is_empty(),
		"pause": debug_pause.duplicate(true),
		"callStack": stack,
		"persistentValues": persistent_values.duplicate(true),
		"pendingOperation": pending_operation.duplicate(true),
		"eventQueue": event_queue.duplicate(true),
		"activeSpellEffects": active_spell_effects.duplicate(true),
		"campaignCompletion": campaign_completion.duplicate(true),
		"stepMode": debug_step_mode,
	}


static func _debug_frame_snapshot(frame: Dictionary, suspended: bool) -> Dictionary:
	return {
		"behaviorId": str(frame.get("scriptId", "")),
		"locals": frame.get("locals", {}).duplicate(true),
		"blockDepth": (
			frame.get("blocks", []).size()
			if frame.get("blocks", []) is Array else 0
		),
		"suspended": suspended,
	}


func _read_context_path(context: Variant, path: String) -> Dictionary:
	if path.is_empty():
		return {"status": "ok", "value": context}
	var current: Variant = context
	for segment: String in path.split(".", false):
		if not (current is Dictionary) or not current.has(segment):
			return {
				"status": "error",
				"message": "Behavior context has no value '%s'" % path,
			}
		current = current[segment]
	return {"status": "ok", "value": current}


func snapshot() -> Dictionary:
	return {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"persistentValues": persistent_values.duplicate(true),
		"fullScriptStates": full_script_states.duplicate(true),
		"activeFullScriptId": active_full_script_id,
		"activeInvocation": active_invocation.duplicate(true),
		"suspendedInvocations": suspended_invocations.duplicate(true),
		"eventQueue": event_queue.duplicate(true),
		"activeSpellEffects": active_spell_effects.duplicate(true),
		"nextSpellEffectSequence": next_spell_effect_sequence,
		"campaignCompletion": campaign_completion.duplicate(true),
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
		var definition := _definition_for_state_key(str(name))
		if definition.is_empty():
			return {
				"status": "error",
				"message": "Saved scenario variable '%s' is unavailable" % name,
			}
		if not _state_value_matches_definition(
			saved["persistentValues"][name],
			definition
		):
			return {
				"status": "error",
				"message": "Saved scenario variable '%s' has the wrong type" % name,
			}
	persistent_values = saved["persistentValues"].duplicate(true)
	full_script_states = saved["fullScriptStates"].duplicate(true)
	active_full_script_id = str(saved["activeFullScriptId"])
	active_invocation = saved["activeInvocation"].duplicate(true)
	suspended_invocations = saved["suspendedInvocations"].duplicate(true)
	event_queue = saved["eventQueue"].duplicate(true)
	active_spell_effects = saved["activeSpellEffects"].duplicate(true)
	next_spell_effect_sequence = int(saved["nextSpellEffectSequence"])
	campaign_completion = saved["campaignCompletion"].duplicate(true)
	trace = saved["trace"].duplicate(true)
	frames = saved["frames"].duplicate(true)
	pending_operation = saved["pendingOperation"].duplicate(true)
	rng_state = int(saved["rngState"])
	return {"status": "ok"}


func migrate_snapshot(
	value: Variant,
	from_content_version: String,
	to_content_version: String
) -> Dictionary:
	var validation := validate_snapshot(value)
	if not bool(validation.get("valid", false)):
		return {
			"status": "error",
			"message": validation.get("message", "Saved script state is invalid"),
		}
	if from_content_version == to_content_version:
		return {"status": "ok", "snapshot": (value as Dictionary).duplicate(true)}
	var chain: Array = []
	var version := from_content_version
	var visited: Dictionary = {}
	while version != to_content_version:
		if visited.has(version):
			return {
				"status": "error",
				"message": "Scenario state migration chain contains a cycle",
			}
		visited[version] = true
		var next_migration: Dictionary = {}
		for migration_value: Variant in migrations:
			if migration_value is Dictionary \
					and str(migration_value.get("fromContentVersion", "")) == version:
				next_migration = migration_value
				break
		if next_migration.is_empty():
			return {
				"status": "error",
				"message": (
					"No scenario state migration continues from content version '%s'"
					% version
				),
			}
		chain.append(next_migration)
		version = str(next_migration.get("toContentVersion", ""))
		if version.is_empty() or chain.size() > migrations.size():
			return {
				"status": "error",
				"message": "Scenario state migration chain is incomplete",
			}
	var saved: Dictionary = value
	if not saved.get("frames", []).is_empty() \
			or not saved.get("pendingOperation", {}).is_empty() \
			or not saved.get("suspendedInvocations", []).is_empty() \
			or not saved.get("activeSpellEffects", []).is_empty():
		return {
			"status": "error",
			"message": (
				"Scenario updates cannot migrate a save while behavior or spell-effect state is active"
			),
		}
	var defaults := persistent_values.duplicate(true)
	for key: Variant in saved.get("persistentValues", {}):
		if not _definition_for_state_key(str(key)).is_empty():
			persistent_values[str(key)] = saved["persistentValues"][key]
	for migration: Dictionary in chain:
		var behavior_id := str(migration.get("behaviorId", ""))
		var behavior: Dictionary = scripts_by_id.get(behavior_id, {})
		if behavior.is_empty() \
				or str(behavior.get("tier", "")) != "safe" \
				or str(behavior.get("kind", "")) != "helper":
			persistent_values = defaults
			return {
				"status": "error",
				"message": (
					"Migration '%s' must reference a Safe helper behavior"
					% migration.get("id", "")
				),
			}
		var step := invoke(behavior_id, {}, {
			"migration": true,
			"fromContentVersion": migration.get("fromContentVersion", ""),
			"toContentVersion": migration.get("toContentVersion", ""),
		})
		if step == null or step.kind not in [
			ScenarioStepResult.CONTINUE,
			ScenarioStepResult.RETURN,
		]:
			persistent_values = defaults
			frames.clear()
			pending_operation.clear()
			return {
				"status": "error",
				"message": (
					"Migration '%s' must complete without yielding"
					% migration.get("id", "")
				),
			}
	var migrated := snapshot()
	migrated["frames"] = []
	migrated["pendingOperation"] = {}
	migrated["activeInvocation"] = {}
	migrated["activeFullScriptId"] = ""
	migrated["suspendedInvocations"] = []
	return {"status": "ok", "snapshot": migrated}


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
		"activeInvocation",
		"campaignCompletion",
	]:
		if not (saved.get(field_name) is Dictionary):
			return _invalid("Scenario script snapshot.%s must be an object" % field_name)
	if not (saved.get("frames") is Array):
		return _invalid("Scenario script snapshot.frames must be an array")
	if not (saved.get("trace") is Array):
		return _invalid("Scenario script snapshot.trace must be an array")
	if not (saved.get("eventQueue") is Array):
		return _invalid("Scenario script snapshot.eventQueue must be an array")
	if not (saved.get("activeSpellEffects") is Array):
		return _invalid(
			"Scenario script snapshot.activeSpellEffects must be an array"
		)
	if not _is_integer(saved.get("nextSpellEffectSequence")) \
			or int(saved.get("nextSpellEffectSequence", 0)) < 1:
		return _invalid(
			"Scenario script snapshot spell-effect sequence is invalid"
		)
	for effect_value: Variant in saved["activeSpellEffects"]:
		if not (effect_value is Dictionary):
			return _invalid("Saved scenario spell effect must be an object")
		var effect: Dictionary = effect_value
		if str(effect.get("id", "")).is_empty() \
				or str(effect.get("identityKey", "")).is_empty() \
				or str(effect.get("interval", "")) not in [
					"round", "move", "minute", "hour", "day",
				] \
				or not _is_integer(effect.get("remainingTicks")) \
				or int(effect.get("remainingTicks", 0)) < 1 \
				or not _is_integer(effect.get("elapsedSeconds")) \
				or int(effect.get("elapsedSeconds", -1)) < 0 \
				or not (effect.get("spellTargetIds") is Array) \
				or not (effect.get("request") is Dictionary):
			return _invalid("Saved scenario spell effect is malformed")
	if not (saved.get("suspendedInvocations") is Array):
		return _invalid(
			"Scenario script snapshot.suspendedInvocations must be an array"
		)
	if not (saved.get("activeFullScriptId") is String):
		return _invalid("Scenario script snapshot active script ID is invalid")
	if saved["frames"].size() > MAX_CALL_DEPTH:
		return _invalid("Scenario script snapshot exceeds the call-depth limit")
	if saved["suspendedInvocations"].size() > MAX_CALL_DEPTH:
		return _invalid(
			"Scenario script snapshot exceeds the nested-invocation limit"
		)
	for context_value: Variant in saved["suspendedInvocations"]:
		if not (context_value is Dictionary):
			return _invalid("Suspended scenario invocation must be an object")
		var context: Dictionary = context_value
		if not (context.get("frames") is Array) \
				or not (context.get("pendingOperation") is Dictionary) \
				or not (context.get("activeInvocation") is Dictionary) \
				or not (context.get("debugPause") is Dictionary) \
				or not (context.get("activeFullScriptId") is String) \
				or not (context.get("debugStepMode") is String) \
				or not _is_integer(context.get("debugDepthTarget")):
			return _invalid("Suspended scenario invocation is malformed")
		if context["frames"].size() > MAX_CALL_DEPTH:
			return _invalid(
				"Suspended scenario invocation exceeds the call-depth limit"
			)
	if not _is_integer(saved.get("rngState")):
		return _invalid("Scenario script snapshot RNG state is invalid")
	if not _is_json_value(saved):
		return _invalid("Scenario script snapshot contains an unsupported value")
	return {"valid": true}


static func validate_document(
	document: Variant,
	campaign_bundle: Object = null
) -> Dictionary:
	if not (document is Dictionary):
		return _invalid("remake/scripts.json must contain an object")
	if int(document.get("schemaVersion", 0)) != SCHEMA_VERSION:
		return _invalid("remake/scripts.json schemaVersion must be %d" % SCHEMA_VERSION)
	if int(document.get("apiVersion", 0)) != API_VERSION:
		return _invalid("remake/scripts.json apiVersion must be %d" % API_VERSION)
	for field_name: String in [
		"behaviors",
		"bindings",
		"stateDefinitions",
		"migrations",
	]:
		if not (document.get(field_name) is Array):
			return _invalid("remake/scripts.json.%s must be an array" % field_name)
	var catalog := CapabilityCatalogScript.new()
	if not catalog.load_builtin():
		return _invalid(catalog.last_error)
	if str(document.get("capabilityCatalogHash", "")) != catalog.catalog_hash():
		return _invalid("Scenario capability catalog hash does not match this runtime")
	var plugin_catalog_result := _register_plugin_capabilities(
		catalog,
		campaign_bundle
	)
	if not bool(plugin_catalog_result.get("valid", false)):
		return plugin_catalog_result
	var seen_state_definitions: Dictionary = {}
	for index: int in range(document["stateDefinitions"].size()):
		var state_value: Variant = document["stateDefinitions"][index]
		var state_context := "remake/scripts.json.stateDefinitions[%d]" % index
		if not (state_value is Dictionary):
			return _invalid("%s must be an object" % state_context)
		var state: Dictionary = state_value
		var state_name := str(state.get("name", ""))
		var state_scope := str(state.get("scope", ""))
		var owner_id := str(state.get("ownerId", ""))
		var value_type := str(state.get("valueType", ""))
		if not state_name.is_valid_identifier():
			return _invalid("%s has an invalid name" % state_context)
		if state_scope not in [
			"campaign",
			"map",
			"encounter",
			"character",
			"item-instance",
			"combat",
			"transient",
		]:
			return _invalid("%s has an unsupported scope" % state_context)
		if int(state.get("schemaVersion", 0)) < 1:
			return _invalid("%s has an invalid schema version" % state_context)
		if value_type not in [
			"bool",
			"int",
			"float",
			"string",
			"bool-array",
			"int-array",
			"float-array",
			"string-array",
		]:
			return _invalid("%s has an unsupported persistent type" % state_context)
		var max_length_value: Variant = state.get("maxLength")
		if value_type.ends_with("-array"):
			if not (max_length_value is int) \
					or int(max_length_value) < 1 \
					or int(max_length_value) > MAX_ARRAY_LENGTH:
				return _invalid(
					"%s requires maxLength from 1 through %d"
					% [state_context, MAX_ARRAY_LENGTH]
				)
		elif max_length_value != null:
			return _invalid(
				"%s cannot declare maxLength for a scalar" % state_context
			)
		if not _state_value_matches_definition(
			state.get("defaultValue"),
			state
		):
			return _invalid("%s has an invalid default value" % state_context)
		var state_key := _state_key(state_scope, owner_id, state_name)
		if seen_state_definitions.has(state_key):
			return _invalid("%s duplicates another state definition" % state_context)
		seen_state_definitions[state_key] = true
	var seen_scripts: Dictionary = {}
	var declared_sources: Dictionary = {}
	for index: int in range(document["behaviors"].size()):
		var script_value: Variant = document["behaviors"][index]
		var context := "remake/scripts.json.behaviors[%d]" % index
		if not (script_value is Dictionary):
			return _invalid("%s must be an object" % context)
		var script: Dictionary = script_value
		var script_id := str(script.get("id", ""))
		if script_id.is_empty() or seen_scripts.has(script_id):
			return _invalid("%s has a missing or duplicate ID" % context)
		seen_scripts[script_id] = index
		if int(script.get("apiVersion", 0)) != API_VERSION:
			return _invalid("%s has an unsupported API version" % context)
		var tier := str(script.get("tier", ""))
		if tier not in ["safe", "sandboxed"]:
			return _invalid("%s has an unsupported execution tier" % context)
		var behavior_kind := str(script.get("kind", ""))
		var role_id := str(script.get("role", ""))
		if behavior_kind not in ["entry", "helper"]:
			return _invalid("%s has an unsupported behavior kind" % context)
		if behavior_kind == "helper":
			role_id = "helper"
		if not catalog.has_role(role_id):
			return _invalid("%s has an unsupported behavior role" % context)
		var hook_id := str(script.get("hook", ""))
		var expected_return_type := _role_return_type(role_id, hook_id, catalog)
		if behavior_kind == "entry" \
				and str(script.get("returnType", "")) != expected_return_type:
			return _invalid(
				"%s role '%s' must return %s"
				% [context, role_id, expected_return_type]
			)
		if int(script.get("behaviorVersion", 0)) < 1 \
				or int(script.get("stateSchemaVersion", 0)) < 1:
			return _invalid("%s has invalid behavior or state-schema versions" % context)
		if not (script.get("requestedCapabilities") is Array):
			return _invalid("%s.requestedCapabilities must be an array" % context)
		var role_descriptor := catalog.role(role_id)
		var pure_hooks: Variant = role_descriptor.get("pureHooks", [])
		var runtime_hooks: Variant = role_descriptor.get(
			"runtimeHooks",
			role_descriptor.get("hooks", [])
		)
		if behavior_kind == "entry" and (
			not (runtime_hooks is Array) or hook_id not in runtime_hooks
		):
			return _invalid(
				"%s hook '%s' is not connected to a runtime boundary for role '%s'"
				% [context, hook_id, role_id]
			)
		if behavior_kind == "helper" and not hook_id.is_empty():
			return _invalid("%s helper behavior cannot declare a hook" % context)
		var pure_hook: bool = pure_hooks is Array and (
			"*" in pure_hooks or hook_id in pure_hooks
		)
		for capability: Variant in script["requestedCapabilities"]:
			var capability_id := str(capability)
			if not catalog.has_operation(capability_id):
				return _invalid(
					"%s requests unavailable capability '%s'" % [context, capability]
				)
			if not catalog.operation_allowed_for_role(capability_id, role_id):
				return _invalid(
					"%s capability '%s' is unavailable to role '%s'"
					% [context, capability_id, role_id]
				)
			var operation := catalog.operation(capability_id)
			if bool(operation.get("yields", false)) \
					and not bool(role_descriptor.get("allowsYield", false)):
				return _invalid(
					"%s role '%s' cannot use yielding capability '%s'"
					% [context, role_id, capability_id]
				)
			if pure_hook and (
				bool(operation.get("yields", false))
				or bool(operation.get("mutates", false))
			):
				return _invalid(
					"%s pure hook '%s' cannot yield or mutate state"
					% [context, hook_id]
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
	var seen_bindings: Dictionary = {}
	for binding_value: Variant in document["bindings"]:
		if not (binding_value is Dictionary):
			return _invalid("Scenario behavior binding must be an object")
		var binding: Dictionary = binding_value
		var behavior_id := str(binding.get("behaviorId", ""))
		if not seen_scripts.has(behavior_id):
			return _invalid("Scenario behavior binding references a missing behavior")
		var binding_id := str(binding.get("id", ""))
		if binding_id.is_empty() or seen_bindings.has(binding_id):
			return _invalid("Scenario behavior binding has a missing or duplicate ID")
		seen_bindings[binding_id] = true
		var behavior: Dictionary = document["behaviors"][int(seen_scripts[behavior_id])]
		if str(binding.get("role", "")) != str(behavior.get("role", "")) \
				or str(binding.get("hook", "")) != str(behavior.get("hook", "")):
			return _invalid(
				"Scenario behavior binding role and hook must match its behavior"
			)
	var seen_migrations: Dictionary = {}
	var migration_origins: Dictionary = {}
	for migration_value: Variant in document["migrations"]:
		if not (migration_value is Dictionary):
			return _invalid("Scenario state migration must be an object")
		var migration: Dictionary = migration_value
		var migration_id := str(migration.get("id", ""))
		var from_version := str(migration.get("fromContentVersion", ""))
		var to_version := str(migration.get("toContentVersion", ""))
		var migration_behavior_id := str(migration.get("behaviorId", ""))
		if migration_id.is_empty() or seen_migrations.has(migration_id):
			return _invalid("Scenario state migration has a missing or duplicate ID")
		if from_version.is_empty() or to_version.is_empty() \
				or from_version == to_version:
			return _invalid(
				"Scenario state migration must advance between content versions"
			)
		if migration_origins.has(from_version):
			return _invalid(
				"Scenario state migration has an ambiguous content-version origin"
			)
		if not seen_scripts.has(migration_behavior_id):
			return _invalid("Scenario state migration references a missing behavior")
		var migration_behavior: Dictionary = document["behaviors"][
			int(seen_scripts[migration_behavior_id])
		]
		if str(migration_behavior.get("tier", "")) != "safe" \
				or str(migration_behavior.get("kind", "")) != "helper" \
				or not migration_behavior.get("parameters", []).is_empty():
			return _invalid(
				"Scenario state migration must use a parameterless Safe helper"
			)
		seen_migrations[migration_id] = true
		migration_origins[from_version] = to_version
	return {"valid": true}


static func _register_plugin_capabilities(
	catalog: ScenarioCapabilityCatalog,
	campaign_bundle: Object
) -> Dictionary:
	if campaign_bundle == null:
		return {"valid": true}
	var runtime_document: Variant = campaign_bundle.documents.get("runtime", {})
	if not (runtime_document is Dictionary):
		return {"valid": true}
	var requirements: Variant = runtime_document.get("requiredPlugins", [])
	if not (requirements is Array) or requirements.is_empty():
		return {"valid": true}
	var registry := EnginePluginRegistryScript.new()
	if not registry.load_installed_catalog():
		return _invalid(registry.last_error)
	var requirement_validation := registry.validate_requirements(requirements)
	if not bool(requirement_validation.get("valid", false)):
		return requirement_validation
	var operations_by_plugin: Dictionary = {}
	for operation_value: Variant in registry.operation_descriptors(requirements):
		if not (operation_value is Dictionary):
			continue
		var plugin_id := str(operation_value.get("pluginId", ""))
		if not operations_by_plugin.has(plugin_id):
			operations_by_plugin[plugin_id] = []
		operations_by_plugin[plugin_id].append(operation_value)
	for plugin_id: String in operations_by_plugin:
		if not catalog.register_external_operations(
			plugin_id,
			operations_by_plugin[plugin_id]
		):
			return _invalid(catalog.last_error)
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
				active_invocation.clear()
				return StepResultScript.continued({"value": result.get("value")})
			"halt":
				active_full_script_id = ""
				active_invocation.clear()
				return StepResultScript.halted({"value": result.get("value")})
			"error":
				active_full_script_id = ""
				active_invocation.clear()
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
		var role_id := str(script.get("role", "helper"))
		if not capability_catalog.operation_allowed_for_role(capability, role_id):
			return {
				"status": "error",
				"message": "Scenario capability '%s' is unavailable to role '%s'"
					% [capability, role_id],
			}
		if bool(capability_catalog.operation(capability).get("yields", false)) \
				and not _behavior_allows_yield(script):
			return {
				"status": "error",
				"message": "Scenario behavior role '%s' cannot yield"
					% role_id,
			}
		if _active_invocation_hook_is_pure() and (
			bool(capability_catalog.operation(capability).get("yields", false))
			or bool(capability_catalog.operation(capability).get("mutates", false))
		):
			return {
				"status": "error",
				"message": "Pure behavior hook '%s' cannot yield or mutate state"
					% script.get("hook", ""),
			}
		if not (result.get("arguments", {}) is Dictionary):
			return {"status": "error", "message": "Scenario reducer arguments must be an object"}
		var argument_validation := _validate_operation_arguments(
			capability,
			result.get("arguments", {})
		)
		if str(argument_validation.get("status", "")) == "error":
			return argument_validation
	return {"status": "ok", "state": state, "result": result}


func _run() -> ScenarioStepResult:
	var execution_budget := (
		capability_catalog.execution_budget()
		if capability_catalog != null else DEFAULT_MAX_STEPS
	)
	for _step: int in range(execution_budget):
		if frames.is_empty():
			return StepResultScript.continued({"value": completed_value})
		var frame: Dictionary = frames[-1]
		var blocks: Array = frame["blocks"]
		if blocks.is_empty():
			_return_from_frame(null)
			continue
		var block: Dictionary = blocks[-1]
		var statements: Array = block.get("statements", [])
		var index := int(block.get("index", 0))
		if index >= statements.size():
			if block.has("iterator"):
				var iterator: Dictionary = block.get("iterator", {})
				var values: Array = iterator.get("values", [])
				var next_index := int(iterator.get("index", 0)) + 1
				if next_index < values.size():
					iterator["index"] = next_index
					block["iterator"] = iterator
					block["index"] = 0
					blocks[-1] = block
					frame["blocks"] = blocks
					frames[-1] = frame
					_set_local(str(iterator.get("name", "item")), values[next_index])
					continue
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
		if _should_debug_pause(frame, statement_value):
			debug_pause = {
				"behaviorId": str(frame.get("scriptId", "")),
				"sourceNode": str(statement_value.get("sourceNode", "")),
				"statementKind": str(statement_value.get("kind", "")),
				"capability": str(statement_value.get("capability", "")),
				"callDepth": frames.size(),
				"locals": frame.get("locals", {}).duplicate(true),
			}
			pending_operation = {
				"debugPause": true,
				"statement": statement_value.duplicate(true),
			}
			return StepResultScript.yielded(
				"scenario_debug_pause",
				debugger_snapshot(),
				{"scriptRuntime": true, "debugPause": true}
			)
		var result := _execute_statement(statement_value)
		if result != null:
			return result
	return StepResultScript.failed(
		"Scenario script exceeded %d internal steps" % execution_budget
	)


func _should_debug_pause(frame: Dictionary, statement: Dictionary) -> bool:
	if not debug_enabled:
		return false
	var behavior_id := str(frame.get("scriptId", ""))
	var source_node := str(statement.get("sourceNode", ""))
	var behavior_breakpoints: Variant = debug_breakpoints.get(behavior_id, {})
	if behavior_breakpoints is Dictionary \
			and not source_node.is_empty() \
			and bool(behavior_breakpoints.get(source_node, false)):
		return true
	match debug_step_mode:
		"into":
			debug_step_mode = "run"
			return true
		"over":
			if frames.size() <= debug_depth_target:
				debug_step_mode = "run"
				debug_depth_target = -1
				return true
		"out":
			if frames.size() < debug_depth_target:
				debug_step_mode = "run"
				debug_depth_target = -1
				return true
	return false


func _execute_statement(statement: Dictionary) -> ScenarioStepResult:
	match str(statement.get("kind", "")):
		"declare", "assign":
			var name := str(statement.get("name", ""))
			var value_result := _evaluate(statement.get("value"))
			if str(value_result.get("status", "")) == "error":
				return StepResultScript.failed(str(value_result.get("message", "")))
			if str(statement.get("scope", "local")) == "persistent":
				var write_result := _write_named_state(
					str(statement.get("stateScope", "campaign")),
					str(statement.get("ownerId", "")),
					name,
					value_result.get("value")
				)
				if str(write_result.get("status", "")) == "error":
					return StepResultScript.failed(str(
						write_result.get("message", "")
					))
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
		"for":
			var collection_result := _evaluate(statement.get("collection"))
			if str(collection_result.get("status", "")) == "error":
				return StepResultScript.failed(str(collection_result.get("message", "")))
			var values: Variant = collection_result.get("value", [])
			if not (values is Array):
				return StepResultScript.failed("Safe script for-loop requires an array")
			if values.size() > MAX_ARRAY_LENGTH:
				return StepResultScript.failed("Safe script for-loop exceeds its bound")
			var body: Variant = statement.get("body", [])
			if not (body is Array):
				return StepResultScript.failed("Safe script for-loop requires statements")
			if not values.is_empty():
				_push_for_block(str(statement.get("name", "item")), values, body)
		"match":
			var match_result := _evaluate(statement.get("value"))
			if str(match_result.get("status", "")) == "error":
				return StepResultScript.failed(str(match_result.get("message", "")))
			var selected: Variant = statement.get("default", [])
			var cases: Variant = statement.get("cases", [])
			if not (cases is Array):
				return StepResultScript.failed("Safe script match cases are invalid")
			for case_value: Variant in cases:
				if not (case_value is Dictionary):
					return StepResultScript.failed("Safe script match case is invalid")
				var pattern_result := _evaluate(case_value.get("pattern"))
				if str(pattern_result.get("status", "")) == "error":
					return StepResultScript.failed(str(pattern_result.get("message", "")))
				if match_result.get("value") == pattern_result.get("value"):
					selected = case_value.get("body", [])
					break
			if not (selected is Array):
				return StepResultScript.failed("Safe script match branch is invalid")
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
			var active_behavior := _active_behavior()
			var return_type := str(active_behavior.get("returnType", "void"))
			if not _value_matches_script_type(returned, return_type):
				return StepResultScript.failed(
					"Scenario behavior '%s' returned a value that does not match %s"
					% [active_behavior.get("id", ""), return_type]
				)
			_return_from_frame(returned)
		_:
			return StepResultScript.failed(
				"Unsupported safe script statement '%s'" % statement.get("kind", "")
			)
	return null


func _execute_operation(statement: Dictionary) -> ScenarioStepResult:
	var capability := str(statement.get("capability", ""))
	if not capability_catalog.has_operation(capability):
		return StepResultScript.failed(
			"Scenario script capability '%s' is unavailable" % capability
		)
	var behavior: Dictionary = _active_behavior()
	var role_id := str(behavior.get("role", "helper"))
	if not capability_catalog.operation_allowed_for_role(capability, role_id):
		return StepResultScript.failed(
			"Scenario capability '%s' is unavailable to role '%s'"
			% [capability, role_id]
		)
	if bool(capability_catalog.operation(capability).get("yields", false)) \
			and not _behavior_allows_yield(behavior):
		return StepResultScript.failed(
			"Scenario behavior role '%s' cannot yield" % role_id
		)
	if _active_invocation_hook_is_pure() and (
		bool(capability_catalog.operation(capability).get("yields", false))
		or bool(capability_catalog.operation(capability).get("mutates", false))
	):
		return StepResultScript.failed(
			"Pure behavior hook '%s' cannot yield or mutate state"
			% behavior.get("hook", "")
		)
	var arguments_result := _evaluate_arguments(statement.get("arguments", {}))
	if str(arguments_result.get("status", "")) == "error":
		return StepResultScript.failed(str(arguments_result.get("message", "")))
	var arguments: Dictionary = arguments_result.get("value", {})
	var validation := _validate_operation_arguments(capability, arguments)
	if str(validation.get("status", "")) == "error":
		return StepResultScript.failed(str(validation.get("message", "")))
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
	var request := arguments.duplicate(true)
	request["_scenarioApiOperation"] = capability
	return StepResultScript.yielded(
		command_id,
		request,
		{"scriptRuntime": true}
	)


func _operation_response_value(
	capability: String,
	response: Dictionary
) -> Dictionary:
	if capability_catalog == null or not capability_catalog.has_operation(capability):
		return {
			"status": "error",
			"message": "Scenario capability '%s' is unavailable" % capability,
		}
	var operation := capability_catalog.operation(capability)
	var declared_result := str(operation.get("result", "void"))
	if declared_result == "void":
		return {"status": "ok", "value": null}
	var value: Variant = response
	var result_field := str(operation.get("resultField", ""))
	if not result_field.is_empty():
		var resolved := _read_context_path(response, result_field)
		if str(resolved.get("status", "")) != "ok":
			return {
				"status": "error",
				"message": (
					"Scenario capability '%s' response is missing '%s'"
					% [capability, result_field]
				),
			}
		value = resolved.get("value")
	elif response.has("value"):
		value = response.get("value")
	if not _value_matches_catalog_type(value, declared_result):
		return {
			"status": "error",
			"message": (
				"Scenario capability '%s' returned a value that does not match %s"
				% [capability, declared_result]
			),
		}
	return {"status": "ok", "value": value}


func _validate_operation_arguments(
	capability: String,
	arguments: Dictionary
) -> Dictionary:
	if capability_catalog == null or not capability_catalog.has_operation(capability):
		return {
			"status": "error",
			"message": "Scenario capability '%s' is unavailable" % capability,
		}
	var operation := capability_catalog.operation(capability)
	var parameter_value: Variant = operation.get("parameters", {})
	if not (parameter_value is Dictionary):
		return {
			"status": "error",
			"message": "Scenario capability '%s' has an invalid parameter contract"
				% capability,
		}
	var parameters: Dictionary = parameter_value
	for argument_name: Variant in arguments:
		if not parameters.has(str(argument_name)):
			return {
				"status": "error",
				"message": (
					"Scenario capability '%s' received unknown argument '%s'"
					% [capability, argument_name]
				),
			}
	for parameter_name: Variant in parameters:
		var declared_type := str(parameters[parameter_name])
		var optional := declared_type.ends_with("?")
		var argument_name := str(parameter_name)
		if not arguments.has(argument_name):
			if optional:
				continue
			return {
				"status": "error",
				"message": (
					"Scenario capability '%s' requires argument '%s'"
					% [capability, argument_name]
				),
			}
		var value: Variant = arguments[argument_name]
		if optional and value == null:
			continue
		if not _value_matches_catalog_type(value, declared_type.trim_suffix("?")):
			return {
				"status": "error",
				"message": (
					"Scenario capability '%s' argument '%s' does not match %s"
					% [capability, argument_name, declared_type]
				),
			}
	return {"status": "ok"}


func _value_matches_catalog_type(value: Variant, type_id: String) -> bool:
	var optional := type_id.ends_with("?")
	var required_type := type_id.trim_suffix("?")
	if optional and value == null:
		return true
	if "|" in required_type:
		return value is String and str(value) in required_type.split("|", false)
	if required_type.ends_with("-array"):
		if not (value is Array) or value.size() > MAX_ARRAY_LENGTH:
			return false
		var entry_type := required_type.trim_suffix("-array")
		for entry: Variant in value:
			if not _value_matches_catalog_type(entry, entry_type):
				return false
		return true
	match required_type:
		"variant":
			return _is_json_value(value)
		"bool":
			return value is bool
		"int":
			return _is_integer(value)
		"float":
			return value is int or value is float
		"string":
			return value is String
	if capability_catalog != null and capability_catalog.types.has(required_type):
		if not (value is Dictionary):
			return false
		var definition: Dictionary = capability_catalog.types[required_type]
		var field_value: Variant = definition.get("fields", {})
		if not (field_value is Dictionary):
			return false
		for field_name: Variant in field_value:
			var field_type := str(field_value[field_name])
			var field_optional := field_type.ends_with("?")
			if not value.has(str(field_name)):
				if field_optional:
					continue
				return false
			if not _value_matches_catalog_type(value[field_name], field_type):
				return false
		return true
	return _value_matches_script_type(value, _catalog_result_type(required_type))


static func _catalog_result_type(type_id: String) -> String:
	var suffix := ""
	var base := type_id
	if base.ends_with("-array"):
		suffix = "-array"
		base = base.trim_suffix("-array")
	var normalized := base.to_snake_case().replace("_", "-")
	return normalized + suffix


func _read_state(arguments: Dictionary) -> Dictionary:
	match str(arguments.get("scope", "")):
		"quest":
			return {
				"status": "ok",
				"value": runtime_state.get_quest_value(int(arguments.get("id", 0))),
			}
		"persistent":
			return _read_named_state(
				"campaign",
				"",
				str(arguments.get("name", ""))
			)
		"campaign", "map", "encounter", "character", "item-instance", "combat", \
				"transient":
			return _read_named_state(
				str(arguments.get("scope", "campaign")),
				str(arguments.get("ownerId", "")),
				str(arguments.get("name", ""))
			)
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
			return _write_named_state(
				"campaign",
				"",
				str(arguments.get("name", "")),
				arguments.get("value")
			)
		"campaign", "map", "encounter", "character", "item-instance", "combat", \
				"transient":
			return _write_named_state(
				str(arguments.get("scope", "campaign")),
				str(arguments.get("ownerId", "")),
				str(arguments.get("name", "")),
				arguments.get("value")
			)
	return {"status": "error", "message": "Unsupported scenario state scope"}


func _read_named_state(
	scope: String,
	owner_id: String,
	name: String
) -> Dictionary:
	var resolved_owner := _resolve_state_owner(scope, owner_id)
	var key := _state_key(scope, resolved_owner, name)
	var definition := _definition_for_state(scope, resolved_owner, name)
	if definition.is_empty():
		return {
			"status": "error",
			"message": "Unknown scenario state '%s'" % key,
		}
	var values: Dictionary = (
		transient_values if scope == "transient" else persistent_values
	)
	if not values.has(key):
		values[key] = _duplicate_state_value(definition.get("defaultValue"))
	return {
		"status": "ok",
		"value": _duplicate_state_value(values[key]),
	}


func _write_named_state(
	scope: String,
	owner_id: String,
	name: String,
	value: Variant
) -> Dictionary:
	var resolved_owner := _resolve_state_owner(scope, owner_id)
	var key := _state_key(scope, resolved_owner, name)
	var definition := _definition_for_state(scope, resolved_owner, name)
	if definition.is_empty():
		return {
			"status": "error",
			"message": "Unknown scenario state '%s'" % key,
		}
	if not _state_value_matches_definition(value, definition):
		return {
			"status": "error",
			"message": (
				"Scenario state '%s' requires %s"
				% [key, definition.get("valueType", "a declared type")]
			),
		}
	var values: Dictionary = (
		transient_values if scope == "transient" else persistent_values
	)
	values[key] = _duplicate_state_value(value)
	return {"status": "ok"}


func _definition_for_state(
	scope: String,
	owner_id: String,
	name: String
) -> Dictionary:
	var exact_key := _state_key(scope, owner_id, name)
	var exact: Variant = variable_definitions.get(exact_key)
	if exact is Dictionary:
		return exact
	if not owner_id.is_empty():
		var template: Variant = variable_definitions.get(
			_state_key(scope, "", name)
		)
		if template is Dictionary:
			return template
	return {}


func _definition_for_state_key(key: String) -> Dictionary:
	var parts := key.split("\u001f", true)
	if parts.size() != 3:
		return {}
	return _definition_for_state(str(parts[0]), str(parts[1]), str(parts[2]))


func _resolve_state_owner(scope: String, explicit_owner: String) -> String:
	if scope in ["campaign", "transient"] or not explicit_owner.is_empty():
		return explicit_owner
	var context: Variant = active_invocation.get("context", {})
	if not (context is Dictionary):
		return ""
	var contexts: Array[Dictionary] = [context]
	var trigger_context: Variant = context.get("trigger", {})
	if trigger_context is Dictionary:
		var execution_context: Variant = trigger_context.get(
			"executionContext",
			{}
		)
		if execution_context is Dictionary:
			contexts.append(execution_context)
	match scope:
		"map":
			for owner_context: Dictionary in contexts:
				var map_trigger: Variant = owner_context.get("mapTrigger", {})
				if map_trigger is Dictionary:
					var location: Variant = map_trigger.get("location", {})
					if location is Dictionary and not str(
						location.get("mapId", "")
					).is_empty():
						return str(location.get("mapId", ""))
				var world: Variant = owner_context.get("world", {})
				if world is Dictionary:
					var location: Variant = world.get("location", {})
					if location is Dictionary:
						return str(location.get("mapId", ""))
		"encounter":
			for owner_context: Dictionary in contexts:
				var encounter: Variant = owner_context.get("encounter", {})
				if encounter is Dictionary:
					return str(encounter.get("id", ""))
		"character":
			for owner_context: Dictionary in contexts:
				for field_name: String in [
					"character",
					"caster",
					"user",
					"target",
				]:
					var character: Variant = owner_context.get(field_name, {})
					if character is Dictionary:
						var character_id := str(character.get(
							"id",
							character.get("characterId", "")
						))
						if not character_id.is_empty():
							return character_id
		"item-instance":
			for owner_context: Dictionary in contexts:
				var item: Variant = owner_context.get("item", {})
				if item is Dictionary:
					return str(item.get("instanceId", item.get("id", "")))
		"combat":
			for owner_context: Dictionary in contexts:
				var combat: Variant = owner_context.get("combat", {})
				if combat is Dictionary:
					return str(combat.get("id", combat.get("battleId", "")))
	return ""


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
					return _read_named_state(
						str(expression.get("stateScope", "campaign")),
						str(expression.get("ownerId", "")),
						name
					)
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
		"record":
			var fields: Variant = expression.get("fields", {})
			if not (fields is Dictionary):
				return {"status": "error", "message": "Safe script record fields are invalid"}
			var record: Dictionary = {}
			for field_name: Variant in fields:
				var field_result := _evaluate(fields[field_name])
				if str(field_result.get("status", "")) == "error":
					return field_result
				record[str(field_name)] = field_result.get("value")
			return {"status": "ok", "value": record}
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
		"member":
			var object_result := _evaluate(expression.get("object"))
			if str(object_result.get("status", "")) == "error":
				return object_result
			var object_value: Variant = object_result.get("value")
			var member := str(expression.get("member", ""))
			if object_value is Dictionary and object_value.has(member):
				return {"status": "ok", "value": object_value[member]}
			return {
				"status": "error",
				"message": "Safe script value has no member '%s'" % member,
			}
		"collection":
			return _evaluate_collection(expression)
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


func _evaluate_collection(expression: Dictionary) -> Dictionary:
	var source_result := _evaluate(expression.get("collection"))
	if str(source_result.get("status", "")) == "error":
		return source_result
	var source: Variant = source_result.get("value", [])
	if not (source is Array) or source.size() > MAX_ARRAY_LENGTH:
		return {
			"status": "error",
			"message": "Safe collection operation requires a bounded array",
		}
	var operation := str(expression.get("operation", "count"))
	if operation not in ["any", "all", "find", "count", "filter"]:
		return {
			"status": "error",
			"message": "Unsupported collection operation '%s'" % operation,
		}
	if operation != "count" and not expression.has("predicate"):
		return {
			"status": "error",
			"message": "Safe collection operation '%s' requires a predicate" % operation,
		}
	if operation == "count" and not expression.has("predicate"):
		return {"status": "ok", "value": source.size()}
	var item_name := str(expression.get("itemName", "item"))
	var locals: Dictionary = frames[-1].get("locals", {})
	var had_previous := locals.has(item_name)
	var previous: Variant = locals.get(item_name)
	var selected: Array = []
	var matched_count := 0
	for item: Variant in source:
		_set_local(item_name, item)
		var predicate := _evaluate(expression.get("predicate"))
		if str(predicate.get("status", "")) == "error":
			_restore_local(item_name, had_previous, previous)
			return predicate
		if bool(predicate.get("value", false)):
			matched_count += 1
			selected.append(item)
			if operation == "any":
				_restore_local(item_name, had_previous, previous)
				return {"status": "ok", "value": true}
			if operation == "find":
				_restore_local(item_name, had_previous, previous)
				return {"status": "ok", "value": item}
		elif operation == "all":
			_restore_local(item_name, had_previous, previous)
			return {"status": "ok", "value": false}
	_restore_local(item_name, had_previous, previous)
	match operation:
		"any":
			return {"status": "ok", "value": false}
		"all":
			return {"status": "ok", "value": true}
		"count":
			return {"status": "ok", "value": matched_count}
		"filter":
			return {"status": "ok", "value": selected}
		"find":
			return {"status": "ok", "value": null}
	return {"status": "error", "message": "Safe collection operation did not resolve"}


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
	locals["context"] = active_invocation.get("context", {}).duplicate(true)
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


func _push_for_block(name: String, values: Array, statements: Array) -> void:
	_set_local(name, values[0])
	var frame: Dictionary = frames[-1]
	var blocks: Array = frame["blocks"]
	blocks.append({
		"statements": statements.duplicate(true),
		"index": 0,
		"iterator": {
			"name": name,
			"values": values.duplicate(true),
			"index": 0,
		},
	})
	frame["blocks"] = blocks
	frames[-1] = frame


func _set_local(name: String, value: Variant) -> void:
	var frame: Dictionary = frames[-1]
	var locals: Dictionary = frame.get("locals", {})
	locals[name] = value
	frame["locals"] = locals
	frames[-1] = frame


func _restore_local(name: String, had_previous: bool, previous: Variant) -> void:
	var frame: Dictionary = frames[-1]
	var locals: Dictionary = frame.get("locals", {})
	if had_previous:
		locals[name] = previous
	else:
		locals.erase(name)
	frame["locals"] = locals
	frames[-1] = frame


func _return_from_frame(value: Variant) -> void:
	var completed: Dictionary = frames.pop_back()
	if frames.is_empty():
		completed_value = value
		active_invocation.clear()
		return
	var target := str(completed.get("resultTarget", ""))
	if not target.is_empty():
		_set_local(target, value)


func _active_behavior() -> Dictionary:
	if frames.is_empty():
		return {}
	var behavior_id := str(frames[-1].get("scriptId", ""))
	var value: Variant = scripts_by_id.get(behavior_id, {})
	return value if value is Dictionary else {}


func _behavior_hook_is_pure(behavior: Dictionary) -> bool:
	var role := capability_catalog.role(str(behavior.get("role", "helper")))
	var pure_hooks: Variant = role.get("pureHooks", [])
	return pure_hooks is Array and (
		"*" in pure_hooks or str(behavior.get("hook", "")) in pure_hooks
	)


func _active_invocation_hook_is_pure() -> bool:
	var behavior_id := str(active_invocation.get("behaviorId", ""))
	var value: Variant = scripts_by_id.get(behavior_id, {})
	return value is Dictionary and _behavior_hook_is_pure(value)


func _behavior_allows_yield(behavior: Dictionary) -> bool:
	var role := capability_catalog.role(str(behavior.get("role", "helper")))
	return bool(role.get("allowsYield", false))


static func _role_return_type(
	role: String,
	hook: String,
	catalog: Object
) -> String:
	var role_descriptor: Dictionary = catalog.role(role)
	var hook_contracts: Variant = role_descriptor.get("hookContracts", [])
	if hook_contracts is Array:
		for contract_value: Variant in hook_contracts:
			if contract_value is Dictionary \
					and str(contract_value.get("id", "")) == hook \
					and not str(contract_value.get("resultType", "")).is_empty():
				return _catalog_result_type_id(
					str(contract_value.get("resultType", ""))
				)
	match role:
		"action":
			return "action-outcome"
		"encounter":
			return "encounter-outcome"
		"spell":
			return "effect-outcome"
		"item":
			return "item-outcome"
		"monster-ai":
			return "monster-decision"
		"rule-modifier":
			return "rule-modifier"
		"lifecycle":
			return "void"
	return ""


static func _catalog_result_type_id(type_name: String) -> String:
	match type_name:
		"ActionOutcome":
			return "action-outcome"
		"EncounterOutcome":
			return "encounter-outcome"
		"EffectOutcome":
			return "effect-outcome"
		"SpellValidationOutcome":
			return "spell-validation-outcome"
		"SpellCastOutcome":
			return "spell-cast-outcome"
		"SpellEffectOutcome":
			return "spell-effect-outcome"
		"SpellTickOutcome":
			return "spell-tick-outcome"
		"SpellExpirationOutcome":
			return "spell-expiration-outcome"
		"ItemOutcome":
			return "item-outcome"
		"MonsterDecision":
			return "monster-decision"
		"RuleModifier":
			return "rule-modifier"
		"void":
			return "void"
	return type_name


static func _value_matches_script_type(value: Variant, type_id: String) -> bool:
	match type_id:
		"void":
			return value == null
		"bool":
			return value is bool
		"int":
			return _is_integer(value)
		"float":
			return value is int or value is float
		"string":
			return value is String
		"bool-array", "int-array", "float-array", "string-array", \
		"character-snapshot-array":
			if not (value is Array) or value.size() > MAX_ARRAY_LENGTH:
				return false
			for entry: Variant in value:
				var entry_type := type_id.trim_suffix("-array")
				if type_id == "character-snapshot-array":
					entry_type = "character-snapshot"
				if not _value_matches_script_type(entry, entry_type):
					return false
			return true
		"location-snapshot", "time-snapshot", "wealth-snapshot", \
		"character-snapshot", "combat-snapshot":
			return value is Dictionary
		"action-outcome":
			return value is Dictionary and str(value.get("kind", "")) in [
				"continue", "halt", "call", "replace", "return",
			]
		"encounter-outcome":
			return value is Dictionary and str(value.get("kind", "")) in [
				"continue", "resolve", "repeat", "close", "branch",
			]
		"effect-outcome":
			if not (value is Dictionary) or str(value.get("kind", "")) not in [
				"applied", "no-effect", "invalid",
			]:
				return false
			for key: Variant in value:
				match str(key):
					"kind":
						pass
					"duration":
						if not _is_integer(value[key]) \
								or int(value[key]) < 0 \
								or int(value[key]) > 1000000:
							return false
					"interval":
						if str(value[key]) not in [
							"round", "move", "minute", "hour", "day",
						]:
							return false
					"effectKey":
						if not (value[key] is String):
							return false
					"stacking":
						if str(value[key]) not in [
							"refresh", "replace", "stack",
						]:
							return false
					_:
						return false
			return true
		"spell-validation-outcome":
			if not (value is Dictionary) or str(value.get("kind", "")) not in [
				"allowed", "blocked",
			]:
				return false
			for key: Variant in value:
				if str(key) == "kind":
					continue
				if str(key) != "reason" or not (value[key] is String):
					return false
			return true
		"spell-cast-outcome":
			if not (value is Dictionary) or str(value.get("kind", "")) not in [
				"complete", "cancelled",
			]:
				return false
			for key: Variant in value:
				if str(key) == "kind":
					continue
				if str(key) != "reason" or not (value[key] is String):
					return false
			return true
		"spell-effect-outcome":
			if not (value is Dictionary) or str(value.get("kind", "")) not in [
				"applied", "no-effect",
			]:
				return false
			for key: Variant in value:
				match str(key):
					"kind":
						pass
					"duration":
						if not _is_integer(value[key]) \
								or int(value[key]) < 0 \
								or int(value[key]) > 1000000:
							return false
					"interval":
						if str(value[key]) not in [
							"round", "move", "minute", "hour", "day",
						]:
							return false
					"effectKey":
						if not (value[key] is String):
							return false
					"stacking":
						if str(value[key]) not in [
							"refresh", "replace", "stack",
						]:
							return false
					_:
						return false
			return true
		"spell-tick-outcome":
			return value is Dictionary \
				and value.size() == 1 \
				and str(value.get("kind", "")) in ["applied", "no-effect"]
		"spell-expiration-outcome":
			return value is Dictionary \
				and value.size() == 1 \
				and str(value.get("kind", "")) == "complete"
		"item-outcome":
			if not (value is Dictionary) or str(value.get("kind", "")) not in [
				"used", "rejected", "no-effect", "modified",
			]:
				return false
			for key: Variant in value:
				if str(key) == "kind":
					continue
				if str(key) not in ["add", "multiply", "minimum", "maximum"] \
						or not (value[key] is int or value[key] is float) \
						or not is_finite(float(value[key])):
					return false
			return true
		"monster-decision":
			return _valid_monster_decision(value)
		"rule-modifier":
			if not (value is Dictionary):
				return false
			for key: Variant in value:
				if str(key) not in ["add", "multiply", "minimum", "maximum"] \
						or not (value[key] is int or value[key] is float) \
						or not is_finite(float(value[key])):
					return false
			return true
	return false


static func _valid_monster_decision(value: Variant) -> bool:
	if not (value is Dictionary):
		return false
	var kind := str(value.get("kind", ""))
	match kind:
		"wait", "flee":
			return true
		"move":
			return _is_integer(value.get("dx")) and _is_integer(value.get("dy"))
		"attack":
			return not str(value.get("targetId", "")).is_empty()
		"cast":
			return (
				not str(value.get("spellId", "")).is_empty()
				and _is_integer(value.get("power"))
				and not str(value.get("targetId", "")).is_empty()
			)
		"use-item":
			return (
				not str(value.get("itemInstanceId", "")).is_empty()
				and not str(value.get("targetId", "")).is_empty()
			)
	return false


static func _state_key(scope: String, owner_id: String, name: String) -> String:
	return "%s\u001f%s\u001f%s" % [scope, owner_id, name]


static func _state_value_matches_definition(
	value: Variant,
	definition: Dictionary
) -> bool:
	var value_type := str(definition.get("valueType", ""))
	if not _value_matches_script_type(value, value_type):
		return false
	if value_type.ends_with("-array"):
		return (
			value is Array
			and value.size() <= int(definition.get("maxLength", 0))
		)
	return true


static func _duplicate_state_value(value: Variant) -> Variant:
	if value is Dictionary or value is Array:
		return value.duplicate(true)
	return value


func clear() -> void:
	scripts_by_id.clear()
	variable_definitions.clear()
	persistent_values.clear()
	transient_values.clear()
	full_script_states.clear()
	active_full_script_id = ""
	active_invocation.clear()
	suspended_invocations.clear()
	event_queue.clear()
	active_spell_effects.clear()
	next_spell_effect_sequence = 1
	campaign_completion.clear()
	completed_value = null
	debug_enabled = false
	debug_breakpoints.clear()
	debug_pause_on_invocation = false
	debug_step_mode = "run"
	debug_depth_target = -1
	debug_pause.clear()
	behavior_bindings.clear()
	migrations.clear()
	trace.clear()
	frames.clear()
	pending_operation.clear()
	runtime_state = null
	bundle = null
	capability_catalog = null
	if sandbox_client != null:
		sandbox_client.close()
	sandbox_client = null
	rng_state = 1
	last_error = ""


static func _source_hash_matches(
	campaign_bundle: Object,
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
