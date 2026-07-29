class_name ClassicRuntimeHost
extends Node

const DefaultScenarioPortsScript = preload(
	"res://scripts/scenario_runtime/default_scenario_ports.gd"
)
const ScenarioRuleModifierPipelineScript = preload(
	"res://scripts/scenario_runtime/scenario_rule_modifier_pipeline.gd"
)

signal command_started(command: String, payload: Dictionary)
signal command_finished(command: String, response: Dictionary)
signal playthrough_completed(result: Dictionary)
signal playthrough_stopped(result: Dictionary)
signal playthrough_finished(result: Dictionary)

var runtime: ClassicRuntime
var command_adapter: Object
var command_router: ScenarioCommandRouter
var gameplay_rule_set: GameplayRuleSet
var rule_modifier_pipeline: ScenarioRuleModifierPipeline
var active := false
var command_context: Dictionary = {}
var nested_trigger_active := false
var restored_continuation_pending := false
var _bound_behavior_active := false


func _init() -> void:
	runtime = ClassicRuntime.new()
	add_child(runtime)
	runtime.command_requested.connect(_on_command_requested)
	runtime.trigger_completed.connect(_on_trigger_completed)
	runtime.runtime_stopped.connect(_on_runtime_stopped)


func configure(adapter: Object, rules: GameplayRuleSet = null) -> void:
	command_adapter = adapter
	gameplay_rule_set = rules
	var router_result := DefaultScenarioPortsScript.create(adapter, rules)
	if str(router_result.get("status", "")) == "ok":
		command_router = router_result["router"]
	else:
		command_router = null
		push_error(str(router_result.get("message", "Scenario command router is unavailable")))
	if (
		command_router != null
		and runtime != null
		and runtime.bundle != null
		and runtime.bundle.extension_registry != null
	):
		_configure_extensions(false)


func load_campaign(directory: String) -> bool:
	active = false
	nested_trigger_active = false
	restored_continuation_pending = false
	command_context.clear()
	if not runtime.load_campaign(directory):
		return false
	if not _configure_extensions():
		return false
	_configure_adapter()
	return true


