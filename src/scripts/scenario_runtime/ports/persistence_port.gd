class_name PersistencePort
extends ScenarioCommandPort

const COMMANDS := [
	"snapshot_runtime",
	"restore_runtime",
	"complete_campaign",
]

var _router: ScenarioCommandRouter
var _behavior_runner: Object


func port_id() -> String:
	return "core.persistence"


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func save_policy() -> Dictionary:
	return {"state": "aggregate"}


func configure(services: Dictionary) -> void:
	_router = services.get("commandRouter")
	_behavior_runner = services.get("behaviorRunner")


func execute(command_id: String, request: Dictionary) -> Dictionary:
	if _router == null:
		return {"status": "error", "message": "Persistence port is not configured"}
	if command_id == "snapshot_runtime":
		return {"status": "ok", "ports": _router.snapshot_state()}
	if command_id == "restore_runtime":
		var state: Variant = request.get("ports", {})
		if not (state is Dictionary):
			return {"status": "error", "message": "Saved port state must be a dictionary"}
		return _router.restore_state(state)
	if command_id == "complete_campaign":
		if _behavior_runner == null \
				or not _behavior_runner.has_method("complete_campaign"):
			return {
				"status": "error",
				"message": "Scenario campaign-completion runtime is unavailable",
			}
		return await _behavior_runner.call("complete_campaign", request)
	return {"status": "error", "message": "Unsupported persistence command '%s'" % command_id}
