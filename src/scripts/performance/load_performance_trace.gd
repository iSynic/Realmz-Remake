extends Node

const DEFAULT_FRAME_BUDGET_USEC := 8000
const OUTPUT_PREFIX := "REALMZ_PERF "

var enabled := false

var _next_token := 1
var _active_phases: Dictionary = {}
var _named_tokens: Dictionary = {}


func _enter_tree() -> void:
	enabled = (
		OS.is_debug_build()
		or OS.get_cmdline_args().has("--profile-load")
		or OS.get_cmdline_user_args().has("--profile-load")
	)
	set_process(enabled)
	if enabled:
		begin_named(&"startup.main_scene")


func _process(_delta: float) -> void:
	if not enabled or _active_phases.is_empty():
		return
	var frame_tick := Time.get_ticks_usec()
	for token: Variant in _active_phases.keys():
		var phase: Dictionary = _active_phases[token]
		var frame_usec := frame_tick - int(
			phase.get("last_frame_tick_usec", frame_tick)
		)
		phase["longest_frame_usec"] = maxi(
			int(phase.get("longest_frame_usec", 0)),
			frame_usec
		)
		phase["last_frame_tick_usec"] = frame_tick
		_active_phases[token] = phase


func begin_phase(phase_name: StringName, context: Dictionary = {}) -> int:
	if not enabled:
		return 0
	var token := _next_token
	_next_token += 1
	var started_usec := Time.get_ticks_usec()
	_active_phases[token] = {
		"name": str(phase_name),
		"started_usec": started_usec,
		"last_frame_tick_usec": started_usec,
		"longest_frame_usec": 0,
		"context": context.duplicate(true),
	}
	return token


func begin_named(phase_name: StringName, context: Dictionary = {}) -> int:
	if not enabled:
		return 0
	var name_key := str(phase_name)
	if _named_tokens.has(name_key):
		end_named(phase_name, false, {"error": "phase_restarted"})
	var token := begin_phase(phase_name, context)
	_named_tokens[name_key] = token
	return token


func end_named(
	phase_name: StringName,
	success: bool = true,
	context: Dictionary = {}
) -> Dictionary:
	var name_key := str(phase_name)
	var token := int(_named_tokens.get(name_key, 0))
	_named_tokens.erase(name_key)
	return end_phase(token, success, context)


func end_phase(
	token: int,
	success: bool = true,
	context: Dictionary = {}
) -> Dictionary:
	if not enabled or token == 0 or not _active_phases.has(token):
		return {}
	var phase: Dictionary = _active_phases[token]
	_active_phases.erase(token)
	var finished_usec := Time.get_ticks_usec()
	var merged_context: Dictionary = phase.get("context", {}).duplicate(true)
	merged_context.merge(context, true)
	var duration_usec := finished_usec - int(phase.get("started_usec", finished_usec))
	var longest_frame_usec := int(phase.get("longest_frame_usec", 0))
	longest_frame_usec = maxi(
		longest_frame_usec,
		finished_usec - int(phase.get("last_frame_tick_usec", finished_usec))
	)
	var payload := {
		"phase": str(phase.get("name", "")),
		"duration_usec": duration_usec,
		"duration_ms": snappedf(float(duration_usec) / 1000.0, 0.001),
		"longest_frame_usec": longest_frame_usec,
		"longest_frame_ms": snappedf(float(longest_frame_usec) / 1000.0, 0.001),
		"success": success,
		"cache_status": str(merged_context.get("cache_status", "none")),
		"campaign": str(merged_context.get("campaign", "")),
	}
	for key: Variant in merged_context:
		var key_string := str(key)
		if payload.has(key_string):
			continue
		var value: Variant = merged_context[key]
		if value == null or value is bool or value is int or value is float or value is String:
			payload[key_string] = value
	print(OUTPUT_PREFIX + JSON.stringify(payload))
	return payload


func is_frame_budget_exhausted(
	frame_started_usec: int,
	budget_usec: int = DEFAULT_FRAME_BUDGET_USEC
) -> bool:
	return Time.get_ticks_usec() - frame_started_usec >= budget_usec


func reset_for_tests() -> void:
	_active_phases.clear()
	_named_tokens.clear()
	_next_token = 1
