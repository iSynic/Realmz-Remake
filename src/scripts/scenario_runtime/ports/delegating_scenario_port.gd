class_name DelegatingScenarioPort
extends ScenarioCommandPort

var _port_runtime: Object
var gameplay_rules: GameplayRuleSet
var extension_registry: ScenarioExtensionRegistry
var runtime_bindings: Dictionary = {}
var behavior_runner: Object


func configure(services: Dictionary) -> void:
	_port_runtime = services.get("scenarioPortRuntime")
	if _port_runtime != null \
			and _port_runtime.has_method("scenario_port_runtime"):
		var domain_runtime: Variant = _port_runtime.call(
			"scenario_port_runtime",
			port_id()
		)
		if domain_runtime is Object:
			_port_runtime = domain_runtime
	gameplay_rules = services.get("gameplayRules")
	extension_registry = services.get("extensionRegistry")
	runtime_bindings = services.get("runtimeBindings", {}).duplicate(true)
	behavior_runner = services.get("behaviorRunner")


func rule_option(domain: String, option_id: String, fallback: Variant) -> Variant:
	if gameplay_rules == null:
		return fallback
	return gameplay_rules.options(domain).get(option_id, fallback)


func service_operation(_command_id: String) -> String:
	return ""


func validate_service_contract() -> Dictionary:
	# Focused runtime tests use small command adapters through execute_command().
	# Only the production service opts into the stricter reflected contract.
	if _port_runtime == null \
			or not _port_runtime.has_method("scenario_service_contract_version"):
		return {"status": "ok"}
	var contract_version := int(
		_port_runtime.call("scenario_service_contract_version")
	)
	if contract_version != 1:
		return {
			"status": "error",
			"message": "Scenario port '%s' does not support Godot service contract %d" % [
				port_id(),
				contract_version,
			],
		}
	var methods_by_name: Dictionary = {}
	for method_value: Variant in _port_runtime.get_method_list():
		if method_value is Dictionary:
			methods_by_name[str(method_value.get("name", ""))] = method_value
	for command_id: String in owned_command_ids():
		var operation := service_operation(command_id)
		if operation.is_empty():
			return _service_contract_error(
				command_id,
				"does not declare a Godot service operation"
			)
		if not _port_runtime.has_method(operation):
			return _service_contract_error(
				command_id,
				"requires missing Godot service method '%s'" % operation
			)
		var method: Dictionary = methods_by_name.get(operation, {})
		var arguments: Variant = method.get("args", [])
		if not (arguments is Array) or arguments.size() != 1:
			return _service_contract_error(
				command_id,
				"requires '%s' to accept exactly one request dictionary" % operation
			)
		var request_argument: Variant = arguments[0]
		if request_argument is Dictionary:
			var argument_type := int(request_argument.get("type", TYPE_NIL))
			if argument_type not in [TYPE_NIL, TYPE_DICTIONARY]:
				return _service_contract_error(
					command_id,
					"requires '%s' to accept a request dictionary" % operation
				)
	return {"status": "ok"}


func execute(command_id: String, request: Dictionary) -> Dictionary:
	if _port_runtime == null:
		return {
			"status": "error",
			"message": "Scenario port '%s' is not configured" % port_id(),
		}
	var operation := service_operation(command_id)
	if not operation.is_empty() and _port_runtime.has_method(operation):
		if _port_runtime.has_method("prepare_scenario_command"):
			_port_runtime.call("prepare_scenario_command", command_id)
		return await _port_runtime.call(operation, request)
	# Focused test doubles may still expose the old generic entry point. The
	# production Godot service does not; command ownership remains in the port.
	if _port_runtime.has_method("execute_command"):
		return await _port_runtime.call("execute_command", command_id, request)
	return {
		"status": "error",
		"message": "Scenario port '%s' has no configured Godot service" % port_id(),
	}


func _service_contract_error(command_id: String, detail: String) -> Dictionary:
	return {
		"status": "error",
		"message": "Scenario command '%s' on port '%s' %s" % [
			command_id,
			port_id(),
			detail,
		],
	}


func invoke_runtime_binding(
	binding_group: String,
	capability: String,
	lookup_keys: Array,
	request: Dictionary
) -> Dictionary:
	var group: Variant = runtime_bindings.get(binding_group, {})
	if not (group is Dictionary):
		return {"handled": false}
	for lookup_key_value: Variant in lookup_keys:
		var lookup_key := str(lookup_key_value)
		if lookup_key.is_empty() or not group.has(lookup_key):
			continue
		var binding_value: Variant = group[lookup_key]
		if not (binding_value is Dictionary):
			return {
				"status": "error",
				"handled": true,
				"message": "Scenario runtime binding '%s' is invalid" % lookup_key,
			}
		var binding: Dictionary = binding_value
		var result: Dictionary
		var binding_id := ""
		if str(binding.get("kind", "")) == "script":
			binding_id = str(binding.get("behaviorId", ""))
			if behavior_runner == null \
					or not behavior_runner.has_method("run_bound_behavior"):
				return {
					"status": "error",
					"handled": true,
					"message": "Scenario behavior runner is unavailable",
				}
			result = await behavior_runner.call(
				"run_bound_behavior",
				binding_id,
				request,
				{
					"portId": port_id(),
					"bindingGroup": binding_group,
					"bindingKey": lookup_key,
				}
			)
		elif str(binding.get("kind", "")) == "extension":
			if extension_registry == null:
				return {
					"status": "error",
					"handled": true,
					"message": "Scenario extension registry is unavailable",
				}
			binding_id = str(binding.get("providerId", ""))
			result = extension_registry.invoke_binding(
				capability,
				binding_id,
				request,
				self
			)
		else:
			return {
				"status": "error",
				"handled": true,
				"message": "Scenario runtime binding '%s' has an unknown kind"
					% lookup_key,
			}
		result["handled"] = true
		result["runtimeBinding"] = binding_id
		return result
	return {"handled": false}


func invoke_behavior_attachments(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	request: Dictionary
) -> Dictionary:
	if behavior_runner == null \
			or not behavior_runner.has_method("run_behavior_attachments"):
		return {"handled": false}
	return await behavior_runner.call(
		"run_behavior_attachments",
		role,
		hook,
		target_kind,
		target_ids,
		request
	)


func apply_rule_modifiers(
	event_id: String,
	base_value: float,
	context := {}
) -> Dictionary:
	if behavior_runner == null \
			or not behavior_runner.has_method("resolve_rule_modifiers"):
		return {"status": "ok", "value": base_value, "applied": []}
	return await behavior_runner.call(
		"resolve_rule_modifiers",
		event_id,
		base_value,
		context
	)
