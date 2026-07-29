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
	return context.call(
		"execute_scenario_script",
		str(parameters.get("scriptId", "")),
		parameters.get("arguments", {})
	)


func resume(
	_pending: ScenarioPendingCommand,
	response: Dictionary,
	context: Object
) -> ScenarioStepResult:
	if context == null or not context.has_method("resume_scenario_script"):
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return context.call("resume_scenario_script", response)
