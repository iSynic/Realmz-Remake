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
	return _apply_action_outcome(result)


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
	return _apply_action_outcome(result)


func _apply_action_outcome(result: ScenarioStepResult) -> ScenarioStepResult:
	if result == null or result.kind != ScenarioStepResult.CONTINUE:
		return result
	var value: Variant = result.data.get("value")
	if not (value is Dictionary):
		return result
	var outcome: Dictionary = value
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
