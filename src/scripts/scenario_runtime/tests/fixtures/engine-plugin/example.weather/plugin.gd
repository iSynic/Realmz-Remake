extends RefCounted


func plugin_id() -> String:
	return "example.weather"


func api_version() -> int:
	return 1


func forecast(request: Dictionary) -> Dictionary:
	return {
		"status": "ok",
		"value": int(request.get("value", 0)) + 1,
	}
