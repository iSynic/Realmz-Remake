class_name ClassicRuntimeHost
extends Node

const DefaultScenarioPortsScript = preload(
	"res://scripts/scenario_runtime/default_scenario_ports.gd"
)
const ScenarioRuleModifierPipelineScript = preload(
	"res://scripts/scenario_runtime/scenario_rule_modifier_pipeline.gd"
)
const EnginePluginRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_registry.gd"
)
const EnginePluginPortScript = preload(
	"res://scripts/scenario_runtime/ports/scenario_engine_plugin_port.gd"
)
const SemanticStateScript = preload(
	"res://scripts/scenario_runtime/scenario_semantic_state.gd"
)
const ClassicDungeonViewModelScript = preload(
	"res://scripts/classic_runtime/classic_dungeon_view_model.gd"
)

const ENHANCED_DISPATCH_TRIGGER_ID := "__scenario_enhanced_global_dispatch__"

signal command_started(command: String, payload: Dictionary)
signal command_finished(command: String, response: Dictionary)
signal playthrough_completed(result: Dictionary)
signal playthrough_stopped(result: Dictionary)
signal playthrough_finished(result: Dictionary)
signal classic_dungeon_view_changed(snapshot: Dictionary)

var runtime: ClassicRuntime
var command_adapter: Object
var command_router: ScenarioCommandRouter
var gameplay_rule_set: GameplayRuleSet
var rule_modifier_pipeline: ScenarioRuleModifierPipeline
var engine_plugin_registry: ScenarioEnginePluginRegistry
var active := false
var command_context: Dictionary = {}
var nested_trigger_active := false
var restored_continuation_pending := false
var _bound_behavior_active := false
var _bound_behavior_depth := 0
var _campaign_completion_active := false
var _script_event_queue_draining := false
var _campaign_start_pending := false
var manual_control_active := false
var enhanced_trigger_state: ScenarioSemanticState
var enhanced_event_triggers_by_id: Dictionary = {}
var enhanced_scheduled_triggers_by_id: Dictionary = {}


func _init() -> void:
	runtime = ClassicRuntime.new()
	add_child(runtime)
	runtime.command_requested.connect(_on_command_requested)
	runtime.trigger_completed.connect(_on_trigger_completed)
	runtime.runtime_stopped.connect(_on_runtime_stopped)


func configure(adapter: Object, rules: GameplayRuleSet = null) -> void:
	command_adapter = adapter
	gameplay_rule_set = rules
	_create_command_router()
	if (
		command_router != null
		and runtime != null
		and runtime.bundle != null
		and runtime.bundle.extension_registry != null
	):
		_configure_extensions(false)


func _create_command_router() -> void:
	var router_result := DefaultScenarioPortsScript.create(
		command_adapter,
		gameplay_rule_set
	)
	if str(router_result.get("status", "")) == "ok":
		command_router = router_result["router"]
	else:
		command_router = null
		push_error(str(router_result.get("message", "Scenario command router is unavailable")))


func load_campaign(directory: String) -> bool:
	active = false
	nested_trigger_active = false
	restored_continuation_pending = false
	command_context.clear()
	_clear_enhanced_global_triggers()
	if not runtime.load_campaign(directory):
		return false
	_create_command_router()
	if not _configure_extensions():
		return false
	_configure_adapter()
	return true


func use_campaign(campaign_bundle: ClassicCampaignBundle) -> void:
	active = false
	nested_trigger_active = false
	restored_continuation_pending = false
	command_context.clear()
	_clear_enhanced_global_triggers()
	var loaded_state := ClassicRuntimeState.new()
	loaded_state.configure_from_bundle(campaign_bundle)
	runtime.use_shared_campaign(campaign_bundle, loaded_state)
	_create_command_router()
	_configure_extensions()
	_configure_adapter()


func _configure_adapter() -> void:
	if command_adapter != null and command_adapter.has_method("configure_classic_bundle"):
		command_adapter.call("configure_classic_bundle", runtime.bundle)


func _configure_extensions(invoke_lifecycle := true) -> bool:
	if command_router == null:
		return false
	var extension_registry := runtime.bundle.extension_registry
	if extension_registry != null:
		if not extension_registry.register_command_ports(
			command_router,
			runtime.bundle.required_extension_ids()
		):
			push_error(extension_registry.last_error)
			return false
	if not _configure_engine_plugins():
		return false
	command_router.configure({
		"scenarioPortRuntime": command_adapter,
		"commandRouter": command_router,
		"gameplayRules": gameplay_rule_set,
		"extensionRegistry": extension_registry,
		"enginePluginRegistry": engine_plugin_registry,
		"behaviorRunner": self,
		"runtimeBindings": runtime.bundle.documents.get(
			"runtime",
			{}
		).get("bindings", {}),
	})
	rule_modifier_pipeline = ScenarioRuleModifierPipelineScript.new()
	rule_modifier_pipeline.configure(
		self,
		extension_registry,
		runtime.bundle.documents.get("runtime", {}).get("bindings", {})
	)
	if not _configure_enhanced_global_triggers():
		return false
	if invoke_lifecycle:
		_campaign_start_pending = true
		call_deferred("_run_campaign_loaded_behaviors")
	return true


func _configure_engine_plugins() -> bool:
	engine_plugin_registry = EnginePluginRegistryScript.new()
	if not engine_plugin_registry.load_installed_catalog():
		push_error(engine_plugin_registry.last_error)
		return false
	var runtime_document: Variant = runtime.bundle.documents.get("runtime", {})
	var requirements: Variant = (
		runtime_document.get("requiredPlugins", [])
		if runtime_document is Dictionary else []
	)
	if not engine_plugin_registry.activate_required(requirements):
		push_error(engine_plugin_registry.last_error)
		return false
	if engine_plugin_registry.command_ids().is_empty():
		return true
	var port := EnginePluginPortScript.new()
	port.bind_registry(engine_plugin_registry)
	if not command_router.register_port(port):
		push_error(command_router.last_error)
		return false
	return true


func _clear_enhanced_global_triggers() -> void:
	enhanced_event_triggers_by_id.clear()
	enhanced_scheduled_triggers_by_id.clear()
	enhanced_trigger_state = null
	_campaign_start_pending = false


func _configure_enhanced_global_triggers() -> bool:
	enhanced_event_triggers_by_id.clear()
	enhanced_scheduled_triggers_by_id.clear()
	enhanced_trigger_state = null
	if runtime == null \
			or runtime.bundle == null \
			or str(runtime.bundle.manifest.get("campaignKind", "")) != "classic-enhanced":
		return true
	var logic: Variant = runtime.bundle.documents.get("remakeLogic", {})
	if not (logic is Dictionary) \
			or str(logic.get("kind", "")) != "classic-enhanced":
		push_error("Classic Enhanced campaign has no compatible scenario logic")
		return false
	if runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		push_error("Classic Enhanced global triggers require the scenario interpreter")
		return false
	var trigger_ids: Dictionary = {}
	for trigger_value: Variant in logic.get("eventTriggers", []):
		if not (trigger_value is Dictionary):
			push_error("Classic Enhanced Event Trigger must be an object")
			return false
		var trigger: Dictionary = trigger_value.duplicate(true)
		var trigger_id := str(trigger.get("id", ""))
		var event_name := _normalize_enhanced_event_name(
			str(trigger.get("event", ""))
		)
		if trigger_id.is_empty() or trigger_ids.has(trigger_id):
			push_error("Classic Enhanced global trigger IDs must be unique")
			return false
		if event_name.is_empty():
			push_error("Classic Enhanced Event Trigger '%s' has an invalid event" % trigger_id)
			return false
		if not _enhanced_behavior_available(str(trigger.get("behaviorId", ""))):
			push_error("Classic Enhanced Event Trigger '%s' has no behavior" % trigger_id)
			return false
		if not _enhanced_condition_available(trigger.get("conditionBehaviorId")):
			push_error("Classic Enhanced Event Trigger '%s' has an invalid condition" % trigger_id)
			return false
		trigger_ids[trigger_id] = true
		trigger["event"] = event_name
		enhanced_event_triggers_by_id[trigger_id] = trigger
	for trigger_value: Variant in logic.get("scheduledTriggers", []):
		if not (trigger_value is Dictionary):
			push_error("Classic Enhanced Scheduled Trigger must be an object")
			return false
		var trigger: Dictionary = trigger_value.duplicate(true)
		var trigger_id := str(trigger.get("id", ""))
		if trigger_id.is_empty() or trigger_ids.has(trigger_id):
			push_error("Classic Enhanced global trigger IDs must be unique")
			return false
		if not _validate_enhanced_schedule(trigger.get("schedule", {})):
			push_error("Classic Enhanced Scheduled Trigger '%s' has an invalid schedule" % trigger_id)
			return false
		if not _enhanced_behavior_available(str(trigger.get("behaviorId", ""))):
			push_error("Classic Enhanced Scheduled Trigger '%s' has no behavior" % trigger_id)
			return false
		if not _enhanced_condition_available(trigger.get("conditionBehaviorId")):
			push_error("Classic Enhanced Scheduled Trigger '%s' has an invalid condition" % trigger_id)
			return false
		trigger_ids[trigger_id] = true
		enhanced_scheduled_triggers_by_id[trigger_id] = trigger
	enhanced_trigger_state = SemanticStateScript.new()
	enhanced_trigger_state.configure(runtime.bundle.package_hash())
	return true


