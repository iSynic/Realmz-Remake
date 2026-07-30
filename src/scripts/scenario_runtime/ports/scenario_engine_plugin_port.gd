class_name ScenarioEnginePluginPort
extends ScenarioCommandPort

var plugin_registry: ScenarioEnginePluginRegistry


func bind_registry(registry: ScenarioEnginePluginRegistry) -> void:
	plugin_registry = registry


func configure(services: Dictionary) -> void:
	var registry: Variant = services.get("enginePluginRegistry")
	plugin_registry = registry if registry is ScenarioEnginePluginRegistry else null


func port_id() -> String:
	return "engine.plugins"


func owned_command_ids() -> PackedStringArray:
	if plugin_registry == null:
		return PackedStringArray()
	return PackedStringArray(plugin_registry.command_ids())


func execute(command_id: String, request: Dictionary) -> Dictionary:
	if plugin_registry == null:
		return {
			"status": "error",
			"message": "Scenario engine plug-in registry is unavailable",
		}
	return await plugin_registry.invoke_command(command_id, request)
