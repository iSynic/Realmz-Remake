class_name ScenarioSemanticRuntimeHost
extends Node

signal command_started(command: String, request: Dictionary)
signal command_finished(command: String, response: Dictionary)

var session: Object
var runtime: Object
var interpreter: Object
var runtime_state: Object
var command_router: Object
var active: bool:
	get:
		return interpreter != null and interpreter.pending_command != null


func configure(owner: Object) -> void:
	session = owner
	runtime = self
	interpreter = owner.interpreter
	runtime_state = owner.semantic_state
	command_router = owner.command_router


func has_trigger(trigger_id: String) -> bool:
	return session != null and session.triggers_by_id.has(trigger_id)


func has_encounter(encounter_id: String) -> bool:
	return session != null and session.encounters_by_id.has(encounter_id)


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
	return result


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