func _enhanced_behavior_available(behavior_id: String) -> bool:
	return not behavior_id.is_empty() \
		and runtime.interpreter.scenario_script_runtime.scripts_by_id.has(behavior_id)


func _enhanced_condition_available(value: Variant) -> bool:
	var behavior_id := str(value) if value != null else ""
	return behavior_id.is_empty() or (
		_enhanced_behavior_available(behavior_id)
		and runtime.interpreter.scenario_script_runtime.behavior_hook_is_pure(
			behavior_id
		)
	)


func has_event_trigger(trigger_id: String) -> bool:
	return enhanced_event_triggers_by_id.has(trigger_id)


func has_scheduled_trigger(trigger_id: String) -> bool:
	return enhanced_scheduled_triggers_by_id.has(trigger_id)


func run_event(event_name: String, context := {}) -> Dictionary:
	return await run_enhanced_event_triggers(event_name, context)


func run_scheduled(clock: Dictionary, context := {}) -> Dictionary:
	return await run_enhanced_scheduled_triggers(clock, context)


func run_enhanced_event_triggers(
	event_name: String,
	context := {}
) -> Dictionary:
	if enhanced_trigger_state == null:
		return {"status": "ok", "handled": false}
	var normalized_event := _normalize_enhanced_event_name(event_name)
	if normalized_event.is_empty():
		return {
			"status": "error",
			"message": "Classic Enhanced event '%s' is unsupported" % event_name,
		}
	var event_context: Dictionary = (
		context.duplicate(true) if context is Dictionary else {}
	)
	event_context["event"] = normalized_event
	var only_trigger_id := str(event_context.get("onlyTriggerId", ""))
	var candidates: Array = []
	for trigger_value: Variant in enhanced_event_triggers_by_id.values():
		var trigger: Dictionary = trigger_value
		if bool(trigger.get("enabled", true)) \
				and str(trigger.get("event", "")) == normalized_event \
				and (
					only_trigger_id.is_empty()
					or str(trigger.get("id", "")) == only_trigger_id
				):
			candidates.append({
				"kind": "event",
				"trigger": trigger.duplicate(true),
				"marker": -1,
			})
	var scheduled_clock: Variant = event_context.get("scheduledClock")
	if normalized_event == "time" and scheduled_clock is Dictionary:
		candidates.append_array(_enhanced_scheduled_candidates(
			scheduled_clock,
			event_context
		))
	return await _run_enhanced_trigger_candidates(
		candidates,
		event_context
	)


func run_enhanced_scheduled_triggers(
	clock: Dictionary,
	context := {}
) -> Dictionary:
	if enhanced_trigger_state == null:
		return {"status": "ok", "handled": false}
	if not _validate_enhanced_clock(clock):
		return {"status": "error", "message": "Scheduled Trigger clock is invalid"}
	var schedule_context: Dictionary = (
		context.duplicate(true) if context is Dictionary else {}
	)
	schedule_context["clock"] = clock.duplicate(true)
	return await _run_enhanced_trigger_candidates(
		_enhanced_scheduled_candidates(clock, schedule_context),
		schedule_context
	)


func _enhanced_scheduled_candidates(
	clock: Dictionary,
	context: Dictionary
) -> Array:
	var only_trigger_id := str(context.get("onlyTriggerId", ""))
	var candidates: Array = []
	for trigger_value: Variant in enhanced_scheduled_triggers_by_id.values():
		var trigger: Dictionary = trigger_value
		if not bool(trigger.get("enabled", true)) \
				or (
					not only_trigger_id.is_empty()
					and str(trigger.get("id", "")) != only_trigger_id
				) \
				or not _enhanced_schedule_location_matches(
					trigger.get("location"),
					context
				):
			continue
		var marker := enhanced_trigger_state.scheduled_due_marker(trigger, clock)
		if marker >= 0:
			candidates.append({
				"kind": "scheduled",
				"trigger": trigger.duplicate(true),
				"marker": marker,
			})
	return candidates


func _run_enhanced_trigger_candidates(
	candidates: Array,
	context: Dictionary
) -> Dictionary:
	if candidates.is_empty():
		return {"status": "ok", "handled": false}
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_trigger: Dictionary = left.get("trigger", {})
		var right_trigger: Dictionary = right.get("trigger", {})
		var left_priority := int(left_trigger.get("priority", 0))
		var right_priority := int(right_trigger.get("priority", 0))
		if left_priority != right_priority:
			return left_priority < right_priority
		return str(left_trigger.get("id", "")) < str(right_trigger.get("id", ""))
	)
	var previous_markers := enhanced_trigger_state.scheduled_markers.duplicate(true)
	var actions: Array = []
	for candidate_value: Variant in candidates:
		var candidate: Dictionary = candidate_value
		var kind := str(candidate.get("kind", "event"))
		var trigger: Dictionary = candidate.get("trigger", {})
		var trigger_id := str(trigger.get("id", ""))
		var invocation_context := context.duplicate(true)
		invocation_context["trigger"] = trigger.duplicate(true)
		invocation_context["triggerKind"] = kind
		var condition_value = trigger.get("conditionBehaviorId")
		var condition_id := str(condition_value) if condition_value != null else ""
		if not condition_id.is_empty():
			var condition_result := run_bound_behavior_pure(
				condition_id,
				{},
				{
					"role": "helper",
					"hook": "",
					"request": invocation_context,
				}
			)
			if str(condition_result.get("status", "")) == "error":
				enhanced_trigger_state.scheduled_markers = previous_markers
				return condition_result
			if not bool(condition_result.get("value", false)):
				continue
		var marker := int(candidate.get("marker", -1))
		if marker >= 0:
			enhanced_trigger_state.mark_scheduled_trigger(trigger_id, marker)
		actions.append({
			"kind": "semantic",
			"slot": actions.size(),
			"operation": "core.script.call",
			"parameters": {
				"behaviorId": str(trigger.get("behaviorId", "")),
				"arguments": {},
				"attachment": {
					"role": "action",
					"hook": "run",
					"request": invocation_context,
				},
			},
		})
	if actions.is_empty():
		return {"status": "ok", "handled": false}
	runtime.runtime_state.set_action_point_override(
		ENHANCED_DISPATCH_TRIGGER_ID,
		{
			"id": ENHANCED_DISPATCH_TRIGGER_ID,
			"active": true,
			"percent": 100,
			"actions": actions,
		}
	)
	var result: Dictionary = await run_trigger(
		ENHANCED_DISPATCH_TRIGGER_ID,
		0,
		{
			"source": "classic-enhanced-global-trigger",
			"eventContext": context.duplicate(true),
		}
	)
	if str(result.get("status", "")) == "error":
		enhanced_trigger_state.scheduled_markers = previous_markers
		return result
	return {
		"status": "ok",
		"handled": true,
		"result": result,
	}


func _validate_enhanced_schedule(value: Variant) -> bool:
	if not (value is Dictionary):
		return false
	match str(value.get("kind", "")):
		"absolute":
			return int(value.get("day", -1)) >= 1 \
				and int(value.get("minute", -1)) in range(0, 1440)
		"elapsed":
			return int(value.get("elapsedMinutes", -1)) >= 0
		"recurring":
			return int(value.get("intervalMinutes", 0)) > 0
	return false


