class_name ScenarioEncounterHandler
extends ClassicOpcodeHandler


func _init() -> void:
	configure("core.encounters", PackedInt32Array([3, 4, 5]))


func semantic_operations() -> PackedStringArray:
	return PackedStringArray(["core.encounter.request-response"])


func execute(instruction: Dictionary, context: Object) -> ScenarioStepResult:
	if str(instruction.get("kind", "")) != "semantic":
		return super.execute(instruction, context)
	var parameters: Variant = instruction.get("parameters", {})
	if not (parameters is Dictionary):
		return ScenarioStepResult.failed(
			"core.encounter.request-response parameters must be an object"
		)
	var section_value: Variant = parameters.get("section", {})
	var targets_value: Variant = parameters.get("targets", {})
	if not (section_value is Dictionary) or not (targets_value is Dictionary):
		return ScenarioStepResult.failed(
			"Encounter response request requires a section and response targets"
		)
	var section: Dictionary = section_value
	var validation := _validate_section(section, targets_value)
	if not validation.is_empty():
		return ScenarioStepResult.failed(validation)
	var available_result := _available_responses(
		section,
		str(parameters.get("encounterId", "")),
		context
	)
	if str(available_result.get("status", "")) == "error":
		return ScenarioStepResult.failed(str(available_result.get("message", "")))
	var available: Array = available_result.get("responses", [])
	if available.is_empty():
		return ScenarioStepResult.failed(
			"Encounter section '%s' has no available responses"
			% section.get("id", "")
		)
	var response_ids: Array = []
	for response_value: Variant in available:
		response_ids.append(str(response_value.get("id", "")))
	return ScenarioStepResult.yielded(
		"encounter_response",
		{
			"encounterId": str(parameters.get("encounterId", "")),
			"sectionId": str(section.get("id", "")),
			"sectionName": str(section.get("name", "")),
			"text": str(section.get("text", "")),
			"pictureId": section.get("pictureId"),
			"soundId": section.get("soundId"),
			"presentation": section.get("presentation", {}).duplicate(true),
			"responses": available.duplicate(true),
		},
		{
			"semanticEncounterResponse": true,
			"encounterId": str(parameters.get("encounterId", "")),
			"sectionId": str(section.get("id", "")),
			"availableResponseIds": response_ids,
			"targets": targets_value.duplicate(true),
		}
	)


