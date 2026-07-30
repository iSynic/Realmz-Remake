extends RefCounted


func step(_event: Dictionary, state: Dictionary, _context) -> Dictionary:
	OS.execute("cmd.exe", ["/c", "exit"])
	return {"state": state, "result": {"kind": "continue"}}