func _validate_enhanced_clock(clock: Variant) -> bool:
	return clock is Dictionary \
		and int(clock.get("elapsedMinutes", -1)) >= 0 \
		and int(clock.get("day", -1)) >= 1 \
		and int(clock.get("minute", -1)) in range(0, 1440)


func _enhanced_schedule_location_matches(
	required_value: Variant,
	context: Dictionary
) -> bool:
	if required_value == null:
		return true
	if not (required_value is Dictionary):
		return false
	var required: Dictionary = required_value
	var current := _enhanced_current_location(context)
	if current.is_empty():
		return false
	var required_map_id := str(required.get("mapId", ""))
	var current_map_id := str(current.get(
		"mapId",
		"%s:%d" % [
			current.get("levelType", "land"),
			current.get("levelIndex", 0),
		]
	))
	if required_map_id != current_map_id:
		return false
	var x := int(current.get("x", 0))
	var y := int(current.get("y", 0))
	var left := int(required.get("x", 0))
	var top := int(required.get("y", 0))
	if str(required.get("kind", "point")) == "point":
		return x == left and y == top
	var width := maxi(1, int(required.get("width", 1)))
	var height := maxi(1, int(required.get("height", 1)))
	return x >= left and x < left + width and y >= top and y < top + height


func _enhanced_current_location(context: Dictionary) -> Dictionary:
	var location_value: Variant = context.get("location")
	if location_value is Dictionary:
		return location_value.duplicate(true)
	if context.has("levelType") and context.has("levelIndex"):
		return context.duplicate(true)
	if command_adapter != null \
			and command_adapter.has_method("get_classic_execution_context"):
		var adapter_context: Variant = command_adapter.call(
			"get_classic_execution_context"
		)
		if adapter_context is Dictionary:
			return adapter_context.duplicate(true)
	return {}


func _normalize_enhanced_event_name(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	var aliases := {
		"campaign-loaded": "campaign-start",
		"campaign-complete": "campaign-end",
		"party-moved": "movement",
		"rest-complete": "rest",
		"time-advanced": "time",
		"battle-complete": "battle-end",
		"character-defeated": "character-defeat",
		"party-defeated": "party-defeat",
	}
	normalized = str(aliases.get(normalized, normalized))
	return normalized if normalized in [
		"campaign-start",
		"campaign-end",
		"map-enter",
		"map-leave",
		"movement",
		"rest-start",
		"rest",
		"time",
		"battle-start",
		"battle-end",
		"character-defeat",
		"party-defeat",
		"spell",
		"item",
		"combat-round",
	] else ""


func snapshot_enhanced_trigger_state() -> Dictionary:
	return (
		enhanced_trigger_state.snapshot()
		if enhanced_trigger_state != null else {}
	)


func restore_enhanced_trigger_state(value: Variant) -> Dictionary:
	if enhanced_trigger_state == null:
		return (
			{"status": "ok"}
			if value is Dictionary and value.is_empty()
			else {
				"status": "error",
				"message": "Save contains unavailable Classic Enhanced trigger state",
			}
		)
	return enhanced_trigger_state.restore(value)


func cancel_pending_campaign_start() -> void:
	_campaign_start_pending = false


func run_bound_behavior(
	behavior_id: String,
	arguments: Dictionary,
	context := {}
) -> Dictionary:
	if runtime == null or runtime.interpreter == null:
		return {"status": "error", "message": "Scenario interpreter is unavailable"}
	_bound_behavior_depth += 1
	_bound_behavior_active = true
	var step: ScenarioStepResult = runtime.interpreter.execute_nested_scenario_script(
		behavior_id,
		arguments,
		context
	)
	for _iteration: int in range(4096):
		if step == null or not step.is_valid():
			return _complete_bound_behavior({
				"status": "error",
				"message": "Scenario behavior returned an invalid step",
			})
		match step.kind:
			ScenarioStepResult.CONTINUE, ScenarioStepResult.RETURN:
				return _complete_bound_behavior({
					"status": "ok",
					"value": step.data.get("value"),
				})
			ScenarioStepResult.HALT:
				return _complete_bound_behavior({
					"status": "ok",
					"halted": true,
					"value": step.data.get("value"),
				})
			ScenarioStepResult.ERROR:
				return _complete_bound_behavior({
					"status": "error",
					"message": step.data.get("message", "Scenario behavior failed"),
				})
			ScenarioStepResult.YIELD:
				var command_id := str(step.data.get("commandId", ""))
				var request: Variant = step.data.get("request", {})
				if command_router == null or not (request is Dictionary):
					return _complete_bound_behavior({
						"status": "error",
						"message": "Scenario behavior yielded an invalid command",
					})
				command_started.emit(command_id, request)
				var response: Dictionary = await command_router.route(
					command_id,
					request
				)
				command_finished.emit(command_id, response)
				if str(response.get("status", "")) == "error":
					return _complete_bound_behavior(response)
				step = runtime.interpreter.resume_scenario_script(response)
			_:
				return _complete_bound_behavior({
					"status": "error",
					"message": "Scenario provider behavior cannot return '%s'"
						% step.kind,
				})
	return _complete_bound_behavior({
		"status": "error",
		"message": "Scenario behavior exceeded its routed command limit",
	})


func run_bound_behavior_pure(
	behavior_id: String,
	arguments: Dictionary,
	context := {}
) -> Dictionary:
	if runtime == null or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {"status": "error", "message": "Scenario interpreter is unavailable"}
	if not runtime.interpreter.scenario_script_runtime.behavior_hook_is_pure(
		behavior_id
	):
		return {
			"status": "error",
			"message": "Scenario behavior '%s' is not a pure hook" % behavior_id,
		}
	_bound_behavior_depth += 1
	_bound_behavior_active = true
	var step: ScenarioStepResult = runtime.interpreter.execute_nested_scenario_script(
		behavior_id,
		arguments,
		context
	)
	for _iteration: int in range(4096):
		if step == null or not step.is_valid():
			return _complete_bound_behavior({
				"status": "error",
				"message": "Pure scenario behavior returned an invalid step",
			})
		match step.kind:
			ScenarioStepResult.CONTINUE, ScenarioStepResult.RETURN:
				return _complete_bound_behavior({
					"status": "ok",
					"value": step.data.get("value"),
				})
			ScenarioStepResult.HALT:
				return _complete_bound_behavior({
					"status": "ok",
					"halted": true,
					"value": step.data.get("value"),
				})
			ScenarioStepResult.ERROR:
				return _complete_bound_behavior({
					"status": "error",
					"message": step.data.get(
						"message",
						"Pure scenario behavior failed"
					),
				})
			ScenarioStepResult.YIELD:
				return _complete_bound_behavior({
					"status": "error",
					"message": (
						"Pure scenario behavior '%s' attempted to yield"
						% behavior_id
					),
				})
			_:
				return _complete_bound_behavior({
					"status": "error",
					"message": "Pure scenario behavior cannot return '%s'"
						% step.kind,
				})
	return _complete_bound_behavior({
		"status": "error",
		"message": "Pure scenario behavior exceeded its execution limit",
	})


func _complete_bound_behavior(result: Dictionary) -> Dictionary:
	var restore_result := runtime.interpreter.complete_nested_scenario_script() \
		if runtime != null and runtime.interpreter != null \
		else {"status": "ok"}
	_bound_behavior_depth = maxi(0, _bound_behavior_depth - 1)
	_bound_behavior_active = _bound_behavior_depth > 0
	if str(restore_result.get("status", "")) == "error":
		result = restore_result
	if runtime != null \
			and runtime.interpreter != null \
			and runtime.interpreter.scenario_script_runtime != null \
			and not _bound_behavior_active \
			and not runtime.interpreter.scenario_script_runtime.event_queue.is_empty():
		call_deferred("_drain_script_event_queue")
	return result


func _queue_script_event(kind: String, hook: String, request: Dictionary) -> Dictionary:
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {"status": "error", "message": "Scenario event queue is unavailable"}
	var queue: Array = runtime.interpreter.scenario_script_runtime.event_queue
	if queue.size() >= 256:
		return {"status": "error", "message": "Scenario event queue limit exceeded"}
	queue.append({
		"kind": kind,
		"hook": hook,
		"request": request.duplicate(true),
	})
	return {"status": "ok", "queued": true}


func _drain_script_event_queue() -> void:
	if _script_event_queue_draining or _bound_behavior_active \
			or runtime == null or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return
	_script_event_queue_draining = true
	var queue: Array = runtime.interpreter.scenario_script_runtime.event_queue
	while not queue.is_empty() and not _bound_behavior_active:
		var event_value: Variant = queue.pop_front()
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value
		var result := {"status": "ok"}
		if str(event.get("kind", "")) == "lifecycle":
			result = await emit_lifecycle_event(
				str(event.get("hook", "")),
				event.get("request", {})
			)
		elif str(event.get("kind", "")) == "spell-effects":
			result = await process_spell_effect_event(
				str(event.get("hook", "")),
				event.get("request", {})
			)
		elif str(event.get("kind", "")) == "enhanced-global":
			result = await _dispatch_enhanced_lifecycle_triggers(
				str(event.get("hook", "")),
				event.get("request", {})
			)
		if str(result.get("status", "")) == "error":
			push_error(str(result.get(
				"message",
				"Queued scenario event failed"
			)))
	_script_event_queue_draining = false


func run_behavior_attachments(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	request: Dictionary
) -> Dictionary:
	if runtime == null or runtime.interpreter == null:
		return {"handled": false}
	var binding_anchor: Dictionary = request.get(
		"anchor",
		{"kind": "domain"}
	)
	var bindings: Array = runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		binding_anchor
	)
	if bindings.is_empty():
		return {"handled": false}
	var results: Array = []
	for binding_value: Variant in bindings:
		var binding: Dictionary = binding_value
		var context := {
			"role": role,
			"hook": hook,
			"targetKind": target_kind,
			"targetId": str(binding.get("recordId", "")),
			"request": request.duplicate(true),
		}
		var arguments_result: Dictionary = (
			runtime.interpreter.resolve_scenario_behavior_arguments(
				binding.get("arguments", {}),
				context
			)
		)
		if str(arguments_result.get("status", "")) != "ok":
			return arguments_result
		var result: Dictionary = await run_bound_behavior(
			str(binding.get("behaviorId", "")),
			arguments_result.get("arguments", {}),
			context
		)
		if str(result.get("status", "")) == "error":
			return result
		results.append(result)
	return {"status": "ok", "handled": true, "results": results}


