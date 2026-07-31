class_name ScenarioEncounterHandler
extends ClassicOpcodeHandler


func _init() -> void:
	configure("core.encounters", PackedInt32Array([3, 4, 5]))


func semantic_operations() -> PackedStringArray:
	return PackedStringArray(["core.encounter.run"])


func execute(instruction: Dictionary, context: Object) -> ScenarioStepResult:
	if str(instruction.get("kind", "")) != "semantic":
		return super.execute(instruction, context)
	var parameters: Variant = instruction.get("parameters", {})
	if not (parameters is Dictionary):
		return ScenarioStepResult.failed(
			"core.encounter.run parameters must be an object"
		)
	var encounter_value: Variant = parameters.get("encounter", {})
	if not (encounter_value is Dictionary):
		return ScenarioStepResult.failed(
			"core.encounter.run requires an encounter"
		)
	var encounter: Dictionary = encounter_value
	var validation := _validate_semantic_encounter(encounter)
	if not validation.is_empty():
		return ScenarioStepResult.failed(validation)
	return _advance_semantic({
		"semanticEncounter": true,
		"encounter": encounter.duplicate(true),
		"nodeId": str(encounter.get("entryNodeId", "")),
		"phase": "entry",
		"outcome": "continue",
		"availableChoiceIds": [],
		"selectedChoiceId": "",
	}, context)


