extends RefCounted


func step(_event: Dictionary, state: Dictionary, _context) -> Dictionary:
	ClassDB.instantiate("Node")
	return {"state": state, "result": {"kind": "continue"}}
