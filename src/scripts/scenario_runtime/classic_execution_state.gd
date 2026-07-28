class_name ClassicScenarioExecutionState
extends RefCounted

const SNAPSHOT_SCHEMA_VERSION := 2
const MAX_CALL_STACK_DEPTH := 20

var current_trigger: Dictionary = {}
var current_action_index := 0
var origin_action_point: Dictionary = {}
var active_action_point_header: Dictionary = {}
var suppress_action_point_destination := false
var remove_action_point := false
var removal_x := 0
var removal_y := 0
var call_stack: Array = []
var gosub_active := false
var pending_continuation: Dictionary = {}
var execution_context: Dictionary = {}
var encounter_origins: Array = []
var loaded_simple_encounter_id := -1
var loaded_complex_encounter_id := -1
var trace: Array = []
var last_error := ""
var halted := false


func reset() -> void:
	current_trigger = {}
	current_action_index = 0
	origin_action_point.clear()
	active_action_point_header.clear()
	suppress_action_point_destination = false
	remove_action_point = false
	removal_x = 0
	removal_y = 0
	call_stack.clear()
	gosub_active = false
	pending_continuation.clear()
	execution_context.clear()
	encounter_origins.clear()
	trace.clear()
	last_error = ""
	halted = false


func make_snapshot() -> Dictionary:
	if halted:
		return _snapshot_error(
			"A stopped Classic action point cannot be saved"
		)
	var snapshot := {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"currentTrigger": current_trigger.duplicate(true),
		"currentActionIndex": current_action_index,
		"originActionPoint": origin_action_point.duplicate(true),
		"activeActionPointHeader": \
			active_action_point_header.duplicate(true),
		"suppressActionPointDestination": \
			suppress_action_point_destination,
		"removeActionPoint": remove_action_point,
		"removalX": removal_x,
		"removalY": removal_y,
		"callStack": call_stack.duplicate(true),
		"gosubActive": gosub_active,
		"pendingContinuation": pending_continuation.duplicate(true),
		"executionContext": execution_context.duplicate(true),
		"encounterOrigins": encounter_origins.duplicate(true),
		"loadedSimpleEncounterId": loaded_simple_encounter_id,
		"loadedComplexEncounterId": loaded_complex_encounter_id,
	}
	if not _is_snapshot_value(snapshot):
		return _snapshot_error(
			"Classic continuation contains runtime-only values and cannot be saved"
		)
	return {"status": "ok", "snapshot": snapshot}


func restore_snapshot(snapshot: Variant) -> Dictionary:
	var validation := validate_snapshot(snapshot)
	if str(validation.get("status", "")) != "ok":
		return validation
	var saved: Dictionary = snapshot
	reset()
	current_trigger = saved["currentTrigger"].duplicate(true)
	current_action_index = int(saved["currentActionIndex"])
	origin_action_point = saved["originActionPoint"].duplicate(true)
	active_action_point_header = \
		saved["activeActionPointHeader"].duplicate(true)
	suppress_action_point_destination = bool(saved.get(
		"suppressActionPointDestination",
		false
	))
	remove_action_point = bool(saved["removeActionPoint"])
	removal_x = int(saved["removalX"])
	removal_y = int(saved["removalY"])
	call_stack = saved["callStack"].duplicate(true)
	gosub_active = bool(saved["gosubActive"])
	pending_continuation = \
		saved["pendingContinuation"].duplicate(true)
	execution_context = saved["executionContext"].duplicate(true)
	encounter_origins = saved["encounterOrigins"].duplicate(true)
	loaded_simple_encounter_id = int(saved["loadedSimpleEncounterId"])
	loaded_complex_encounter_id = int(saved["loadedComplexEncounterId"])
	return {"status": "ok"}


static func validate_snapshot(snapshot: Variant) -> Dictionary:
	if not (snapshot is Dictionary):
		return _snapshot_error(
			"Classic continuation execution state is not a dictionary"
		)
	if int(snapshot.get("schemaVersion", 0)) != SNAPSHOT_SCHEMA_VERSION:
		return _snapshot_error(
			"Classic continuation execution schema is not supported"
		)
	for field_name: String in [
		"currentTrigger",
		"originActionPoint",
		"activeActionPointHeader",
		"pendingContinuation",
		"executionContext",
	]:
		if not (snapshot.get(field_name) is Dictionary):
			return _snapshot_error(
				"Classic continuation has invalid %s" % field_name
			)
	var pending_value: Dictionary = snapshot["pendingContinuation"]
	if not pending_value.is_empty():
		if not (pending_value.get("continuationId") is String) \
				or str(pending_value["continuationId"]).is_empty() \
				or not (pending_value.get("data") is Dictionary):
			return _snapshot_error(
				"Classic continuation has an invalid pending record"
			)
	for field_name: String in ["callStack", "encounterOrigins"]:
		if not (snapshot.get(field_name) is Array):
			return _snapshot_error(
				"Classic continuation has invalid %s" % field_name
			)
	if int(snapshot.get("currentActionIndex", -1)) < 0:
		return _snapshot_error(
			"Classic continuation has an invalid action index"
		)
	if snapshot["callStack"].size() > MAX_CALL_STACK_DEPTH:
		return _snapshot_error(
			"Classic continuation exceeds the GOSUB stack limit"
		)
	for field_name: String in ["removeActionPoint", "gosubActive"]:
		if not (snapshot.get(field_name) is bool):
			return _snapshot_error(
				"Classic continuation has invalid %s" % field_name
			)
	if snapshot.has("suppressActionPointDestination") \
			and not (
				snapshot.get("suppressActionPointDestination") is bool
			):
		return _snapshot_error(
			"Classic continuation has invalid "
			+ "suppressActionPointDestination"
		)
	for field_name: String in [
		"removalX",
		"removalY",
		"loadedSimpleEncounterId",
		"loadedComplexEncounterId",
	]:
		var field_value: Variant = snapshot.get(field_name)
		if not (field_value is int or field_value is float):
			return _snapshot_error(
				"Classic continuation has invalid %s" % field_name
			)
	for frame_value: Variant in snapshot["callStack"]:
		if not (frame_value is Dictionary) \
				or not (frame_value.get("trigger") is Dictionary) \
				or not (
					frame_value.get("actionPointHeader") is Dictionary
				) \
				or not (
					frame_value.get("actionIndex") is int
					or frame_value.get("actionIndex") is float
				):
			return _snapshot_error(
				"Classic continuation has an invalid GOSUB frame"
			)
	for origin_value: Variant in snapshot["encounterOrigins"]:
		if not (origin_value is Dictionary) \
				or not (origin_value.get("trigger") is Dictionary) \
				or not (origin_value.get("callStack") is Array) \
				or not (
					origin_value.get("actionPointHeader") is Dictionary
				):
			return _snapshot_error(
				"Classic continuation has an invalid encounter frame"
			)
	if not _is_snapshot_value(snapshot):
		return _snapshot_error(
			"Classic continuation contains invalid runtime values"
		)
	return {"status": "ok"}


static func _is_snapshot_value(value: Variant) -> bool:
	if value == null \
			or value is bool \
			or value is int \
			or value is float \
			or value is String:
		return true
	if value is Array:
		for child_value: Variant in value:
			if not _is_snapshot_value(child_value):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not (key is String) \
					or not _is_snapshot_value(value[key]):
				return false
		return true
	return false


static func _snapshot_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
