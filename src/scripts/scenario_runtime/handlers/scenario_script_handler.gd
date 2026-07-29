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
	var invocation_context := {
		"role": "action",
		"hook": "run",
		"trigger": context.current_trigger_identity()
			if context.has_method("current_trigger_identity") else {},
		"action": instruction.duplicate(true),
	}
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
	return context.call(
		"execute_scenario_script",
		str(parameters.get("behaviorId", parameters.get("scriptId", ""))),
		arguments,
		invocation_context
	)


func resume(
	_pending: ScenarioPendingCommand,
	response: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if context == null or not context.has_method("resume_scenario_script"):
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return context.call("resume_scenario_script", response)