func run_behavior_binding(
	behavior_id: String,
	role: String,
	hook: String,
	target_kind: String,
	target_id: String,
	slot: int,
	request: Dictionary
) -> Dictionary:
	if runtime == null or runtime.interpreter == null:
		return {
			"status": "error",
			"message": "Scenario behavior runtime is unavailable",
		}
	var binding_anchor: Dictionary = request.get(
		"anchor",
		{"kind": "domain"}
	)
	var bindings: Array = runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		[target_id],
		binding_anchor
	)
	if bindings.is_empty() and slot >= 0:
		# Preview entries from older clients carry only a slot. Select the named
		# binding after checking its target contract; placement remains package data.
		for binding_value: Variant in runtime.interpreter.scenario_script_runtime.behavior_bindings:
			if binding_value is Dictionary \
					and str(binding_value.get("behaviorId", "")) == behavior_id \
					and str(binding_value.get("role", "")) == role \
					and str(binding_value.get("hook", "")) == hook \
					and str(binding_value.get("targetKind", "")) == target_kind \
					and str(binding_value.get("recordId", "")) == target_id:
				bindings.append(binding_value.duplicate(true))
	var selected_binding := {}
	for binding_value: Variant in bindings:
		if binding_value is Dictionary \
				and str(binding_value.get("behaviorId", "")) == behavior_id:
			selected_binding = binding_value
			break
	if selected_binding.is_empty():
		return {
			"status": "error",
			"message": (
				"Scenario behavior '%s' is not attached to %s '%s' at %s/%s"
				% [behavior_id, target_kind, target_id, role, hook]
			),
		}
	var context := {
		"role": role,
		"hook": hook,
		"targetKind": target_kind,
		"targetId": target_id,
		"request": request.duplicate(true),
	}
	var arguments_result: Dictionary = (
		runtime.interpreter.resolve_scenario_behavior_arguments(
			selected_binding.get("arguments", {}),
			context
		)
	)
	if str(arguments_result.get("status", "")) != "ok":
		return arguments_result
	return await run_bound_behavior(
		behavior_id,
		arguments_result.get("arguments", {}),
		context
	)


func run_behavior_attachments_pure(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	request: Dictionary
) -> Dictionary:
	if runtime == null or runtime.interpreter == null:
		return {"handled": false}
	var binding_anchor: Dictionary = request.get(
		"anchor",
		{"kind": "domain"}
	)
	var bindings: Array = runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		binding_anchor
	)
	if bindings.is_empty():
		return {"handled": false}
	var results: Array = []
	for binding_value: Variant in bindings:
		var binding: Dictionary = binding_value
		var context := {
			"role": role,
			"hook": hook,
			"targetKind": target_kind,
			"targetId": str(binding.get("recordId", "")),
			"request": request.duplicate(true),
		}
		var arguments_result: Dictionary = (
			runtime.interpreter.resolve_scenario_behavior_arguments(
				binding.get("arguments", {}),
				context
			)
		)
		if str(arguments_result.get("status", "")) != "ok":
			return arguments_result
		var result: Dictionary = run_bound_behavior_pure(
			str(binding.get("behaviorId", "")),
			arguments_result.get("arguments", {}),
			context
		)
		if str(result.get("status", "")) == "error":
			return result
		results.append(result)
	return {"status": "ok", "handled": true, "results": results}


func has_behavior_attachments(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	anchor := {"kind": "domain"}
) -> bool:
	if runtime == null or runtime.interpreter == null:
		return false
	return not runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		anchor
	).is_empty()


func has_item_behavior(instance: Object, hook_kind: String) -> bool:
	if command_router == null:
		return false
	var port: Variant = command_router.port_for_command("query_party_wealth")
	return (
		port != null
		and port.has_method("has_item_behavior")
		and bool(port.call("has_item_behavior", instance, hook_kind))
	)


func run_item_behavior(
	instance: Object,
	hook_kind: String,
	user: Object = null,
	target: Object = null
) -> Dictionary:
	if command_router == null:
		return {"handled": false}
	var port: Variant = command_router.port_for_command("query_party_wealth")
	if port == null or not port.has_method("run_item_behavior"):
		return {"handled": false}
	return await port.call(
		"run_item_behavior",
		instance,
		hook_kind,
		user,
		target
	)


func run_item_behavior_pure(
	instance: Object,
	hook_kind: String,
	user: Object = null,
	target: Object = null,
	details := {}
) -> Dictionary:
	if command_router == null:
		return {"handled": false}
	var port: Variant = command_router.port_for_command("query_party_wealth")
	if port == null or not port.has_method("run_item_behavior_pure"):
		return {"handled": false}
	return port.call(
		"run_item_behavior_pure",
		instance,
		hook_kind,
		user,
		target,
		details
	)


func item_behavior_allows(
	instance: Object,
	hook_kind: String,
	user: Object = null,
	target: Object = null,
	details := {}
) -> Dictionary:
	var result := run_item_behavior_pure(
		instance,
		hook_kind,
		user,
		target,
		details
	)
	if str(result.get("status", "")) == "error":
		return result
	for outcome_value: Variant in result.get("outcomes", []):
		if outcome_value is Dictionary \
				and str(outcome_value.get("kind", "")) == "rejected":
			return {
				"status": "ok",
				"handled": true,
				"allowed": false,
			}
	return {
		"status": "ok",
		"handled": bool(result.get("handled", false)),
		"allowed": true,
	}


func resolve_item_behavior_modifier(
	instance: Object,
	hook_kind: String,
	user: Object,
	target: Object,
	base_value: float,
	details := {}
) -> Dictionary:
	var request_details: Dictionary = (
		details.duplicate(true) if details is Dictionary else {}
	)
	request_details["baseValue"] = base_value
	var result := run_item_behavior_pure(
		instance,
		hook_kind,
		user,
		target,
		request_details
	)
	if str(result.get("status", "")) == "error":
		return result
	var current := base_value
	for outcome_value: Variant in result.get("outcomes", []):
		if not (outcome_value is Dictionary):
			return {
				"status": "error",
				"message": "Scenario item behavior returned an invalid outcome",
			}
		var outcome: Dictionary = outcome_value
		if str(outcome.get("kind", "")) == "rejected":
			return {
				"status": "ok",
				"handled": true,
				"allowed": false,
				"value": current,
			}
		current = (
			(current + float(outcome.get("add", 0.0)))
			* float(outcome.get("multiply", 1.0))
		)
		if outcome.has("minimum"):
			current = maxf(current, float(outcome["minimum"]))
		if outcome.has("maximum"):
			current = minf(current, float(outcome["maximum"]))
		if not is_finite(current):
			return {
				"status": "error",
				"message": "Scenario item behavior produced a non-finite value",
			}
	return {
		"status": "ok",
		"handled": bool(result.get("handled", false)),
		"allowed": true,
		"value": current,
	}


