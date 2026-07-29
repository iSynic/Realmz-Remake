extends RefCounted


func step(event: Dictionary, state: Dictionary, context) -> Dictionary:
	var next_state := state.duplicate(true)
	next_state["steps"] = int(next_state.get("steps", 0)) + 1
	if event.get("kind") == "invoke":
		return {
			"state": next_state,
			"result": context.command(
				"core.presentation.text",
				{"text": "Sandbox fixture"}
			),
		}
	return {
		"state": next_state,
		"result": context.continued(next_state["steps"]),
	}