func resume(
	pending: ScenarioPendingCommand,
	response: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if not bool(pending.continuation.get("semanticEncounterResponse", false)):
		return super.resume(pending, response, context)
	var available: Variant = pending.continuation.get("availableResponseIds", [])
	var targets: Variant = pending.continuation.get("targets", {})
	if not (available is Array) or available.is_empty() or not (targets is Dictionary):
		return ScenarioStepResult.failed(
			"Encounter response continuation is invalid"
		)
	var response_id := _selected_response_id(response, available)
	if response_id.is_empty() or not targets.has(response_id):
		return ScenarioStepResult.failed(
			"Encounter presenter returned an unavailable response"
		)
	if context != null and context.has_method("record_semantic_response_reference"):
		context.call(
			"record_semantic_response_reference",
			{
				"kind": "remake-response",
				"encounterId": str(pending.continuation.get("encounterId", "")),
				"sectionId": str(pending.continuation.get("sectionId", "")),
				"responseId": response_id,
			}
		)
	return ScenarioStepResult.branched(int(targets.get(response_id, -1)))


func execute_on_runtime(instruction: Dictionary, runtime: Object) -> Dictionary:
	var code := int(instruction.get("code", 0))
	var record_id := int(instruction.get("id", 0))
	match code:
		3:
			return _invoke(
				runtime,
				"_execute_choice",
				[record_id, bool(runtime.gosub_active)]
			)
		4:
			return _invoke(runtime, "_execute_encounter", ["simple", record_id])
		5:
			return _invoke(runtime, "_execute_encounter", ["complex", record_id])
	return _unsupported(instruction)


func _available_responses(
	section: Dictionary,
	encounter_id: String,
	context: Object
) -> Dictionary:
	var available: Array = []
	for response_value: Variant in section.get("responses", []):
		if not (response_value is Dictionary):
			return _error("Encounter response is invalid")
		var authored_response: Dictionary = response_value
		var availability_id := _optional_id(
			authored_response.get("availabilityBehaviorId")
		)
		if availability_id.is_empty():
			available.append(authored_response)
			continue
		if context == null or not context.has_method("execute_scenario_script"):
			return _error("Encounter availability runtime is unavailable")
		var result: ScenarioStepResult = context.call(
			"execute_scenario_script",
			availability_id,
			{},
			{
				"role": "encounter",
				"hook": "availability",
				"encounterId": encounter_id,
				"sectionId": str(section.get("id", "")),
				"responseId": str(authored_response.get("id", "")),
			}
		)
		if result == null or result.kind == ScenarioStepResult.ERROR:
			return _error(
				str(result.data.get(
					"message",
					"Encounter availability behavior failed"
				)) if result != null else "Encounter availability returned no result"
			)
		if result.kind != ScenarioStepResult.CONTINUE \
				or not (result.data.get("value") is bool):
			return _error(
				"Encounter availability behavior must be pure and return bool"
			)
		if bool(result.data.get("value")):
			available.append(authored_response)
	return {"status": "ok", "responses": available}


func _validate_section(section: Dictionary, targets: Dictionary) -> String:
	var section_id := str(section.get("id", ""))
	if section_id.is_empty():
		return "Encounter response request requires a stable section ID"
	var responses: Variant = section.get("responses", [])
	if not (responses is Array) or responses.is_empty():
		return "Encounter section '%s' has no responses" % section_id
	var ids: Dictionary = {}
	var match_keys: Dictionary = {}
	for response_value: Variant in responses:
		if not (response_value is Dictionary):
			return "Encounter section '%s' has an invalid response" % section_id
		var response_id := str(response_value.get("id", ""))
		if response_id.is_empty() or ids.has(response_id):
			return "Encounter response IDs must be unique"
		var response_error := _validate_semantic_response(response_value)
		if not response_error.is_empty():
			return "Encounter response '%s' %s" % [response_id, response_error]
		var match_key := _semantic_response_match_key(response_value)
		if not match_key.is_empty() and match_keys.has(match_key):
			return "Encounter responses cannot use the same typed, spell, or item match twice"
		if not match_key.is_empty():
			match_keys[match_key] = true
		if not targets.has(response_id) or int(targets.get(response_id, -1)) < 0:
			return "Encounter response '%s' has no execution target" % response_id
		ids[response_id] = true
	return ""


static func _validate_semantic_response(response: Dictionary) -> String:
	var kind := str(response.get("kind", "choice"))
	if kind not in [
		"choice",
		"typed-reply",
		"spell",
		"item",
		"rogue",
		"back-out",
	]:
		return "has an unsupported kind '%s'" % kind
	var match_value: Variant = response.get("match", {})
	if not (match_value is Dictionary):
		return "has invalid matching data"
	var response_match: Dictionary = match_value
	if kind == "typed-reply" \
			and str(response_match.get("text", "")).strip_edges().is_empty():
		return "requires matching text"
	if kind in ["spell", "item"] \
			and str(response_match.get("recordId", "")).strip_edges().is_empty():
		return "requires a stable record ID"
	if kind == "rogue" \
			and str(response_match.get("outcome", "attempt")) != "attempt":
		return (
			"must be a selectable attempt; success and failure routing belongs "
			+ "inside its Behavior"
		)
	return ""


static func _semantic_response_match_key(response: Dictionary) -> String:
	var kind := str(response.get("kind", ""))
	var response_match: Dictionary = response.get("match", {})
	if kind == "typed-reply":
		return "%s:%s" % [
			kind,
			str(response_match.get("text", "")).strip_edges().to_lower(),
		]
	if kind in ["spell", "item"]:
		return "%s:%s" % [
			kind,
			str(response_match.get("recordId", "")).strip_edges().to_lower(),
		]
	return ""


static func _selected_response_id(response: Dictionary, available: Array) -> String:
	var reference: Variant = response.get("responseRef")
	if reference is Dictionary:
		var referenced_id := str(reference.get("responseId", reference.get("id", "")))
		if referenced_id in available:
			return referenced_id
	var direct_id := str(response.get("responseId", ""))
	if direct_id in available:
		return direct_id
	var selected_index := clampi(int(response.get("choice", 0)), 0, available.size() - 1)
	return str(available[selected_index])


static func _optional_id(value: Variant) -> String:
	return str(value) if value is String else ""


static func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