func has_spell_behavior(spell: Object) -> bool:
	if command_router == null:
		return false
	var port: Variant = command_router.port_for_command("query_party_members")
	return (
		port != null
		and port.has_method("has_spell_behavior")
		and bool(port.call("has_spell_behavior", spell))
	)


func run_spell_behavior(
	spell: Object,
	caster: Object,
	targets: Array,
	power: int,
	cast_context := {}
) -> Dictionary:
	if command_router == null:
		return {"handled": false}
	var port: Variant = command_router.port_for_command("query_party_members")
	if port == null or not port.has_method("run_spell_behavior"):
		return {"handled": false}
	return await port.call(
		"run_spell_behavior",
		spell,
		caster,
		targets,
		power,
		cast_context
	)


func run_spell_behavior_hook(
	spell: Object,
	hook: String,
	caster: Object,
	targets: Array,
	power: int,
	cast_context := {}
) -> Dictionary:
	if command_router == null:
		return {"handled": false}
	var port: Variant = command_router.port_for_command("query_party_members")
	if port == null or not port.has_method("run_spell_behavior_hook"):
		return {"handled": false}
	return await port.call(
		"run_spell_behavior_hook",
		spell,
		hook,
		caster,
		targets,
		power,
		cast_context
	)


func register_spell_behavior_effect(
	target_ids: Array,
	request: Dictionary,
	outcome: Dictionary
) -> Dictionary:
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {
			"status": "error",
			"message": "Scenario spell-effect runtime is unavailable",
		}
	return runtime.interpreter.scenario_script_runtime.register_spell_effect(
		target_ids,
		request,
		outcome
	)


func complete_campaign(request := {}) -> Dictionary:
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {
			"status": "error",
			"message": "Scenario campaign-completion runtime is unavailable",
		}
	var script_runtime: ScenarioScriptRuntime = (
		runtime.interpreter.scenario_script_runtime
	)
	if not script_runtime.campaign_completion.is_empty():
		return {
			"status": "ok",
			"completed": true,
			"alreadyCompleted": true,
		}
	if _campaign_completion_active:
		return {
			"status": "error",
			"message": "Scenario campaign completion is already being dispatched",
		}
	_campaign_completion_active = true
	var completion_request: Dictionary = (
		request.duplicate(true) if request is Dictionary else {}
	)
	completion_request["event"] = "campaign-complete"
	var marked := script_runtime.mark_campaign_complete(completion_request)
	if str(marked.get("status", "")) == "error":
		_campaign_completion_active = false
		return marked
	var lifecycle_result := await emit_lifecycle_event(
		"campaign-complete",
		completion_request
	)
	_campaign_completion_active = false
	if str(lifecycle_result.get("status", "")) == "error":
		return lifecycle_result
	return {
		"status": "ok",
		"completed": true,
		"alreadyCompleted": false,
		"lifecycle": lifecycle_result,
	}


func process_spell_effect_event(
	event_kind: String,
	event := {}
) -> Dictionary:
	var event_request: Dictionary = (
		event.duplicate(true) if event is Dictionary else {}
	)
	if _bound_behavior_active:
		return _queue_script_event(
			"spell-effects",
			event_kind,
			event_request
		)
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {"status": "ok", "handled": false, "deliveries": 0}
	var advanced: Dictionary = (
		runtime.interpreter.scenario_script_runtime.advance_spell_effects(
			event_kind,
			event_request
		)
	)
	if str(advanced.get("status", "")) == "error":
		return advanced
	return await _dispatch_spell_effect_deliveries(
		advanced.get("deliveries", [])
	)


func expire_spell_effect_intervals(intervals: Array) -> Dictionary:
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {"status": "ok", "handled": false, "deliveries": 0}
	var expired: Dictionary = (
		runtime.interpreter.scenario_script_runtime.expire_spell_effects(
			intervals
		)
	)
	if str(expired.get("status", "")) == "error":
		return expired
	return await _dispatch_spell_effect_deliveries(
		expired.get("deliveries", [])
	)


func _dispatch_spell_effect_deliveries(deliveries: Array) -> Dictionary:
	if command_router == null:
		return {
			"status": "error",
			"message": "Scenario spell-effect command router is unavailable",
		}
	var port: Variant = command_router.port_for_command("query_party_members")
	if port == null or not port.has_method("run_stored_spell_behavior_hook"):
		return {
			"status": "error",
			"message": "Scenario spell-effect port is unavailable",
		}
	var handled := false
	var delivered := 0
	for delivery_value: Variant in deliveries:
		if not (delivery_value is Dictionary):
			return {
				"status": "error",
				"message": "Scenario spell-effect delivery is malformed",
			}
		var delivery: Dictionary = delivery_value
		var result: Dictionary = await port.call(
			"run_stored_spell_behavior_hook",
			delivery.get("effect", {}),
			str(delivery.get("hook", "")),
			delivery.get("event", {})
		)
		if str(result.get("status", "")) == "error":
			return result
		handled = handled or bool(result.get("handled", false))
		delivered += 1
	return {
		"status": "ok",
		"handled": handled,
		"deliveries": delivered,
	}


func has_monster_ai_behavior(monster: Object) -> bool:
	if command_router == null:
		return false
	var port: Variant = command_router.port_for_command("query_combat")
	return (
		port != null
		and port.has_method("has_monster_ai_behavior")
		and bool(port.call("has_monster_ai_behavior", monster))
	)


func run_monster_ai_behavior(monster: Object) -> Dictionary:
	if command_router == null:
		return {"handled": false}
	var port: Variant = command_router.port_for_command("query_combat")
	if port == null or not port.has_method("run_monster_ai_behavior"):
		return {"handled": false}
	return await port.call("run_monster_ai_behavior", monster)


func resolve_rule_modifiers(
	event_id: String,
	base_value: float,
	context := {}
) -> Dictionary:
	if rule_modifier_pipeline == null:
		return {"status": "ok", "value": base_value, "applied": []}
	return rule_modifier_pipeline.resolve(event_id, base_value, context)


func resume_scenario_debugger(action: String) -> Dictionary:
	if runtime == null \
			or runtime.interpreter == null \
			or runtime.interpreter.scenario_script_runtime == null:
		return {
			"status": "error",
			"message": "Scenario debugger runtime is unavailable",
		}
	var runtime_result: Dictionary = (
		runtime.interpreter.scenario_script_runtime.debugger_resume(action)
	)
	if str(runtime_result.get("status", "")) != "ok":
		return runtime_result
	if command_router == null:
		return {
			"status": "error",
			"message": "Scenario debugger command router is unavailable",
		}
	var presentation_port: Variant = command_router.port_for_command(
		"scenario_debug_pause"
	)
	if presentation_port == null \
			or not presentation_port.has_method("resume_debugger"):
		return {
			"status": "error",
			"message": "Scenario debugger presentation port is unavailable",
		}
	return presentation_port.resume_debugger(action)


func _run_campaign_loaded_behaviors() -> void:
	if not _campaign_start_pending:
		return
	_campaign_start_pending = false
	var request := {
		"event": "campaign-loaded",
		"campaignId": str(runtime.bundle.manifest.get("id", "")),
	}
	var lifecycle_result := await emit_lifecycle_event(
		"campaign-start",
		request
	)
	if str(lifecycle_result.get("status", "")) == "error":
		push_error(str(lifecycle_result.get(
			"message",
			"Scenario campaign-start behavior failed"
		)))


