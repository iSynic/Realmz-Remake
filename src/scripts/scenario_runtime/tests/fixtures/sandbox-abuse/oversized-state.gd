extends RefCounted


func step(_event: Dictionary, state: Dictionary, context) -> Dictionary:
	var next_state := state.duplicate(true)
	next_state["payload"] = "x".repeat(300000)
	return {"state": next_state, "result": context.continued()}
