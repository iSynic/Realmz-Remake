extends SceneTree

const API_VERSION := 1
const MAX_SOURCE_BYTES := 1048576
const MAX_STATE_BYTES := 262144
const MAX_MESSAGE_BYTES := 1048576
const MAX_DEPTH := 16
const DENIED_TOKENS := [
	"@tool",
	"FileAccess",
	"DirAccess",
	"ResourceLoader",
	"ResourceSaver",
	"GDExtension",
	"JavaScriptBridge",
	"OS.",
	"ClassDB",
	"Engine.",
	"Thread",
	"WorkerThreadPool",
	"TCPServer",
	"StreamPeerTCP",
	"PacketPeerUDP",
	"HTTPRequest",
	"WebSocketPeer",
]

var package_root := ""
var package_hash := ""
var nonce := ""
var instances: Dictionary = {}


func _init() -> void:
	if not _read_arguments():
		_emit({"status": "error", "message": "Sandbox runner arguments are invalid"})
		quit(2)
		return
	while true:
		var line := OS.read_string_from_stdin()
		if line.is_empty():
			quit()
			return
		if line.to_utf8_buffer().size() > MAX_MESSAGE_BYTES:
			_emit({"status": "error", "message": "Sandbox request is too large"})
			continue
		var request: Variant = JSON.parse_string(line)
		if not (request is Dictionary):
			_emit({"status": "error", "message": "Sandbox request must be JSON"})
			continue
		match str(request.get("type", "")):
			"handshake":
				_emit({
					"status": (
						"ok"
						if int(request.get("protocolVersion", 0)) == API_VERSION
							and str(request.get("nonce", "")) == nonce
						else "error"
					),
					"protocolVersion": API_VERSION,
					"packageHash": package_hash,
				})
			"step":
				_emit(_step(request))
			"stop":
				_emit({"status": "ok"})
				quit()
				return
			_:
				_emit({"status": "error", "message": "Sandbox request type is unsupported"})


func _step(request: Dictionary) -> Dictionary:
	var script: Variant = request.get("script", {})
	var event: Variant = request.get("event", {})
	var state: Variant = request.get("state", {})
	if not (script is Dictionary) or not (event is Dictionary) \
			or not _is_json_value(state):
		return {"status": "error", "message": "Sandbox step payload is invalid"}
	var instance_result := _instance_for(script)
	if str(instance_result.get("status", "")) == "error":
		return instance_result
	var context := SandboxContext.new()
	context.configure(script.get("capabilities", []))
	var returned: Variant = instance_result["instance"].call(
		"step",
		event.duplicate(true),
		state.duplicate(true) if state is Dictionary or state is Array else state,
		context
	)
	if not (returned is Dictionary):
		return {"status": "error", "message": "Sandbox reducer must return an object"}
	var next_state: Variant = returned.get("state", {})
	var result: Variant = returned.get("result", {})
	if not _is_json_value(next_state) \
			or JSON.stringify(next_state).to_utf8_buffer().size() > MAX_STATE_BYTES:
		return {"status": "error", "message": "Sandbox state exceeds JSON limits"}
	if not (result is Dictionary) or not _is_json_value(result):
		return {"status": "error", "message": "Sandbox reducer result is invalid"}
	return {
		"status": "ok",
		"state": next_state,
		"result": result,
	}


func _instance_for(script: Dictionary) -> Dictionary:
	var script_id := str(script.get("id", ""))
	if instances.has(script_id):
		return {"status": "ok", "instance": instances[script_id]}
	if int(script.get("apiVersion", 0)) != API_VERSION:
		return {"status": "error", "message": "Sandbox script API is unsupported"}
	var source_path := str(script.get("sourcePath", "")).replace("\\", "/")
	if not source_path.begins_with("remake/source/") \
			or not source_path.ends_with(".gd") \
			or source_path.contains("..") \
			or source_path.contains(":"):
		return {"status": "error", "message": "Sandbox source path is invalid"}
	var absolute_path := package_root.path_join(source_path)
	var source_bytes := FileAccess.get_file_as_bytes(absolute_path)
	if source_bytes.is_empty() or source_bytes.size() > MAX_SOURCE_BYTES:
		return {"status": "error", "message": "Sandbox source is unavailable or too large"}
	if _sha256(source_bytes) != str(script.get("contentHash", "")).to_lower():
		return {"status": "error", "message": "Sandbox source hash changed"}
	var source := source_bytes.get_string_from_utf8()
	for denied: String in DENIED_TOKENS:
		if source.contains(denied):
			return {
				"status": "error",
				"message": "Sandbox source contains denied API token '%s'" % denied,
			}
	var compiled := GDScript.new()
	compiled.source_code = source
	var compile_error := compiled.reload()
	if compile_error != OK:
		return {
			"status": "error",
			"message": "Sandbox script did not compile (%s)" % error_string(compile_error),
		}
	var instance: Object = compiled.new()
	if instance == null or not instance.has_method("step"):
		return {"status": "error", "message": "Sandbox script has no step reducer"}
	instances[script_id] = instance
	return {"status": "ok", "instance": instance}


func _read_arguments() -> bool:
	var arguments := OS.get_cmdline_user_args()
	for index: int in range(arguments.size() - 1):
		match arguments[index]:
			"--package-root":
				package_root = arguments[index + 1]
			"--package-hash":
				package_hash = arguments[index + 1]
			"--nonce":
				nonce = arguments[index + 1]
	return DirAccess.dir_exists_absolute(package_root) \
		and package_hash.length() == 64 \
		and nonce.length() == 64


func _emit(value: Dictionary) -> void:
	print(JSON.stringify(value))


static func _sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


static func _is_json_value(value: Variant, depth := 0) -> bool:
	if depth > MAX_DEPTH:
		return false
	if value == null or value is bool or value is int or value is float or value is String:
		return true
	if value is Array:
		for child: Variant in value:
			if not _is_json_value(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not (key is String) or not _is_json_value(value[key], depth + 1):
				return false
		return true
	return false


class SandboxContext:
	extends RefCounted

	var capabilities: Dictionary = {}

	func configure(values: Array) -> void:
		capabilities.clear()
		for value: Variant in values:
			capabilities[str(value)] = true

	func command(capability: String, arguments := {}) -> Dictionary:
		if not capabilities.has(capability):
			return {
				"kind": "error",
				"message": "Undeclared sandbox capability '%s'" % capability,
			}
		return {
			"kind": "yield",
			"capability": capability,
			"arguments": (
				arguments.duplicate(true) if arguments is Dictionary else {}
			),
		}

	func continued(value: Variant = null) -> Dictionary:
		return {"kind": "continue", "value": value}

	func halted(value: Variant = null) -> Dictionary:
		return {"kind": "halt", "value": value}

	func failed(message: String) -> Dictionary:
		return {"kind": "error", "message": message}
