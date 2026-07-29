class_name ScenarioRuleModifierPipeline
extends RefCounted

const FAMILIES := [
	"attack-chance",
	"damage",
	"healing",
	"spell-cost",
	"movement-cost",
	"fatigue",
	"experience",
	"loot",
	"encounter-chance",
	"rest-recovery",
	"time-advance",
	"condition-resistance",
]

var behavior_runner: Object
var extension_registry: ScenarioExtensionRegistry
var runtime_bindings: Dictionary = {}


func configure(
	runner: Object,
	registry: ScenarioExtensionRegistry,
	bindings: Dictionary
) -> void:
	behavior_runner = runner
	extension_registry = registry
	runtime_bindings = bindings.duplicate(true)


func resolve(event_id: String, base_value: float, context := {}) -> Dictionary:
	if event_id not in FAMILIES:
		return _error("Unknown scenario rule-modifier family '%s'" % event_id)
	var event_context: Dictionary = (
		context.duplicate(true) if context is Dictionary else {}
	)
	var current := base_value
	var applied: Array = []
	var extension_group: Variant = runtime_bindings.get("ruleModifiers", {})
	if extension_group is Dictionary:
		var extension_keys: Array = extension_group.keys()
		extension_keys.sort()
		for key_value: Variant in extension_keys:
			var binding_value: Variant = extension_group[key_value]
			if not (binding_value is Dictionary) \
					or str(binding_value.get("kind", "")) != "extension":
				continue
			var provider_id := str(binding_value.get("providerId", ""))
			if extension_registry == null:
				return _error("Scenario rule extension registry is unavailable")
			var extension_result := extension_registry.invoke_binding(
				"gameplayRuleProviders",
				provider_id,
				{
					"event": event_id,
					"baseValue": base_value,
					"currentValue": current,
					"context": event_context,
				},
				self
			)
			var applied_result := _apply_result(
				current,
				extension_result,
				event_context
			)
			if str(applied_result.get("status", "")) != "ok":
				return applied_result
			current = float(applied_result["value"])
			applied.append({
				"kind": "extension",
				"id": provider_id,
				"value": current,
			})
	if behavior_runner != null \
			and behavior_runner.has_method("run_behavior_attachments_pure"):
		var attachment_result: Dictionary = behavior_runner.call(
			"run_behavior_attachments_pure",
			"rule-modifier",
			event_id,
			"rule",
			[event_id],
			{
				"event": event_id,
				"baseValue": base_value,
				"currentValue": current,
				"context": event_context,
				"pure": true,
			}
		)
		if str(attachment_result.get("status", "")) == "error":
			return attachment_result
		for result_value: Variant in attachment_result.get("results", []):
			if not (result_value is Dictionary):
				return _error("Scenario rule modifier returned an invalid result")
			var applied_result := _apply_result(
				current,
				result_value.get("value"),
				event_context
			)
			if str(applied_result.get("status", "")) != "ok":
				return applied_result
			current = float(applied_result["value"])
			applied.append({"kind": "scenario", "value": current})
	var minimum := float(event_context.get("minimum", -INF))
	var maximum := float(event_context.get("maximum", INF))
	if minimum > maximum:
		return _error("Scenario rule modifier received invalid clamp bounds")
	current = clampf(current, minimum, maximum)
	return {
		"status": "ok",
		"event": event_id,
		"baseValue": base_value,
		"value": current,
		"applied": applied,
	}


func _apply_result(
	current: float,
	result_value: Variant,
	context: Dictionary
) -> Dictionary:
	if result_value is Dictionary and str(result_value.get("status", "")) == "error":
		return result_value
	var value: Variant = (
		result_value.get("value")
		if result_value is Dictionary and result_value.has("value")
		else result_value
	)
	if value == null:
		return {"status": "ok", "value": current}
	if value is int or value is float:
		var replacement := float(value)
		return (
			{"status": "ok", "value": replacement}
			if is_finite(replacement)
			else _error("Scenario rule modifier returned a non-finite value")
		)
	if not (value is Dictionary):
		return _error("Scenario rule modifier must return a number or modifier object")
	var modifier: Dictionary = value
	var next := (
		(current + float(modifier.get("add", 0.0)))
		* float(modifier.get("multiply", 1.0))
	)
	if modifier.has("minimum"):
		next = maxf(next, float(modifier["minimum"]))
	if modifier.has("maximum"):
		next = minf(next, float(modifier["maximum"]))
	if not is_finite(next):
		return _error("Scenario rule modifier produced a non-finite value")
	return {
		"status": "ok",
		"value": clampf(
			next,
			float(context.get("minimum", -INF)),
			float(context.get("maximum", INF))
		),
	}


func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
