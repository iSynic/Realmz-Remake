extends RefCounted


func step(_event: Dictionary, state: Dictionary, _context) -> Dictionary:
	load("res://not-authorized.gd")
	return {"state": state, "result": {"kind": "continue"}}
