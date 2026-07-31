class_name ScenarioSemanticRuntimeHost
extends Node

signal command_started(command: String, request: Dictionary)
signal command_finished(command: String, response: Dictionary)

var session: Object
var runtime: Object
var interpreter: Object
var runtime_state: Object
var command_router: Object
var _event_queue: Array = []
var _event_queue_draining := false
var active: bool:
	get:
		return interpreter != null and interpreter.pending_command != null


func configure(owner: Object) -> void:
	session = owner
	runtime = self
	interpreter = owner.interpreter
	runtime_state = owner.semantic_state
	command_router = owner.command_router
	_event_queue.clear()
	_event_queue_draining = false


func has_trigger(trigger_id: String) -> bool:
	return session != null and session.triggers_by_id.has(trigger_id)


func has_encounter(encounter_id: String) -> bool:
	return session != null and session.encounters_by_id.has(encounter_id)


func has_event_trigger(trigger_id: String) -> bool:
	return session != null and session.event_triggers_by_id.has(trigger_id)


func has_scheduled_trigger(trigger_id: String) -> bool:
	return session != null and session.scheduled_triggers_by_id.has(trigger_id)


func run_trigger(
	trigger_id: String,
	_start_slot := 0,
	context := {}
) -> Dictionary:
	if session == null:
		return _error("Semantic campaign session is unavailable")
	command_started.emit("map-trigger", {
		"triggerId": trigger_id,
		"context": context,
	})
	var result: Dictionary = await session.run_map_trigger(trigger_id, context)
	command_finished.emit("map-trigger", result)
	_schedule_event_queue_drain()
	return result


func run_encounter(
	encounter_id: String,
	context := {},
	start_node_id := ""
) -> Dictionary:
	if session == null:
		return _error("Semantic campaign session is unavailable")
	command_started.emit("encounter", {
		"encounterId": encounter_id,
		"nodeId": start_node_id,
		"context": context,
	})
	var result: Dictionary = await session.run_encounter(
		encounter_id,
		context,
		start_node_id
	)
	command_finished.emit("encounter", result)
	_schedule_event_queue_drain()
	return result


func run_event(event_name: String, context := {}) -> Dictionary:
	if session == null:
		return _error("Semantic campaign session is unavailable")
	command_started.emit("event-trigger", {
		"event": event_name,
		"context": context,
	})
	var result: Dictionary = await session.run_event(event_name, context)
	command_finished.emit("event-trigger", result)
	_schedule_event_queue_drain()
	return result


func run_scheduled(clock: Dictionary, context := {}) -> Dictionary:
	if session == null:
		return _error("Semantic campaign session is unavailable")
	command_started.emit("scheduled-trigger", {
		"clock": clock,
		"context": context,
	})
	var result: Dictionary = await session.run_scheduled(clock, context)
	command_finished.emit("scheduled-trigger", result)
	_schedule_event_queue_drain()
	return result


func emit_lifecycle_event(hook: String, request := {}) -> Dictionary:
	var event_request: Dictionary = (
		request.duplicate(true) if request is Dictionary else {}
	)
	if active or not session.pending_trigger_queue.is_empty():
		if _event_queue.size() >= 256:
			return _error("Semantic event queue limit exceeded")
		_event_queue.append({
			"hook": hook,
			"request": event_request,
		})
		return {"status": "ok", "queued": true, "handled": false}
	var result := await _dispatch_lifecycle_event(hook, event_request)
	_schedule_event_queue_drain()
	return result


func _dispatch_lifecycle_event(
	hook: String,
	request: Dictionary
) -> Dictionary:
	var event_result := await run_event(hook, request)
	if str(event_result.get("status", "")) == "error":
		return event_result
	var schedule_result := {"status": "complete", "handled": false}
	if hook == "time-advanced":
		var current_time := int(request.get("currentTime", 0))
		var clock := {
			"elapsedMinutes": maxi(0, floori(float(current_time) / 60.0)),
			"day": maxi(1, floori(float(current_time) / 86400.0) + 1),
			"minute": maxi(
				0,
				floori(float(current_time % 86400) / 60.0)
			),
		}
		schedule_result = await run_scheduled(clock, request)
		if str(schedule_result.get("status", "")) == "error":
			return schedule_result
	return {
		"status": "ok",
		"handled": (
			bool(event_result.get("handled", false))
			or bool(schedule_result.get("handled", false))
		),
		"event": event_result,
		"scheduled": schedule_result,
	}


func _drain_event_queue() -> void:
	if _event_queue_draining or active:
		return
	_event_queue_draining = true
	while not _event_queue.is_empty() and not active:
		var entry_value: Variant = _event_queue.pop_front()
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var result := await _dispatch_lifecycle_event(
			str(entry.get("hook", "")),
			entry.get("request", {})
		)
		if str(result.get("status", "")) == "error":
			push_error(str(result.get(
				"message",
				"Queued semantic event failed"
			)))
	_event_queue_draining = false


func lifecycle_event_queue_snapshot() -> Array:
	return _event_queue.duplicate(true)


func restore_lifecycle_event_queue(value: Variant) -> Dictionary:
	if not (value is Array) or value.size() > 256:
		return _error("Saved semantic lifecycle event queue is invalid")
	for entry_value: Variant in value:
		if not (entry_value is Dictionary):
			return _error("Saved semantic lifecycle event is invalid")
		var entry: Dictionary = entry_value
		if str(entry.get("hook", "")).is_empty() \
				or not (entry.get("request", {}) is Dictionary):
			return _error("Saved semantic lifecycle event is malformed")
	_event_queue = value.duplicate(true)
	_schedule_event_queue_drain()
	return {"status": "ok"}


func _schedule_event_queue_drain() -> void:
	if not _event_queue_draining and not active and not _event_queue.is_empty():
		call_deferred("_drain_event_queue")


func make_continuation_snapshot() -> Dictionary:
	if interpreter == null:
		return _error("Semantic interpreter is unavailable")
	return {"status": "ok", "snapshot": interpreter.snapshot()}


func snapshot_port_state() -> Dictionary:
	return command_router.snapshot_state() if command_router != null else {}


func restore_port_state(state: Dictionary) -> Dictionary:
	if command_router == null:
		return _error("Semantic command router is unavailable")
	return command_router.restore_state(state)


static func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