func emit_lifecycle_event(hook: String, request := {}) -> Dictionary:
	if runtime == null or runtime.bundle == null:
		return {"status": "error", "message": "Scenario lifecycle runtime is unavailable"}
	var event_request: Dictionary = (
		request.duplicate(true) if request is Dictionary else {}
	)
	if _bound_behavior_active:
		return _queue_script_event("lifecycle", hook, event_request)
	var spell_effect_result := {"status": "ok", "handled": false}
	match hook:
		"time-advanced":
			spell_effect_result = await process_spell_effect_event(
				"time",
				event_request
			)
		"party-moved":
			spell_effect_result = await process_spell_effect_event(
				"move",
				event_request
			)
		"battle-complete":
			spell_effect_result = await expire_spell_effect_intervals(["round"])
	if str(spell_effect_result.get("status", "")) == "error":
		return spell_effect_result
	event_request["hook"] = hook
	event_request["campaignId"] = str(runtime.bundle.manifest.get("id", ""))
	var battle_attachment_result := {"status": "ok", "handled": false}
	var battle_id := int(event_request.get("battleId", -1))
	if hook in ["battle-start", "battle-complete"] and battle_id >= 0:
		battle_attachment_result = await run_behavior_attachments(
			"lifecycle",
			hook,
			"battle",
			[str(battle_id)],
			event_request
		)
		if str(battle_attachment_result.get("status", "")) == "error":
			return battle_attachment_result
	var attachment_result: Dictionary = await run_behavior_attachments(
		"lifecycle",
		hook,
		"lifecycle",
		["campaign"],
		event_request
	)
	if str(attachment_result.get("status", "")) == "error":
		return attachment_result
	var enhanced_result := await _dispatch_or_queue_enhanced_lifecycle_triggers(
		hook,
		event_request
	)
	if str(enhanced_result.get("status", "")) == "error":
		return enhanced_result
	var lifecycle_bindings: Variant = runtime.bundle.documents.get(
		"runtime",
		{}
	).get("bindings", {}).get("lifecycle", {})
	if not (lifecycle_bindings is Dictionary):
		return {
			"status": "ok",
			"handled": (
				bool(attachment_result.get("handled", false))
				or bool(battle_attachment_result.get("handled", false))
				or bool(spell_effect_result.get("handled", false))
				or bool(enhanced_result.get("handled", false))
			),
		}
	var candidate_keys: Array = [hook, str(event_request.get("event", ""))]
	for binding_key: Variant in candidate_keys:
		if str(binding_key).is_empty() or not lifecycle_bindings.has(binding_key):
			continue
		var binding_value: Variant = lifecycle_bindings[binding_key]
		if not (binding_value is Dictionary):
			continue
		var binding: Dictionary = binding_value
		var provider_request := event_request.duplicate(true)
		provider_request["bindingKey"] = str(binding_key)
		var provider_result: Dictionary
		if str(binding.get("kind", "")) == "script":
			provider_result = await run_bound_behavior(
				str(binding.get("behaviorId", "")),
				provider_request,
				{"role": "lifecycle", "hook": hook}
			)
		elif runtime.bundle.extension_registry != null:
			provider_result = runtime.bundle.extension_registry.invoke_binding(
				"lifecycleHooks",
				str(binding.get("providerId", "")),
				provider_request,
				self
			)
		else:
			provider_result = {
				"status": "error",
				"message": "Scenario lifecycle extension registry is unavailable",
			}
		if str(provider_result.get("status", "")) == "error":
			return provider_result
	return {
		"status": "ok",
		"handled": (
			bool(attachment_result.get("handled", false))
			or bool(battle_attachment_result.get("handled", false))
			or bool(spell_effect_result.get("handled", false))
			or bool(enhanced_result.get("handled", false))
		),
	}


func _dispatch_or_queue_enhanced_lifecycle_triggers(
	hook: String,
	request: Dictionary
) -> Dictionary:
	if enhanced_trigger_state == null:
		return {"status": "ok", "handled": false}
	if active or _bound_behavior_active:
		return _queue_script_event("enhanced-global", hook, request)
	return await _dispatch_enhanced_lifecycle_triggers(hook, request)


func _dispatch_enhanced_lifecycle_triggers(
	hook: String,
	request: Dictionary
) -> Dictionary:
	var context := request.duplicate(true)
	if hook == "time-advanced":
		context["scheduledClock"] = _enhanced_clock_from_request(request)
	return await run_enhanced_event_triggers(hook, context)


func _enhanced_clock_from_request(request: Dictionary) -> Dictionary:
	var supplied: Variant = request.get("clock")
	if supplied is Dictionary and _validate_enhanced_clock(supplied):
		return supplied.duplicate(true)
	var current_time := maxi(0, int(request.get("currentTime", 0)))
	var elapsed_minutes := floori(float(current_time) / 60.0)
	return {
		"elapsedMinutes": elapsed_minutes,
		"day": floori(float(elapsed_minutes) / 1440.0) + 1,
		"minute": elapsed_minutes % 1440,
	}


func has_trigger(trigger_id: String) -> bool:
	return runtime.has_trigger(trigger_id)


func random_encounters_enabled() -> bool:
	return (
		runtime.runtime_state.random_encounters_enabled
		and bool(rule_option("mapTime", "randomRectangles", true))
	)


func rule_option(domain: String, option_id: String, fallback: Variant) -> Variant:
	if gameplay_rule_set == null:
		return fallback
	return gameplay_rule_set.options(domain).get(option_id, fallback)


func snapshot_port_state() -> Dictionary:
	return command_router.snapshot_state() if command_router != null else {}


func restore_port_state(state: Dictionary) -> Dictionary:
	if command_router == null:
		return _continuation_error("Scenario command router is unavailable")
	return command_router.restore_state(state)


func get_random_rectangle(
	level_type: String,
	level_index: int,
	rect_index: int
) -> Dictionary:
	var baseline := runtime.bundle.get_random_rectangle(
		level_type,
		level_index,
		rect_index
	)
	return runtime.runtime_state.get_random_rectangle(
		level_type,
		level_index,
		rect_index,
		baseline
	)


func consume_random_rectangle_door(
	level_type: String,
	level_index: int,
	rect_index: int,
	door_index: int
) -> Dictionary:
	if door_index < 0 or door_index >= 3:
		return {
			"status": "error",
			"message": "Classic random-door index must be between 0 and 2",
		}
	var rectangle := get_random_rectangle(level_type, level_index, rect_index)
	if rectangle.is_empty():
		return {
			"status": "error",
			"message": "Classic random rectangle %s:%d:%d is unavailable"
				% [level_type, level_index, rect_index],
		}
	var percentages: Variant = rectangle.get("randomDoorPercent", [])
	if not (percentages is Array) or door_index >= percentages.size():
		return {
			"status": "error",
			"message": "Classic random rectangle %s:%d:%d has malformed door percentages"
				% [level_type, level_index, rect_index],
		}
	var previous_percent := int(percentages[door_index])
	if previous_percent <= 0:
		return {
			"status": "ok",
			"consumed": false,
			"previousPercent": previous_percent,
			"rectangle": rectangle,
		}
	percentages[door_index] = 0
	rectangle["randomDoorPercent"] = percentages
	runtime.runtime_state.set_random_rectangle(
		level_type,
		level_index,
		rect_index,
		rectangle
	)
	return {
		"status": "ok",
		"consumed": true,
		"previousPercent": previous_percent,
		"rectangle": rectangle,
	}


func allies_suspended() -> bool:
	return runtime.runtime_state.allies_suspended


func spellcasting_blocked(player_character: bool) -> bool:
	return (
		runtime.runtime_state.player_spellcasting_blocked
		if player_character
		else runtime.runtime_state.monster_spellcasting_blocked
	)


func run_trigger(trigger_id: String, start_slot := 0, context := {}) -> Dictionary:
	if active:
		return {
			"status": "error",
			"message": "A Classic action point is already active",
		}
	if not start_trigger(trigger_id, start_slot, context):
		return runtime.last_result
	if not active:
		return runtime.last_result
	var result: Dictionary = await playthrough_finished
	return result


func run_nested_trigger(trigger_id: String, start_slot := 0, context := {}) -> Dictionary:
	if not active:
		return await run_trigger(trigger_id, start_slot, context)
	if nested_trigger_active:
		return {
			"status": "error",
			"message": "A nested Classic action point is already active",
		}
	nested_trigger_active = true
	# A map action point can remain suspended in start_battle while combat macros run.
	# Share its campaign state without replacing that interpreter's execution stack.
	var nested_host := ClassicRuntimeHost.new()
	add_child(nested_host)
	nested_host.configure(command_adapter, gameplay_rule_set)
	nested_host.runtime.use_shared_campaign(runtime.bundle, runtime.runtime_state)
	var result: Dictionary = await nested_host.run_trigger(trigger_id, start_slot, context)
	nested_host.queue_free()
	nested_trigger_active = false
	return result


