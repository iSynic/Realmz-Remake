class_name DefaultScenarioPorts
extends RefCounted

const RouterScript = preload(
	"res://scripts/scenario_runtime/scenario_command_router.gd"
)
const MapPortScript = preload(
	"res://scripts/scenario_runtime/ports/map_port.gd"
)
const CombatPortScript = preload(
	"res://scripts/scenario_runtime/ports/combat_port.gd"
)
const InventoryPortScript = preload(
	"res://scripts/scenario_runtime/ports/inventory_port.gd"
)
const CharacterPortScript = preload(
	"res://scripts/scenario_runtime/ports/character_port.gd"
)
const PresentationPortScript = preload(
	"res://scripts/scenario_runtime/ports/presentation_port.gd"
)
const PersistencePortScript = preload(
	"res://scripts/scenario_runtime/ports/persistence_port.gd"
)
const CapabilityCatalogScript = preload(
	"res://scripts/scenario_runtime/scenario_capability_catalog.gd"
)


static func create(
	port_runtime: Object,
	gameplay_rule_set: GameplayRuleSet = null
) -> Dictionary:
	var router := RouterScript.new()
	for port: ScenarioCommandPort in [
		MapPortScript.new(),
		CombatPortScript.new(),
		InventoryPortScript.new(),
		CharacterPortScript.new(),
		PresentationPortScript.new(),
		PersistencePortScript.new(),
	]:
		if not router.register_port(port):
			return {"status": "error", "message": router.last_error}
	router.configure({
		"scenarioPortRuntime": port_runtime,
		"commandRouter": router,
		"gameplayRules": gameplay_rule_set,
	})
	var contract_result := router.validate_service_contracts()
	if str(contract_result.get("status", "")) != "ok":
		return contract_result
	var ownership_result := _validate_capability_ownership(router)
	if str(ownership_result.get("status", "")) != "ok":
		return ownership_result
	return {"status": "ok", "router": router}


static func _validate_capability_ownership(
	router: ScenarioCommandRouter
) -> Dictionary:
	var catalog := CapabilityCatalogScript.new()
	if not catalog.load_builtin():
		return {"status": "error", "message": catalog.last_error}
	for operation_id: Variant in catalog.operation_ids():
		var operation: Dictionary = catalog.operation(str(operation_id))
		var command_id := str(operation.get("commandId", ""))
		if command_id.is_empty():
			continue
		var port := router.port_for_command(command_id)
		if port == null:
			return {
				"status": "error",
				"message": "Scenario API operation '%s' has no command owner"
					% operation_id,
			}
		var expected_port := str(operation.get("owningPort", ""))
		if port.port_id() != expected_port:
			return {
				"status": "error",
				"message": (
					"Scenario API operation '%s' routes through '%s', not '%s'"
					% [operation_id, port.port_id(), expected_port]
				),
			}
	return {"status": "ok"}