func use_campaign(campaign_bundle: ClassicCampaignBundle) -> void:
	active = false
	nested_trigger_active = false
	restored_continuation_pending = false
	command_context.clear()
	var loaded_state := ClassicRuntimeState.new()
	loaded_state.configure_from_bundle(campaign_bundle)
	runtime.use_shared_campaign(campaign_bundle, loaded_state)
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
	command_router.configure({
		"scenarioPortRuntime": command_adapter,
		"commandRouter": command_router,
		"gameplayRules": gameplay_rule_set,
		"extensionRegistry": extension_registry,
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
	if invoke_lifecycle:
		call_deferred("_run_campaign_loaded_behaviors")
	return true


func run_bound_behavior(
	behavior_id: String,
	arguments: Dictionary,
	context := {}
) -> Dictionary:
	if _bound_behavior_active:
		return {
			"status": "error",
			"message": "Scenario behavior dispatch cannot recursively invoke a provider",
		}
	if runtime == null or runtime.interpreter == null:
		return {"status": "error", "message": "Scenario interpreter is unavailable"}
	_bound_behavior_active = true
	var step: ScenarioStepResult = runtime.interpreter.execute_scenario_script(
		behavior_id,
		arguments,
		context
	)
	for _iteration: int in range(4096):
		if step == null or not step.is_valid():
			_bound_behavior_active = false
			return {"status": "error", "message": "Scenario behavior returned an invalid step"}
		match step.kind:
			ScenarioStepResult.CONTINUE, ScenarioStepResult.RETURN:
				_bound_behavior_active = false
				return {"status": "ok", "value": step.data.get("value")}
			ScenarioStepResult.HALT:
				_bound_behavior_active = false
				return {
					"status": "ok",
					"halted": true,
					"value": step.data.get("value"),
				}
			ScenarioStepResult.ERROR:
				_bound_behavior_active = false
				return {
					"status": "error",
					"message": step.data.get("message", "Scenario behavior failed"),
				}
			ScenarioStepResult.YIELD:
				var command_id := str(step.data.get("commandId", ""))
				var request: Variant = step.data.get("request", {})
				if command_router == null or not (request is Dictionary):
					_bound_behavior_active = false
					return {
						"status": "error",
						"message": "Scenario behavior yielded an invalid command",
					}
				command_started.emit(command_id, request)
				var response: Dictionary = await command_router.route(
					command_id,
					request
				)
				command_finished.emit(command_id, response)
				if str(response.get("status", "")) == "error":
					_bound_behavior_active = false
					return response
				step = runtime.interpreter.resume_scenario_script(response)
			_:
				_bound_behavior_active = false
				return {
					"status": "error",
					"message": "Scenario provider behavior cannot return '%s'"
						% step.kind,
				}
	_bound_behavior_active = false
	return {
		"status": "error",
		"message": "Scenario behavior exceeded its routed command limit",
	}


func run_behavior_attachments(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	request: Dictionary
) -> Dictionary:
	if runtime == null or runtime.interpreter == null:
		return {"handled": false}
	var bindings: Array = runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		int(request.get("slot", -1))
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


func has_behavior_attachments(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	slot := -1
) -> bool:
	if runtime == null or runtime.interpreter == null:
		return false
	return not runtime.interpreter.matching_scenario_behavior_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		slot
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
	return await rule_modifier_pipeline.resolve(event_id, base_value, context)


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
	event_request["hook"] = hook
	event_request["campaignId"] = str(runtime.bundle.manifest.get("id", ""))
	var attachment_result: Dictionary = await run_behavior_attachments(
		"lifecycle",
		hook,
		"lifecycle",
		["campaign"],
		event_request
	)
	if str(attachment_result.get("status", "")) == "error":
		return attachment_result
	var lifecycle_bindings: Variant = runtime.bundle.documents.get(
		"runtime",
		{}
	).get("bindings", {}).get("lifecycle", {})
	if not (lifecycle_bindings is Dictionary):
		return {"status": "ok", "handled": bool(attachment_result.get("handled", false))}
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
	return {"status": "ok", "handled": bool(attachment_result.get("handled", false))}


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
				"status": "error",
				"message": "Classic battle macro trigger '%s' is missing" % trigger_id,
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


func discover_map_secrets(position: Vector2i) -> Dictionary:
	if command_adapter == null \
			or not command_adapter.has_method("discover_classic_map_secrets"):
		return {"handled": false}
	var response: Variant = command_adapter.call(
		"discover_classic_map_secrets",
		runtime.runtime_state,
		position
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


func make_continuation_snapshot() -> Dictionary:
	if nested_trigger_active:
		return _continuation_error(
			"Finish the current Classic combat macro before saving"
		)
	if not active:
		return runtime.make_continuation_snapshot()
	var command := str(runtime.last_result.get("command", ""))
	if command_adapter != null \
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
	var response_value: Variant = await command_router.route(command, command_payload)
	if not active:
		return
	var response: Dictionary = response_value if response_value is Dictionary else {}
	command_finished.emit(command, response)
	if str(response.get("status", "")) == "error":
		_stop_with_error(str(response.get("message", "Classic command adapter failed")), command)
		return
	_resume_after_command(command, command_payload, response)


func _resume_after_command(command: String, payload: Dictionary, response: Dictionary) -> void:
	if command == "teleport":
		var state: Object = runtime.runtime_state
		var reveal_result := reveal_dungeon_overhead(Vector2i(state.x, state.y))
		if str(reveal_result.get("status", "")) == "error":
			_stop_with_error(str(reveal_result.get(
				"message",
				"Classic dungeon overhead could not be revealed"
			)), command)
			return
	runtime.finish_command(response)


func _on_trigger_completed(result: Dictionary) -> void:
	if not active:
		return
	active = false
	command_context.clear()
	playthrough_completed.emit(result)
	playthrough_finished.emit(result)


func _on_runtime_stopped(result: Dictionary) -> void:
	if not active:
		return
	active = false
	command_context.clear()
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
