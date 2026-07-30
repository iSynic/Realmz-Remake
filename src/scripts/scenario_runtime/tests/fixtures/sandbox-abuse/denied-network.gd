extends RefCounted


func step(_event: Dictionary, state: Dictionary, _context) -> Dictionary:
	var request := HTTPRequest.new()
	return {"state": state, "result": {"kind": "continue", "value": request}}