func run_battle_round_macro(
	battle_data: Dictionary,
	combat_round: int,
	context := {}
) -> Dictionary:
	var raw_macro := int(battle_data.get("battleMacro", 0))
	if combat_round <= 1 or raw_macro >= 0:
		return {"handled": false}
	var trigger_id := "Data ED3:macro:%d" % abs(raw_macro)
	if not has_trigger(trigger_id):
		return {
			"handled": true,
			"triggerId": trigger_id,
			"result": {
				"status": "completed",
				"reason": "missing-battle-round-macro-noop",
				"message": (
					"Classic battle macro trigger '%s' is missing; "
					+ "using the deterministic no-op fallback"
				) % trigger_id,
			},
		}
	var execution_context: Dictionary = context.duplicate(true) if context is Dictionary else {}
	execution_context["combatRound"] = combat_round
	execution_context["battleMacro"] = raw_macro
	execution_context["queuedMacro"] = false
	return {
		"handled": true,
		"triggerId": trigger_id,
		"result": await run_nested_trigger(trigger_id, 0, execution_context),
	}


func run_queued_combat_macro(entry: Dictionary, combat_context := {}) -> Dictionary:
	var trigger_id := str(entry.get("triggerId", ""))
	if trigger_id.is_empty() or not has_trigger(trigger_id):
		return {
			"handled": true,
			"triggerId": trigger_id,
			"result": {
				"status": "error",
				"message": "Classic queued combat macro trigger '%s' is missing" % trigger_id,
			},
		}
	var execution_context: Dictionary = combat_context.duplicate(true) \
		if combat_context is Dictionary else {}
	var queued_context: Variant = entry.get("context", {})
	if queued_context is Dictionary:
		for context_key: Variant in queued_context:
			execution_context[context_key] = queued_context[context_key]
	execution_context["queuedMacro"] = true
	return {
		"handled": true,
		"triggerId": trigger_id,
		"result": await run_nested_trigger(trigger_id, 0, execution_context),
	}


func activate_start_location(force_reload := false) -> Dictionary:
	if command_adapter == null or not command_adapter.has_method("activate_classic_start"):
		return {
			"status": "error",
			"message": "ClassicRuntimeHost requires a start-location adapter",
		}
	var replay_result := reapply_map_state()
	if str(replay_result.get("status", "")) == "error":
		return replay_result
	var state := runtime.runtime_state
	var response: Variant = command_adapter.call("activate_classic_start", {
		"levelType": state.level_type,
		"levelIndex": state.level_index,
		"x": state.x,
		"y": state.y,
		"heading": state.heading,
		"multiView": state.multi_view,
		"viewType": state.view_type,
		"compassEnabled": state.compass_enabled,
		"recheckDestination": true,
		"forceReload": force_reload,
	})
	if response is Dictionary:
		response["persistentMapState"] = replay_result
		var reveal_result := reveal_dungeon_overhead(Vector2i(state.x, state.y))
		if str(reveal_result.get("status", "")) == "error":
			return reveal_result
		response["dungeonOverhead"] = reveal_result
		refresh_dungeon_view()
		return response
	return {}


func reapply_map_state() -> Dictionary:
	if command_adapter == null or not command_adapter.has_method("reapply_classic_map_state"):
		return {
			"status": "error",
			"message": "ClassicRuntimeHost requires a persistent map-state adapter",
		}
	var response: Variant = command_adapter.call(
		"reapply_classic_map_state",
		runtime.runtime_state
	)
	return response if response is Dictionary else {
		"status": "error",
		"message": "Classic map-state adapter returned an invalid response",
	}


func reveal_dungeon_overhead(position: Vector2i) -> Dictionary:
	var state: Object = runtime.runtime_state if runtime != null else null
	if state == null or str(state.get("level_type")) != "dungeon":
		return {"handled": false}
	if command_adapter == null \
			or not command_adapter.has_method("reveal_classic_dungeon_overhead"):
		return {
			"status": "error",
			"message": "ClassicRuntimeHost requires a dungeon-overhead adapter",
		}
	var response: Variant = command_adapter.call(
		"reveal_classic_dungeon_overhead",
		state,
		position
	)
	return response if response is Dictionary else {
		"status": "error",
		"message": "Classic dungeon-overhead adapter returned an invalid response",
	}


func get_dungeon_view_snapshot(radius: int = 6) -> Dictionary:
	if runtime == null or runtime.bundle == null or runtime.runtime_state == null:
		return {"status": "ok", "active": false}
	return ClassicDungeonViewModelScript.build_snapshot(
		runtime.bundle,
		runtime.runtime_state,
		radius
	)


func refresh_dungeon_view(radius: int = 6) -> Dictionary:
	var snapshot := get_dungeon_view_snapshot(radius)
	classic_dungeon_view_changed.emit(snapshot)
	return snapshot


func rotate_dungeon_heading(delta: int) -> Dictionary:
	var snapshot := get_dungeon_view_snapshot()
	if str(snapshot.get("status", "")) == "error":
		return snapshot
	if not bool(snapshot.get("active", false)):
		return {"status": "ok", "handled": false, "changed": false, "snapshot": snapshot}
	var state: Object = runtime.runtime_state
	var old_heading := ClassicDungeonViewModelScript.normalize_heading(
		int(state.get("heading"))
	)
	var new_heading := ClassicDungeonViewModelScript.rotated_heading(old_heading, delta)
	state.call("set_heading", new_heading)
	return {
		"status": "ok",
		"handled": true,
		"changed": new_heading != old_heading,
		"snapshot": refresh_dungeon_view(),
	}


func toggle_dungeon_view(allow_wizard_eye := false) -> Dictionary:
	var snapshot := get_dungeon_view_snapshot()
	if str(snapshot.get("status", "")) == "error":
		return snapshot
	if not bool(snapshot.get("active", false)):
		return {"status": "ok", "handled": false, "changed": false, "snapshot": snapshot}
	var state: Object = runtime.runtime_state
	if not bool(state.get("multi_view")) and not allow_wizard_eye:
		return {
			"status": "ok",
			"handled": true,
			"changed": false,
			"reason": "fixed-3d",
			"snapshot": snapshot,
		}
	var old_view_type := int(state.get("view_type"))
	var new_view_type := ClassicDungeonViewModelScript.VIEW_MAP \
		if old_view_type == ClassicDungeonViewModelScript.VIEW_3D \
		else ClassicDungeonViewModelScript.VIEW_3D
	state.set("view_type", new_view_type)
	return {
		"status": "ok",
		"handled": true,
		"changed": true,
		"snapshot": refresh_dungeon_view(),
	}


func resolve_dungeon_movement(from_position: Vector2i, to_position: Vector2i) -> Dictionary:
	if command_adapter == null \
			or not command_adapter.has_method("resolve_classic_dungeon_movement"):
		return {"handled": false}
	var response: Variant = command_adapter.call(
		"resolve_classic_dungeon_movement",
		runtime.runtime_state,
		from_position,
		to_position
	)
	return response if response is Dictionary else {
		"status": "error",
		"handled": true,
		"allowed": false,
		"message": "Classic dungeon movement adapter returned an invalid response",
	}


func resolve_map_movement(from_position: Vector2i, to_position: Vector2i) -> Dictionary:
	if (
		str(runtime.runtime_state.get("level_type")) == "land"
		and str(rule_option("mapTime", "edgeTransitions", "classic-adjacent")) == "blocked"
	):
		var map_record := runtime.bundle.get_map(
			"land:%d" % int(runtime.runtime_state.get("level_index"))
		)
		if map_record is Dictionary:
			var width := int(map_record.get("width", 0))
			var height := int(map_record.get("height", 0))
			if (
				to_position.x < 0
				or to_position.y < 0
				or to_position.x >= width
				or to_position.y >= height
			):
				return {
					"handled": true,
					"allowed": false,
					"blockedByGameplayRules": true,
				}
	if command_adapter == null \
			or not command_adapter.has_method("resolve_classic_map_movement"):
		return {"handled": false}
	var response: Variant = command_adapter.call(
		"resolve_classic_map_movement",
		runtime.runtime_state,
		from_position,
		to_position
	)
	return response if response is Dictionary else {
		"status": "error",
		"handled": true,
		"allowed": false,
		"message": "Classic map movement adapter returned an invalid response",
	}


