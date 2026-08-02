class_name ScenarioScriptHandler
extends ScenarioInstructionHandler


func handler_id() -> String:
	return "core.script"


func semantic_operations() -> PackedStringArray:
	return PackedStringArray(["core.script.call"])


func execute(instruction: Dictionary, context: Object) -> ScenarioStepResult:
	if context == null or not context.has_method("execute_scenario_script"):
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	var parameters: Variant = instruction.get("parameters", {})
	if not (parameters is Dictionary):
		return ScenarioStepResult.failed("core.script.call parameters must be an object")
	var attachment: Dictionary = (
		parameters.get("attachment", {}).duplicate(true)
		if parameters.get("attachment") is Dictionary
		else {}
	)
	var invocation_context := {
		"role": str(attachment.get("role", "action")),
		"hook": str(attachment.get("hook", "run")),
		"trigger": context.current_trigger_identity()
			if context.has_method("current_trigger_identity") else {},
		"action": instruction.duplicate(true),
	}
	var execution_context: Variant = invocation_context["trigger"].get(
		"executionContext",
		{}
	)
	if execution_context is Dictionary:
		for key: Variant in execution_context:
			if not invocation_context.has(key):
				invocation_context[key] = execution_context[key]
	if not attachment.is_empty():
		invocation_context["attachment"] = attachment
		var attachment_request: Variant = attachment.get("request")
		if attachment_request is Dictionary:
			invocation_context["request"] = attachment_request.duplicate(true)
	var arguments: Variant = parameters.get("arguments", {})
	if parameters.has("argumentBindings"):
		if not context.has_method("resolve_scenario_behavior_arguments"):
			return ScenarioStepResult.failed(
				"Scenario behavior argument resolver is unavailable"
			)
		var resolved: Dictionary = context.call(
			"resolve_scenario_behavior_arguments",
			parameters.get("argumentBindings", {}),
			invocation_context
		)
		if str(resolved.get("status", "")) != "ok":
			return ScenarioStepResult.failed(str(resolved.get(
				"message",
				"Scenario behavior arguments are invalid"
			)))
		arguments = resolved.get("arguments", {})
	var result: ScenarioStepResult = context.call(
		"execute_scenario_script",
		str(parameters.get("behaviorId", parameters.get("scriptId", ""))),
		arguments,
		invocation_context
	)
	return _apply_behavior_outcome(
		result,
		str(attachment.get("role", "action")),
		attachment
	)


func resume(
	_pending: ScenarioPendingCommand,
	response: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if context == null or not context.has_method("resume_scenario_script"):
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	var result: ScenarioStepResult = context.call(
		"resume_scenario_script",
		response
	)
	return _apply_behavior_outcome(
		result,
		str(_pending.action_identity.get("attachmentRole", "action")),
		(
			_pending.action_identity.get("attachment", {}).duplicate(true)
			if _pending.action_identity.get("attachment") is Dictionary else {}
		)
	)


func _apply_behavior_outcome(
	result: ScenarioStepResult,
	role: String,
	attachment := {}
) -> ScenarioStepResult:
	if role not in ["action", "encounter"]:
		return result
	if result == null or result.kind != ScenarioStepResult.CONTINUE:
		return result
	var value: Variant = result.data.get("value")
	if not (value is Dictionary):
		return result
	var outcome: Dictionary = value
	if role == "encounter":
		return _apply_encounter_outcome(outcome, attachment)
	match str(outcome.get("kind", "continue")):
		"continue":
			return ScenarioStepResult.continued()
		"halt":
			return ScenarioStepResult.halted(outcome)
		"call":
			var call_target := str(outcome.get("triggerId", ""))
			if call_target.is_empty():
				return ScenarioStepResult.failed(
					"Action behavior call outcome requires a trigger ID"
				)
			return ScenarioStepResult.called(
				call_target,
				int(outcome.get("actionIndex", 0))
			)
		"replace":
			var replace_target := str(outcome.get("triggerId", ""))
			if replace_target.is_empty():
				return ScenarioStepResult.failed(
					"Action behavior replace outcome requires a trigger ID"
				)
			return ScenarioStepResult.replaced(
				replace_target,
				int(outcome.get("actionIndex", 0))
			)
		"return":
			return ScenarioStepResult.returned()
	return ScenarioStepResult.failed(
		"Action behavior returned an unsupported outcome"
	)


func _apply_encounter_outcome(
	outcome: Dictionary,
	attachment: Dictionary
) -> ScenarioStepResult:
	var kind := str(outcome.get("kind", "continue"))
	if kind == "continue":
		return ScenarioStepResult.continued()
	var targets: Variant = attachment.get("outcomeTargets", {})
	if not (targets is Dictionary):
		return ScenarioStepResult.failed(
			"Encounter behavior has no control-flow targets"
		)
	if kind in ["close", "resolve", "repeat"]:
		var target_key := "close" if kind in ["close", "resolve"] else "repeat"
		if not targets.has(target_key):
			return ScenarioStepResult.failed(
				"Encounter behavior outcome '%s' is unavailable here" % kind
			)
		return ScenarioStepResult.branched(int(targets[target_key]))
	if kind == "branch":
		var section_id := str(outcome.get("sectionId", ""))
		var sections: Variant = attachment.get("sectionTargets", {})
		if section_id.is_empty() or not (sections is Dictionary) \
				or not sections.has(section_id):
			return ScenarioStepResult.failed(
				"Encounter branch outcome requires a valid section ID"
			)
		return ScenarioStepResult.branched(int(sections[section_id]))
	return ScenarioStepResult.failed(
		"Encounter behavior returned an unsupported outcome"
	)
