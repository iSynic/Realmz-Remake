extends RefCounted


func step(_event: Dictionary, state: Dictionary, _context) -> Dictionary:
	FileAccess.open("C:/Windows/win.ini", FileAccess.READ)
	return {"state": state, "result": {"kind": "continue"}}