func discover_map_secrets(
	position: Vector2i,
	force_detection := false
) -> Dictionary:
	if command_adapter == null \
			or not command_adapter.has_method("discover_classic_map_secrets"):
		return {"handled": false}
	var response: Variant = command_adapter.call(
		"discover_classic_map_secrets",
		runtime.runtime_state,
		position,
		force_detection
	)
	return response if response is Dictionary else {
		"status": "error",
		"handled": true,
		"message": "Classic secret-discovery adapter returned an invalid response",
	}


func play_map_sound(sound_id: int) -> Dictionary:
	if command_adapter == null or not command_adapter.has_method("play_classic_map_sound"):
		return {"handled": false}
	var response: Variant = command_adapter.call("play_classic_map_sound", sound_id)
	if not (response is Dictionary):
		return {
			"status": "error",
			"handled": true,
			"message": "Classic map-sound adapter returned an invalid response",
		}
	var result: Dictionary = response.duplicate()
	result["handled"] = true
	return result


func start_trigger(trigger_id: String, start_slot := 0, context := {}) -> bool:
	if command_router == null:
		_stop_with_error("ClassicRuntimeHost requires a scenario command router")
		return false
	if not (context is Dictionary):
		_stop_with_error("ClassicRuntimeHost command context must be a dictionary")
		return false
	command_context.clear()
	restored_continuation_pending = false
	if command_adapter.has_method("get_classic_execution_context"):
		var adapter_context: Variant = command_adapter.call("get_classic_execution_context")
		if adapter_context is Dictionary:
			command_context = adapter_context.duplicate(true)
	for context_key: Variant in context:
		command_context[context_key] = context[context_key]
	active = true
	if not runtime.activate_trigger(trigger_id, start_slot, command_context):
		active = false
		return false
	return true


func begin_manual_trigger(
	trigger_id: String,
	start_slot := 0,
	context := {}
) -> Dictionary:
	if active:
		return _continuation_error("A Classic action point is already active")
	manual_control_active = true
	if not start_trigger(trigger_id, start_slot, context):
		manual_control_active = false
		return runtime.last_result.duplicate(true)
	return _manual_runtime_result()


func resume_manual_command(response: Dictionary) -> Dictionary:
	if not manual_control_active or not active:
		return _continuation_error("No manually controlled Classic command is active")
	var pending := _manual_runtime_result()
	if str(pending.get("status", "")) != "yield":
		return pending
	var command := str(pending.get("commandId", ""))
	command_finished.emit(command, response)
	if str(response.get("status", "")) == "error":
		manual_control_active = false
		_stop_with_error(
			str(response.get("message", "Classic preview response failed")),
			command
		)
		return _continuation_error(
			str(response.get("message", "Classic preview response failed"))
		)
	_resume_after_command(command, pending.get("request", {}), response)
	return _manual_runtime_result()


func resume_manual_restored_continuation() -> Dictionary:
	if not restored_continuation_pending:
		return _continuation_error("No restored Classic command is waiting")
	restored_continuation_pending = false
	manual_control_active = true
	active = true
	return _manual_runtime_result()


func _manual_runtime_result() -> Dictionary:
	if runtime == null:
		return _continuation_error("Classic runtime is unavailable")
	var result := runtime.last_result.duplicate(true)
	if str(result.get("status", "")) != "yield":
		return result
	var request: Dictionary = (
		result.get("payload", {}).duplicate(true)
		if result.get("payload", {}) is Dictionary else {}
	)
	for context_key: Variant in command_context:
		if not request.has(context_key):
			request[context_key] = command_context[context_key]
	return {
		"status": "yield",
		"commandId": str(result.get("command", "")),
		"request": {"payload": request},
	}


func make_continuation_snapshot() -> Dictionary:
	if nested_trigger_active:
		return _continuation_error(
			"Finish the current Classic combat macro before saving"
		)
	if not active:
		return runtime.make_continuation_snapshot()
	var command := str(runtime.last_result.get("command", ""))
	if not manual_control_active \
			and command_adapter != null \
			and command_adapter.has_method("classic_continuation_save_policy"):
		var policy: Variant = command_adapter.call(
			"classic_continuation_save_policy",
			command
		)
		if policy is Dictionary and str(policy.get("status", "")) == "error":
			return policy
	var runtime_result := runtime.make_continuation_snapshot()
	if str(runtime_result.get("status", "")) != "ok":
		return runtime_result
	var snapshot: Dictionary = runtime_result["snapshot"]
	snapshot["commandContext"] = command_context.duplicate(true)
	return {"status": "ok", "snapshot": snapshot}


func restore_continuation(snapshot: Variant) -> Dictionary:
	active = false
	nested_trigger_active = false
	restored_continuation_pending = false
	command_context.clear()
	var runtime_result := runtime.restore_continuation(snapshot)
	if str(runtime_result.get("status", "")) != "ok":
		return runtime_result
	if str(snapshot.get("state", "")) != "suspended":
		return {"status": "ok"}
	var context_value: Variant = snapshot.get("commandContext", {})
	if not (context_value is Dictionary):
		return _continuation_error("Classic continuation has an invalid command context")
	command_context = context_value.duplicate(true)
	restored_continuation_pending = true
	return {"status": "ok"}


func has_restored_continuation() -> bool:
	return restored_continuation_pending


func resume_restored_continuation() -> Dictionary:
	if not restored_continuation_pending:
		return {"status": "ok", "handled": false}
	if command_router == null:
		return _continuation_error("ClassicRuntimeHost requires a scenario command router")
	restored_continuation_pending = false
	active = true
	var replay_result := runtime.replay_continuation()
	if str(replay_result.get("status", "")) == "error":
		active = false
		command_context.clear()
		return replay_result
	return {"status": "ok", "handled": true}


func _on_command_requested(command: String, payload: Dictionary) -> void:
	if not active:
		return
	var command_payload := payload.duplicate(true)
	for context_key: Variant in command_context:
		if not command_payload.has(context_key):
			command_payload[context_key] = command_context[context_key]
	command_started.emit(command, command_payload)
	if manual_control_active:
		return
	var response_value: Variant = await command_router.route(command, command_payload)
	if not active:
		return
	var response: Dictionary = response_value if response_value is Dictionary else {}
	command_finished.emit(command, response)
	if str(response.get("status", "")) == "error":
		_stop_with_error(str(response.get("message", "Classic command adapter failed")), command)
		return
	_resume_after_command(command, command_payload, response)


func _resume_after_command(command: String, _payload: Dictionary, response: Dictionary) -> void:
	if command == "teleport":
		var state: Object = runtime.runtime_state
		var reveal_result := reveal_dungeon_overhead(Vector2i(state.x, state.y))
		if str(reveal_result.get("status", "")) == "error":
			_stop_with_error(str(reveal_result.get(
				"message",
				"Classic dungeon overhead could not be revealed"
			)), command)
			return
	refresh_dungeon_view()
	runtime.finish_command(response)


func _on_trigger_completed(result: Dictionary) -> void:
	if not active:
		return
	var enhanced_dispatch := (
		str(command_context.get("source", ""))
			== "classic-enhanced-global-trigger"
	)
	active = false
	command_context.clear()
	if enhanced_dispatch and runtime != null and runtime.runtime_state != null:
		runtime.runtime_state.action_point_overrides.erase(
			ENHANCED_DISPATCH_TRIGGER_ID
		)
	playthrough_completed.emit(result)
	playthrough_finished.emit(result)
	if runtime != null \
			and runtime.interpreter != null \
			and runtime.interpreter.scenario_script_runtime != null \
			and not runtime.interpreter.scenario_script_runtime.event_queue.is_empty():
		call_deferred("_drain_script_event_queue")


func _on_runtime_stopped(result: Dictionary) -> void:
	if not active:
		return
	var enhanced_dispatch := (
		str(command_context.get("source", ""))
			== "classic-enhanced-global-trigger"
	)
	active = false
	command_context.clear()
	if enhanced_dispatch and runtime != null and runtime.runtime_state != null:
		runtime.runtime_state.action_point_overrides.erase(
			ENHANCED_DISPATCH_TRIGGER_ID
		)
	playthrough_stopped.emit(result)
	playthrough_finished.emit(result)


func _stop_with_error(message: String, command := "") -> void:
	active = false
	command_context.clear()
	var result := {
		"status": "error",
		"message": message,
	}
	if not command.is_empty():
		result["command"] = command
	playthrough_stopped.emit(result)
	playthrough_finished.emit(result)


static func _continuation_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
