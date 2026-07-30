extends RefCounted


func step(_event: Dictionary, state: Dictionary, context) -> Dictionary:
	return {
		"state": state,
		"result": context.command("core.inventory.wealth"),
	}
