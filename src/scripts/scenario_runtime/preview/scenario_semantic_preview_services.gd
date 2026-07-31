class_name ScenarioSemanticPreviewServices
extends RefCounted

const SNAPSHOT_SCHEMA_VERSION := 2

var command_log: Array = []
var transcript: Array[String] = []
var battles: Array[int] = []
var pictures: Array[int] = []
var sounds: Array[int] = []
var location := {
	"levelType": "land",
	"levelIndex": 0,
	"x": 0,
	"y": 0,
}
var choice_responses: Array[int] = []
var choice_response_index := 0


func configure(start: Dictionary, fixture := {}) -> void:
	command_log.clear()
	transcript.clear()
	battles.clear()
	pictures.clear()
	sounds.clear()
	choice_response_index = 0
	location = _normalized_location(start)
	choice_responses.clear()
	if fixture is Dictionary:
		for response_value: Variant in fixture.get("choiceResponses", []):
			choice_responses.append(int(response_value))


func apply_fixture(fixture: Variant) -> void:
	if not (fixture is Dictionary):
		return
	choice_responses.clear()
	for response_value: Variant in fixture.get("choiceResponses", []):
		choice_responses.append(int(response_value))
	choice_response_index = 0


func execute_command(command_id: String, request: Dictionary) -> Dictionary:
	var event := {
		"commandId": command_id,
		"request": request.duplicate(true),
	}
	var response: Dictionary
	match command_id:
		"show_text":
			transcript.append(str(request.get("text", "")))
			response = {}
		"choice":
			var options: Variant = request.get("options", [])
			var option_count: int = options.size() if options is Array else 0
			var selected := 0
			if choice_response_index < choice_responses.size():
				selected = choice_responses[choice_response_index]
				choice_response_index += 1
			if option_count > 0:
				selected = clampi(selected, 0, option_count - 1)
			response = {"choice": selected}
		"teleport":
			location = _normalized_location(request)
			response = {}
		"start_battle":
			battles.append(int(request.get("battleId", 0)))
			response = {}
		"show_picture":
			pictures.append(int(request.get("pictureId", 0)))
			response = {}
		"play_sound":
			sounds.append(int(request.get("soundId", 0)))
			response = {}
		_:
			response = {
				"status": "error",
				"message": "Semantic preview service cannot execute '%s'" % command_id,
			}
	event["response"] = response.duplicate(true)
	command_log.append(event)
	return response


func _scenario_choice(request: Dictionary) -> Dictionary:
	return execute_command("choice", request)


func snapshot() -> Dictionary:
	return {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"commandLog": command_log.duplicate(true),
		"transcript": Array(transcript),
		"battles": Array(battles),
		"pictures": Array(pictures),
		"sounds": Array(sounds),
		"location": location.duplicate(true),
		"choiceResponses": Array(choice_responses),
		"choiceResponseIndex": choice_response_index,
	}


func restore(value: Variant) -> Dictionary:
	var validation := validate_snapshot(value)
	if not bool(validation.get("valid", false)):
		return {
			"status": "error",
			"message": validation.get("message", "Preview service snapshot is invalid"),
		}
	var saved: Dictionary = value
	command_log = saved["commandLog"].duplicate(true)
	transcript.assign(saved["transcript"])
	battles.assign(saved["battles"])
	pictures.assign(saved["pictures"])
	sounds.assign(saved["sounds"])
	location = saved["location"].duplicate(true)
	choice_responses.assign(saved["choiceResponses"])
	choice_response_index = int(saved["choiceResponseIndex"])
	return {"status": "ok"}


static func validate_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _invalid("Preview service snapshot must be an object")
	var saved: Dictionary = value
	if int(saved.get("schemaVersion", 0)) != SNAPSHOT_SCHEMA_VERSION:
		return _invalid("Preview service snapshot schema is unsupported")
	for field_name: String in [
		"commandLog",
		"transcript",
		"battles",
		"pictures",
		"sounds",
		"choiceResponses",
	]:
		if not (saved.get(field_name) is Array):
			return _invalid("Preview service snapshot has invalid %s" % field_name)
	if not (saved.get("location") is Dictionary):
		return _invalid("Preview service snapshot has invalid location")
	if not (saved.get("choiceResponseIndex") is int):
		return _invalid("Preview service snapshot has invalid choice position")
	return {"valid": true}


static func _normalized_location(value: Dictionary) -> Dictionary:
	var map_id := str(value.get("mapId", ""))
	var level_type := str(value.get("levelType", ""))
	var level_index := int(value.get("levelIndex", 0))
	if not map_id.is_empty() and map_id.contains(":"):
		var parts := map_id.split(":", false, 1)
		level_type = str(parts[0])
		level_index = int(parts[1]) if parts.size() > 1 else 0
	if level_type not in ["land", "dungeon"]:
		level_type = "land"
	return {
		"levelType": level_type,
		"levelIndex": level_index,
		"x": int(value.get("x", 0)),
		"y": int(value.get("y", 0)),
	}


static func _invalid(message: String) -> Dictionary:
	return {"valid": false, "message": message}
