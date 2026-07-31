class_name ScenarioSemanticState
extends RefCounted

const SNAPSHOT_SCHEMA_VERSION := 3

var quest_values: Dictionary = {}
var completed_triggers: Dictionary = {}
var completed_encounters: Dictionary = {}
var completed_map_entries: Dictionary = {}
var map_entry_sequences: Dictionary = {}
var scheduled_markers: Dictionary = {}
var rng_state := 1
var location: Dictionary = {}


func configure(package_hash: String) -> void:
	quest_values.clear()
	completed_triggers.clear()
	completed_encounters.clear()
	completed_map_entries.clear()
	map_entry_sequences.clear()
	scheduled_markers.clear()
	location.clear()
	rng_state = 1
	if package_hash.length() >= 8:
		rng_state = maxi(1, package_hash.substr(0, 8).hex_to_int() & 0x7fffffff)


func get_quest_value(quest_id: int) -> int:
	return int(quest_values.get(absi(quest_id), 0))


func set_quest_value(quest_id: int, value: int) -> void:
	quest_values[absi(quest_id)] = clampi(value, -127, 127)


func set_location(
	level_type: String,
	level_index: int,
	x: int,
	y: int
) -> void:
	location = {
		"levelType": level_type,
		"levelIndex": level_index,
		"x": x,
		"y": y,
	}


func begin_map_entry(map_id: String) -> int:
	var sequence := int(map_entry_sequences.get(map_id, 0)) + 1
	map_entry_sequences[map_id] = sequence
	return sequence


func current_map_entry(map_id: String) -> int:
	return int(map_entry_sequences.get(map_id, 0))


func can_run_trigger(trigger: Dictionary) -> bool:
	var trigger_id := str(trigger.get("id", ""))
	match str(trigger.get("repeatPolicy", "always")):
		"once":
			return not bool(completed_triggers.get(trigger_id, false))
		"once-per-map-entry":
			var map_id := str(trigger.get("location", {}).get("mapId", ""))
			var key := "%s\u001f%s\u001f%d" % [
				trigger_id,
				map_id,
				current_map_entry(map_id),
			]
			return not bool(completed_map_entries.get(key, false))
	return true


func mark_trigger_completed(trigger: Dictionary) -> void:
	var trigger_id := str(trigger.get("id", ""))
	completed_triggers[trigger_id] = true
	if str(trigger.get("repeatPolicy", "always")) == "once-per-map-entry":
		var map_id := str(trigger.get("location", {}).get("mapId", ""))
		var key := "%s\u001f%s\u001f%d" % [
			trigger_id,
			map_id,
			current_map_entry(map_id),
		]
		completed_map_entries[key] = true


func can_run_encounter(encounter: Dictionary) -> bool:
	if str(encounter.get("repeatPolicy", "always")) == "once":
		return not bool(completed_encounters.get(
			str(encounter.get("id", "")),
			false
		))
	return true


func mark_encounter_completed(encounter: Dictionary) -> void:
	completed_encounters[str(encounter.get("id", ""))] = true


func scheduled_due_marker(trigger: Dictionary, clock: Dictionary) -> int:
	var trigger_id := str(trigger.get("id", ""))
	if trigger_id.is_empty():
		return -1
	var schedule: Variant = trigger.get("schedule", {})
	if not (schedule is Dictionary):
		return -1
	var elapsed_minutes := int(clock.get("elapsedMinutes", -1))
	var day := int(clock.get("day", -1))
	var minute := int(clock.get("minute", -1))
	if elapsed_minutes < 0 and day >= 0 and minute >= 0:
		elapsed_minutes = day * 1440 + minute
	var marker := -1
	match str(schedule.get("kind", "")):
		"absolute":
			var target_day := int(schedule.get("day", -1))
			var target_minute := int(schedule.get("minute", -1))
			if day >= 0 and minute >= 0 \
					and target_day >= 1 \
					and target_minute >= 0 \
					and day * 1440 + minute >= target_day * 1440 + target_minute:
				marker = (target_day - 1) * 1440 + target_minute
		"elapsed":
			var target_elapsed := int(schedule.get("elapsedMinutes", -1))
			if elapsed_minutes >= target_elapsed and target_elapsed >= 0:
				marker = target_elapsed
		"recurring":
			var interval := int(schedule.get("intervalMinutes", 0))
			if elapsed_minutes >= interval and interval > 0:
				marker = floori(
					float(elapsed_minutes) / float(interval)
				) * interval
	if marker < 0 or marker <= int(scheduled_markers.get(trigger_id, -1)):
		return -1
	return marker


func mark_scheduled_trigger(trigger_id: String, marker: int) -> void:
	if not trigger_id.is_empty() and marker >= 0:
		scheduled_markers[trigger_id] = marker


func roll_percent() -> int:
	rng_state = int((1103515245 * rng_state + 12345) & 0x7fffffff)
	return (rng_state % 100) + 1


func snapshot() -> Dictionary:
	return {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"questValues": quest_values.duplicate(true),
		"completedTriggers": completed_triggers.duplicate(true),
		"completedEncounters": completed_encounters.duplicate(true),
		"completedMapEntries": completed_map_entries.duplicate(true),
		"mapEntrySequences": map_entry_sequences.duplicate(true),
		"scheduledMarkers": scheduled_markers.duplicate(true),
		"rngState": rng_state,
		"location": location.duplicate(true),
	}


func restore(value: Variant) -> Dictionary:
	var validation := validate_snapshot(value)
	if not bool(validation.get("valid", false)):
		return {
			"status": "error",
			"message": validation.get("message", "Semantic state snapshot is invalid"),
		}
	var saved: Dictionary = value
	quest_values = saved["questValues"].duplicate(true)
	completed_triggers = saved["completedTriggers"].duplicate(true)
	completed_encounters = saved["completedEncounters"].duplicate(true)
	completed_map_entries = saved["completedMapEntries"].duplicate(true)
	map_entry_sequences = saved["mapEntrySequences"].duplicate(true)
	scheduled_markers = saved["scheduledMarkers"].duplicate(true)
	rng_state = int(saved["rngState"])
	location = saved.get("location", {}).duplicate(true)
	return {"status": "ok"}


static func validate_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _invalid("Semantic state snapshot must be an object")
	var saved: Dictionary = value
	if int(saved.get("schemaVersion", 0)) != SNAPSHOT_SCHEMA_VERSION:
		return _invalid("Semantic state snapshot schema is unsupported")
	for field_name: String in [
		"questValues",
		"completedTriggers",
		"completedEncounters",
		"completedMapEntries",
		"mapEntrySequences",
		"scheduledMarkers",
	]:
		if not (saved.get(field_name) is Dictionary):
			return _invalid("Semantic state snapshot has invalid %s" % field_name)
	if not (saved.get("rngState") is int):
		return _invalid("Semantic state snapshot has invalid RNG state")
	if not (saved.get("location", {}) is Dictionary):
		return _invalid("Semantic state snapshot has invalid location")
	return {"valid": true}


static func _invalid(message: String) -> Dictionary:
	return {"valid": false, "message": message}
