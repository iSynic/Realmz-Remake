class_name ScenarioGodotDomainService
extends RefCounted

var service_owner: Object


func configure(owner: Object) -> void:
	service_owner = owner


func scenario_service_contract_version() -> int:
	if service_owner == null \
			or not service_owner.has_method("scenario_service_contract_version"):
		return 0
	return int(service_owner.call("scenario_service_contract_version"))


func prepare_scenario_command(command_id: String) -> void:
	if service_owner != null \
			and service_owner.has_method("prepare_scenario_command"):
		service_owner.call("prepare_scenario_command", command_id)


func _autoload(autoload_name: String) -> Node:
	if service_owner == null:
		return null
	return service_owner.call("_autoload", autoload_name)


func _campaign_resources() -> Node:
	if service_owner == null:
		return null
	return service_owner.call("_classic_campaign_resources")


func _classic_runtime_state() -> Object:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return null
	var session: Variant = game_global.get("classic_campaign_session")
	if not is_instance_valid(session):
		return null
	var host: Variant = session.get("host")
	if not is_instance_valid(host):
		return null
	var runtime: Variant = host.get("runtime")
	if runtime == null:
		return null
	return runtime.get("runtime_state")


func _emit_lifecycle_event(hook: String, request := {}) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null \
			or not game_global.has_method("emit_classic_lifecycle_event"):
		return {"status": "ok", "handled": false}
	var result: Variant = await game_global.call(
		"emit_classic_lifecycle_event",
		hook,
		request
	)
	return result if result is Dictionary else _error(
		"Scenario lifecycle event returned an invalid response"
	)


func _text_rect() -> Object:
	if service_owner == null:
		return null
	return service_owner.call("_text_rect")


func _picture_rect() -> Object:
	if service_owner == null:
		return null
	return service_owner.call("_picture_rect")


func _error(message: String) -> Dictionary:
	return {
		"status": "error",
		"message": message,
	}