func resume(
	pending: ScenarioPendingCommand,
	response: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if not bool(pending.continuation.get("semanticEncounter", false)):
		return super.resume(pending, response, context)
	var state := pending.continuation.duplicate(true)
	if bool(state.get("scriptPending", false)):
		if context == null or not context.has_method("resume_scenario_script"):
			return ScenarioStepResult.failed(
				"Encounter behavior runtime is unavailable"
			)
		var script_result: ScenarioStepResult = context.call(
			"resume_scenario_script",
			response
		)
		return _continue_after_behavior(script_result, state, context)
	match str(state.get("phase", "")):
		"node-sound", "node-text", "choices":
			return _advance_semantic(state, context)
		"choice":
			var available: Variant = state.get("availableChoiceIds", [])
			if not (available is Array) or available.is_empty():
				return ScenarioStepResult.failed(
					"Encounter choice continuation has no available choices"
				)
			var selected_index := clampi(
				int(response.get("choice", 0)),
				0,
				available.size() - 1
			)
			state["selectedChoiceId"] = str(available[selected_index])
			state["phase"] = "selection"
			return _advance_semantic(state, context)
	return ScenarioStepResult.failed(
		"Encounter continuation phase '%s' is unsupported"
		% state.get("phase", "")
	)


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


func _advance_semantic(state: Dictionary, context: Object) -> ScenarioStepResult:
	for _step: int in range(256):
		var encounter: Dictionary = state.get("encounter", {})
		var phase := str(state.get("phase", ""))
		match phase:
			"entry":
				state["phase"] = "node-picture"
				var entry_behavior := _optional_id(
					encounter.get("entryBehaviorId")
				)
				if not entry_behavior.is_empty():
					return _run_behavior(
						entry_behavior,
						"enter",
						"entry",
						state,
						context
					)
			"node-picture":
				var node_result := _semantic_node(state)
				if str(node_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(node_result["message"]))
				var node: Dictionary = node_result["node"]
				state["phase"] = "node-sound"
				var picture_id := _optional_id(node.get("pictureId"))
				if not picture_id.is_empty():
					return _yield_encounter(
						"show_picture",
						{"pictureId": int(picture_id)},
						state
					)
			"node-sound":
				var node_result := _semantic_node(state)
				if str(node_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(node_result["message"]))
				var node: Dictionary = node_result["node"]
				state["phase"] = "node-text"
				var sound_id := _optional_id(node.get("soundId"))
				if not sound_id.is_empty():
					return _yield_encounter(
						"play_sound",
						{"soundId": int(sound_id), "wait": true},
						state
					)
			"node-text":
				var node_result := _semantic_node(state)
				if str(node_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(node_result["message"]))
				var node: Dictionary = node_result["node"]
				state["phase"] = "choices"
				var text := str(node.get("text", ""))
				if not text.is_empty():
					return _yield_encounter(
						"show_text",
						{"text": text},
						state
					)
			"choices":
				var choices_result := _available_choices(state, context)
				if str(choices_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(
						choices_result.get("message", "")
					))
				var choices: Array = choices_result.get("choices", [])
				if choices.is_empty():
					state["outcome"] = "close"
					state["phase"] = "completion"
					continue
				var choice_ids: Array = []
				var labels: Array = []
				for choice_value: Variant in choices:
					var choice: Dictionary = choice_value
					choice_ids.append(str(choice.get("id", "")))
					labels.append(str(choice.get("label", "")))
				state["availableChoiceIds"] = choice_ids
				state["phase"] = "choice"
				return _yield_encounter(
					"choice",
					{
						"prompt": "",
						"options": labels,
						"encounterId": str(encounter.get("id", "")),
						"nodeId": str(state.get("nodeId", "")),
					},
					state
				)
			"selection":
				var choice_result := _selected_choice(state)
				if str(choice_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(choice_result["message"]))
				var choice: Dictionary = choice_result["choice"]
				state["phase"] = "after-selection"
				var selection_behavior := _optional_id(
					choice.get("selectionBehaviorId")
				)
				if not selection_behavior.is_empty():
					return _run_behavior(
						selection_behavior,
						"result",
						"selection",
						state,
						context
					)
			"after-selection":
				var choice_result := _selected_choice(state)
				if str(choice_result.get("status", "")) == "error":
					return ScenarioStepResult.failed(str(choice_result["message"]))
				var choice: Dictionary = choice_result["choice"]
				var outcome := str(state.get(
					"behaviorOutcome",
					choice.get("outcome", "continue")
				))
				state.erase("behaviorOutcome")
				var destination := str(state.get(
					"behaviorDestination",
					choice.get("nextNodeId", "")
				))
				state.erase("behaviorDestination")
				if outcome == "repeat":
					state["nodeId"] = str(encounter.get("entryNodeId", ""))
					state["phase"] = "entry"
					continue
				if outcome == "branch" or (
					outcome == "continue" and not destination.is_empty()
				):
					if destination.is_empty():
						return ScenarioStepResult.failed(
							"Encounter branch has no destination scene"
						)
					state["nodeId"] = destination
					state["phase"] = "node-picture"
					continue
				state["outcome"] = outcome
				state["phase"] = "completion"
			"completion":
				state["phase"] = "done"
				var completion_behavior := _optional_id(
					encounter.get("completionBehaviorId")
				)
				if not completion_behavior.is_empty():
					return _run_behavior(
						completion_behavior,
						"complete",
						"completion",
						state,
						context
					)
			"done":
				if context != null \
						and context.has_method(
							"record_semantic_encounter_completion"
						):
					context.call(
						"record_semantic_encounter_completion",
						encounter
					)
				return ScenarioStepResult.continued({
					"encounterId": str(encounter.get("id", "")),
					"outcome": str(state.get("outcome", "close")),
				})
			_:
				return ScenarioStepResult.failed(
					"Encounter phase '%s' is unsupported" % phase
				)
	return ScenarioStepResult.failed(
		"Encounter exceeded its semantic transition budget"
	)


func _run_behavior(
	behavior_id: String,
	hook: String,
	purpose: String,
	state: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if context == null or not context.has_method("execute_scenario_script"):
		return ScenarioStepResult.failed("Encounter behavior runtime is unavailable")
	state["behaviorPurpose"] = purpose
	var encounter: Dictionary = state.get("encounter", {})
	var result: ScenarioStepResult = context.call(
		"execute_scenario_script",
		behavior_id,
		{},
		{
			"role": "encounter",
			"hook": hook,
			"encounter": encounter.duplicate(true),
			"nodeId": str(state.get("nodeId", "")),
			"choiceId": str(state.get("selectedChoiceId", "")),
		}
	)
	return _continue_after_behavior(result, state, context)


func _continue_after_behavior(
	result: ScenarioStepResult,
	state: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if result == null:
		return ScenarioStepResult.failed("Encounter behavior returned no result")
	if result.kind == ScenarioStepResult.YIELD:
		state["scriptPending"] = true
		return _yield_encounter(
			str(result.data.get("commandId", "")),
			result.data.get("request", {}),
			state
		)
	if result.kind == ScenarioStepResult.ERROR:
		return result
	if result.kind != ScenarioStepResult.CONTINUE:
		return ScenarioStepResult.failed(
			"Encounter behavior returned unsupported VM flow '%s'" % result.kind
		)
	state.erase("scriptPending")
	var value: Variant = result.data.get("value")
	if value is Dictionary:
		var behavior_outcome := str(value.get("kind", "continue"))
		if behavior_outcome not in [
			"continue", "resolve", "repeat", "close", "branch",
		]:
			return ScenarioStepResult.failed(
				"Encounter behavior returned unsupported outcome '%s'"
				% behavior_outcome
			)
		if str(state.get("behaviorPurpose", "")) == "selection" \
				and behavior_outcome != "continue":
			state["behaviorOutcome"] = behavior_outcome
			if value.has("nodeId"):
				state["behaviorDestination"] = str(value.get("nodeId", ""))
	state.erase("behaviorPurpose")
	return _advance_semantic(state, context)


func _available_choices(state: Dictionary, context: Object) -> Dictionary:
	var node_result := _semantic_node(state)
	if str(node_result.get("status", "")) == "error":
		return node_result
	var available: Array = []
	for choice_value: Variant in node_result["node"].get("choices", []):
		if not (choice_value is Dictionary):
			return _semantic_error("Encounter choice is invalid")
		var choice: Dictionary = choice_value
		var availability_id := _optional_id(
			choice.get("availabilityBehaviorId")
		)
		if availability_id.is_empty():
			available.append(choice)
			continue
		if context == null or not context.has_method("execute_scenario_script"):
			return _semantic_error("Encounter availability runtime is unavailable")
		var result: ScenarioStepResult = context.call(
			"execute_scenario_script",
			availability_id,
			{},
			{
				"role": "helper",
				"hook": "",
				"encounter": state.get("encounter", {}).duplicate(true),
				"nodeId": str(state.get("nodeId", "")),
				"choiceId": str(choice.get("id", "")),
			}
		)
		if result == null or result.kind == ScenarioStepResult.ERROR:
			return _semantic_error(
				str(result.data.get(
					"message",
					"Encounter availability behavior failed"
				)) if result != null else "Encounter availability returned no result"
			)
		if result.kind != ScenarioStepResult.CONTINUE \
				or not (result.data.get("value") is bool):
			return _semantic_error(
				"Encounter availability behavior must be pure and return bool"
			)
		if bool(result.data.get("value")):
			available.append(choice)
	return {"status": "ok", "choices": available}


func _semantic_node(state: Dictionary) -> Dictionary:
	var encounter: Dictionary = state.get("encounter", {})
	var node_id := str(state.get("nodeId", ""))
	for node_value: Variant in encounter.get("nodes", []):
		if node_value is Dictionary \
				and str(node_value.get("id", "")) == node_id:
			return {"status": "ok", "node": node_value}
	return _semantic_error(
		"Encounter '%s' has no scene '%s'"
		% [encounter.get("id", ""), node_id]
	)


func _selected_choice(state: Dictionary) -> Dictionary:
	var node_result := _semantic_node(state)
	if str(node_result.get("status", "")) == "error":
		return node_result
	var choice_id := str(state.get("selectedChoiceId", ""))
	for choice_value: Variant in node_result["node"].get("choices", []):
		if choice_value is Dictionary \
				and str(choice_value.get("id", "")) == choice_id:
			return {"status": "ok", "choice": choice_value}
	return _semantic_error(
		"Encounter scene has no selected choice '%s'" % choice_id
	)


func _yield_encounter(
	command_id: String,
	request: Variant,
	state: Dictionary
) -> ScenarioStepResult:
	if command_id.is_empty():
		return ScenarioStepResult.failed(
			"Encounter behavior yielded an empty command"
		)
	return ScenarioStepResult.yielded(
		command_id,
		request if request is Dictionary else {},
		state
	)


func _validate_semantic_encounter(encounter: Dictionary) -> String:
	var encounter_id := str(encounter.get("id", ""))
	if encounter_id.is_empty():
		return "Semantic encounter requires a stable ID"
	var nodes: Variant = encounter.get("nodes", [])
	if not (nodes is Array) or nodes.is_empty():
		return "Encounter '%s' has no scenes" % encounter_id
	var node_ids: Dictionary = {}
	for node_value: Variant in nodes:
		if not (node_value is Dictionary):
			return "Encounter '%s' has an invalid scene" % encounter_id
		var node_id := str(node_value.get("id", ""))
		if node_id.is_empty() or node_ids.has(node_id):
			return "Encounter '%s' scene IDs must be unique" % encounter_id
		node_ids[node_id] = true
	if not node_ids.has(str(encounter.get("entryNodeId", ""))):
		return "Encounter '%s' entry scene is unavailable" % encounter_id
	for node_value: Variant in nodes:
		for choice_value: Variant in node_value.get("choices", []):
			if not (choice_value is Dictionary):
				return "Encounter '%s' has an invalid choice" % encounter_id
			var destination := _optional_id(choice_value.get("nextNodeId"))
			if not destination.is_empty() and not node_ids.has(destination):
				return "Encounter '%s' choice destination is unavailable" % encounter_id
	return ""


static func _optional_id(value: Variant) -> String:
	return str(value) if value is String else ""


static func _semantic_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
