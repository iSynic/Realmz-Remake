class_name ScenarioSandboxClient
extends RefCounted

const PROTOCOL_VERSION := 1
const MAX_MESSAGE_BYTES := 1048576
const MAX_REQUESTS_PER_SCRIPT := 4096

var process: Dictionary = {}
var request_count := 0
var last_error := ""


static func helper_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join(
		"scenario-sandbox-host.exe"
	)


static func feasibility() -> Dictionary:
	if OS.get_name() != "Windows":
		return {
			"available": false,
			"message": "Sandboxed scenario scripts currently require Windows",
		}
	if not FileAccess.file_exists(helper_path()):
		return {
			"available": false,
			"message": "The Windows scenario sandbox host is not installed",
		}
	return {"available": true, "message": ""}


func start(bundle: ClassicCampaignBundle) -> bool:
	close()
	var gate := feasibility()
	if not bool(gate.get("available", false)):
		return _fail(str(gate.get("message", "Scenario sandbox is unavailable")))
	var nonce := Crypto.new().generate_random_bytes(32).hex_encode()
	process = OS.execute_with_pipe(helper_path(), [
		"--protocol", str(PROTOCOL_VERSION),
		"--godot-executable", OS.get_executable_path(),
		"--project-root", ProjectSettings.globalize_path("res://"),
		"--package-root", bundle.root_directory,
		"--package-hash", bundle.package_hash(),
		"--nonce", nonce,
	], false)
	if process.is_empty() or not process.has("stdio"):
		return _fail("Could not start the Windows scenario sandbox host")
	var handshake := _request({
		"type": "handshake",
		"protocolVersion": PROTOCOL_VERSION,
		"nonce": nonce,
	})
	if str(handshake.get("status", "")) != "ok":
		close()
		return _fail(str(handshake.get("message", "Scenario sandbox handshake failed")))
	return true


func step(script: Dictionary, event: Dictionary, state: Variant) -> Dictionary:
	return _request({
		"type": "step",
		"script": {
			"id": script.get("id", ""),
			"sourcePath": script.get("sourcePath", ""),
			"contentHash": script.get("contentHash", ""),
			"apiVersion": script.get("apiVersion", 0),
			"capabilities": script.get("requestedCapabilities", []),
			"stateSchemaHash": script.get("stateSchemaHash", ""),
		},
		"event": event,
		"state": state,
	})


func close() -> void:
	if not process.is_empty():
		var stdio: Variant = process.get("stdio")
		if stdio != null:
			stdio.store_line(JSON.stringify({"type": "stop"}))
	process.clear()
	request_count = 0


func _request(message: Dictionary) -> Dictionary:
	if process.is_empty():
		return {"status": "error", "message": "Scenario sandbox is not running"}
	request_count += 1
	if request_count > MAX_REQUESTS_PER_SCRIPT:
		return {"status": "error", "message": "Scenario sandbox request limit exceeded"}
	var encoded := JSON.stringify(message)
	if encoded.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return {"status": "error", "message": "Scenario sandbox request is too large"}
	var stdio: FileAccess = process.get("stdio")
	stdio.store_line(encoded)
	var response_text := stdio.get_line()
	if response_text.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
		return {"status": "error", "message": "Scenario sandbox response is too large"}
	var parsed: Variant = JSON.parse_string(response_text)
	return (
		parsed
		if parsed is Dictionary
		else {"status": "error", "message": "Scenario sandbox response is invalid"}
	)


func _fail(message: String) -> bool:
	last_error = message
	return false
