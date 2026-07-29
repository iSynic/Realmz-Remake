class_name ScenarioPreviewHost
extends Node

const PROTOCOL_VERSION := 1
const InstallScript = preload(
	"res://scripts/classic_runtime/classic_campaign_install.gd"
)

var socket := WebSocketPeer.new()
var port := 0
var nonce := ""
var package_directory := ""
var profile_root := ""
var install: ClassicCampaignInstall
var campaign_panel: Node
var session: ClassicCampaignSession
var _connected := false
var _launching := false
var _evidence_index: Dictionary = {}


func start_from_command_line() -> bool:
	var arguments := _arguments()
	port = int(arguments.get("--preview-port", 0))
	nonce = str(arguments.get("--preview-nonce", ""))
	package_directory = str(arguments.get("--preview-package", ""))
	profile_root = str(arguments.get("--preview-profile", ""))
	if port <= 0 or nonce.length() < 32 or package_directory.is_empty():
		return false
	if not _prepare_profile():
		return false
	var error := socket.connect_to_url("ws://127.0.0.1:%d" % port)
	if error != OK:
		push_error("Providence preview connection failed: %s" % error_string(error))
		return false
	set_process(true)
	return true


func _process(_delta: float) -> void:
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN and not _connected:
		_connected = true
		_send({
			"type": "handshake",
			"protocolVersion": PROTOCOL_VERSION,
			"nonce": nonce,
			"runtime": "Realmz Remake",
		})
		call_deferred("_load_package", package_directory, "")
	elif state == WebSocketPeer.STATE_CLOSED:
		set_process(false)
		return
	while socket.get_available_packet_count() > 0:
		var packet := socket.get_packet()
		var message: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if message is Dictionary:
			_handle_message(message)


func _handle_message(message: Dictionary) -> void:
	var request_id := str(message.get("requestId", ""))
	match str(message.get("type", "")):
		"ping":
			_respond(request_id, {"status": "ok", "type": "pong"})
		"load-package":
			_load_package(
				str(message.get("packagePath", package_directory)),
				request_id
			)
		"launch-entry":
			if _launching:
				_respond(request_id, {
					"status": "error",
					"message": "A preview launch is already in progress",
				})
			else:
				_launching = true
				_launch_entry(message.get("entry", {}), request_id)
		"vm-trace":
			_respond(request_id, {
				"status": "ok",
				"trace": _vm_trace(),
			})
		"diagnostics":
			_respond(request_id, {
				"status": "ok",
				"readiness": install.selection_rules() if install != null else {},
				"runtimeError": install.last_error if install != null else "Package is not loaded",
			})
		"current-location":
			_respond(request_id, {
				"status": "ok",
				"location": _current_location(),
			})
		"state-summary":
			_respond(request_id, {
				"status": "ok",
				"summary": _state_summary(),
			})
		"stop":
			_respond(request_id, {"status": "ok"})
			get_tree().quit()
		_:
			_respond(request_id, {
				"status": "error",
				"message": "Preview message type is unsupported",
			})


func _load_package(path: String, request_id: String) -> void:
	var normalized := ProjectSettings.globalize_path(path).replace("\\", "/").simplify_path()
	install = InstallScript.new()
	if not install.load_from_campaigns_directory(
		normalized.get_base_dir(),
		normalized.get_file()
	):
		_respond(request_id, {
			"status": "error",
			"message": install.last_error,
		})
		return
	package_directory = normalized
	_evidence_index.clear()
	Paths.campaignsfolderpath = normalized.get_base_dir() + "/"
	GameGlobal.clear_classic_campaign_install_cache(normalized.get_file())
	var rules := install.selection_rules()
	_respond(request_id, {
		"status": "ok",
		"packageHash": install.bundle.package_hash(),
		"campaignId": install.bundle.manifest.get("id", ""),
		"campaignName": install.bundle.manifest.get("name", ""),
		"readiness": rules,
		"entryPoints": _entry_points(),
	})


func _launch_entry(entry_value: Variant, request_id: String) -> void:
	if install == null or not install.last_error.is_empty():
		_launching = false
		_respond(request_id, {"status": "error", "message": "Preview package is not loaded"})
		return
	var rules := install.selection_rules()
	if not bool(rules.get("valid", false)):
		_launching = false
		_respond(request_id, {
			"status": "error",
			"message": rules.get("diagnostic", "Preview package is not ready"),
		})
		return
	var panel_result := await _launch_deterministic_party()
	if str(panel_result.get("status", "")) != "ok":
		_launching = false
		_respond(request_id, panel_result)
		return
	session = GameGlobal.classic_campaign_session
	var entry: Dictionary = entry_value if entry_value is Dictionary else {}
	var kind := str(entry.get("kind", "start"))
	if kind == "ap":
		var trigger_id := str(entry.get("triggerId", ""))
		if trigger_id.is_empty() or not session.host.has_trigger(trigger_id):
			_launching = false
			_respond(request_id, {
				"status": "error",
				"message": "Preview action point is unavailable",
			})
			return
		session.host.command_started.connect(_on_command_started)
		session.host.command_finished.connect(_on_command_finished)
		call_deferred("_run_preview_trigger", trigger_id, int(entry.get("slot", 0)))
	elif kind == "battle":
		var battle_id := int(entry.get("battleId", -1))
		if not install.bundle.battles_by_id.has(battle_id):
			_launching = false
			_respond(request_id, {
				"status": "error",
				"message": "Preview battle is unavailable",
			})
			return
		var battle_result: Dictionary = await session.host.command_router.route("start_battle", {
			"battleId": battle_id,
			"source": "providence-preview",
		})
		if str(battle_result.get("status", "")) == "error":
			_launching = false
			_respond(request_id, battle_result)
			return
	elif kind == "map":
		var teleport_result: Dictionary = await session.host.command_router.route(
			"teleport",
			{
				"levelType": str(entry.get("levelType", "land")),
				"levelIndex": int(entry.get("levelIndex", 0)),
				"x": int(entry.get("x", 0)),
				"y": int(entry.get("y", 0)),
				"source": "providence-preview",
			}
		)
		if str(teleport_result.get("status", "")) == "error":
			_launching = false
			_respond(request_id, teleport_result)
			return
	_respond(request_id, {
		"status": "ok",
		"entry": entry,
		"location": _current_location(),
		"party": GameGlobal.player_characters.map(
			func(character: Variant) -> String: return str(character.get("name"))
		),
	})
	_launching = false


func _launch_deterministic_party() -> Dictionary:
	campaign_panel = UI.main_menu.newCampaignPanel
	UI.main_menu._on_new_campaign_button_pressed()
	await get_tree().process_frame
	var campaign_name := package_directory.get_file()
	var campaign_index := -1
	for index: int in range(campaign_panel.campaignsItemList.item_count):
		var metadata: Variant = campaign_panel.campaignsItemList.get_item_metadata(index)
		if metadata is Dictionary \
				and str(metadata.get("campaignName", "")) == campaign_name:
			campaign_index = index
			break
	if campaign_index < 0:
		return {"status": "error", "message": "Preview campaign was not discovered"}
	campaign_panel.campaignsItemList.select(campaign_index)
	campaign_panel._on_campaign_selected(campaign_index)
	await get_tree().process_frame
	var buttons: Array = campaign_panel.charPickRect.eligibleContainer.get_children()
	for button: Node in buttons:
		var character: Variant = button.get("character")
		if character == null or bool(button.get("disabled")):
			continue
		campaign_panel.charPickRect._on_char_button_pressed(button)
		campaign_panel.charPickRect._on_AddButton_pressed()
		if campaign_panel.pickedparty.size() >= 6:
			break
	if campaign_panel.pickedparty.is_empty() or campaign_panel.startButton.disabled:
		return {"status": "error", "message": "Preview test party could not be admitted"}
	campaign_panel._on_StartButton_pressed()
	for _frame: int in 600:
		if is_instance_valid(GameGlobal.classic_campaign_session) \
				and StateMachine._state_name == "Exploration":
			return {"status": "ok"}
		await get_tree().process_frame
	return {"status": "error", "message": "Preview campaign did not enter exploration"}


func _run_preview_trigger(trigger_id: String, slot: int) -> void:
	var result: Dictionary = await session.host.run_trigger(
		trigger_id,
		slot,
		{"source": "providence-preview"}
	)
	_send({
		"type": "runtime-event",
		"event": "trigger-finished",
		"triggerId": trigger_id,
		"result": result,
		"trace": _vm_trace(),
	})


func _on_command_started(command: String, payload: Dictionary) -> void:
	_send({
		"type": "runtime-event",
		"event": "command-started",
		"command": command,
		"payload": payload,
		"location": _current_location(),
	})


func _on_command_finished(command: String, response: Dictionary) -> void:
	_send({
		"type": "runtime-event",
		"event": "command-finished",
		"command": command,
		"response": response,
		"trace": _vm_trace(),
	})


func _entry_points() -> Dictionary:
	var action_points: Array[Dictionary] = []
	for trigger: Variant in install.bundle.documents.get("scripts", {}).get("triggers", []):
		action_points.append({
			"id": trigger.get("id", ""),
			"coordinate": trigger.get("coordinate", {}),
			"levelType": trigger.get("levelType", ""),
			"levelIndex": trigger.get("levelIndex", 0),
		})
	var battles: Array[Dictionary] = []
	for battle: Variant in install.bundle.documents.get("encounters", {}).get("battles", []):
		battles.append({"id": battle.get("id", 0), "name": battle.get("name", "")})
	return {
		"start": install.bundle.get_start(),
		"actionPoints": action_points,
		"battles": battles,
	}


func _vm_trace() -> Array:
	if not is_instance_valid(session) or session.host == null:
		return []
	var interpreter: Variant = session.host.runtime.interpreter
	if interpreter == null:
		return []
	var result: Array = interpreter.trace.duplicate(true)
	if interpreter.scenario_script_runtime != null:
		result.append_array(
			interpreter.scenario_script_runtime.trace.duplicate(true)
		)
	_load_evidence_index()
	for entry_value: Variant in result:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var action: Variant = entry.get("action", {})
		if action is Dictionary:
			var trigger_id := str(action.get("triggerId", ""))
			var evidence_key := "triggers:%s" % trigger_id
			if _evidence_index.has(evidence_key):
				entry["evidence"] = _evidence_index[evidence_key].duplicate(true)
		var script_id := str(entry.get("scriptId", ""))
		var source_node := str(entry.get("sourceNode", ""))
		if not script_id.is_empty() and not source_node.is_empty():
			var source_location := _script_source_location(script_id, source_node)
			if not source_location.is_empty():
				entry["sourceLocation"] = source_location
	return result


func _load_evidence_index() -> void:
	if not _evidence_index.is_empty() or install == null or install.bundle == null:
		return
	var evidence_path := str(install.bundle.manifest.get("files", {}).get("evidence", ""))
	if evidence_path.is_empty():
		return
	var absolute_path := package_directory.path_join(evidence_path)
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(absolute_path))
	if not (document is Dictionary):
		return
	for record_value: Variant in document.get("recordCatalog", {}).get("records", []):
		if record_value is Dictionary:
			_evidence_index[str(record_value.get("key", ""))] = record_value


func _script_source_location(script_id: String, source_node: String) -> Dictionary:
	var document: Variant = install.bundle.documents.get("remakeScripts", {})
	if not (document is Dictionary):
		return {}
	for script_value: Variant in document.get("scripts", []):
		if not (script_value is Dictionary) or str(script_value.get("id", "")) != script_id:
			continue
		var source_map: Variant = script_value.get("sourceMap", {})
		if not (source_map is Dictionary):
			return {}
		var nodes: Variant = source_map.get("nodes", source_map)
		if nodes is Dictionary and nodes.get(source_node) is Dictionary:
			return nodes[source_node].duplicate(true)
	return {}


func _state_summary() -> Dictionary:
	return {
		"campaignId": (
			install.bundle.manifest.get("id", "") if install != null else ""
		),
		"location": _current_location(),
		"state": StateMachine._state_name,
		"commandPending": (
			session.host.active if is_instance_valid(session) else false
		),
	}


func _current_location() -> Dictionary:
	return {
		"map": GameGlobal.currentmap_name,
		"x": int(GameGlobal.position.x),
		"y": int(GameGlobal.position.y),
	}


func _prepare_profile() -> bool:
	if profile_root.is_empty():
		return false
	Paths.profilesfolderpath = profile_root.path_join("Profiles") + "/"
	Paths.settingspath = profile_root.path_join("override.cfg")
	DirAccess.make_dir_recursive_absolute(Paths.profilesfolderpath)
	var profile_name := "Providence Preview"
	if not DirAccess.dir_exists_absolute(
		Paths.profilesfolderpath.path_join(profile_name)
	):
		if not GameGlobal.create_new_profile(profile_name, false):
			return false
	GameGlobal.set_current_profile(profile_name)
	return true


func _arguments() -> Dictionary:
	var result: Dictionary = {}
	var values := OS.get_cmdline_user_args()
	for index: int in range(values.size() - 1):
		if values[index].begins_with("--preview-"):
			result[values[index]] = values[index + 1]
	return result


func _respond(request_id: String, value: Dictionary) -> void:
	var response := value.duplicate(true)
	response["type"] = "response"
	response["requestId"] = request_id
	_send(response)


func _send(value: Dictionary) -> void:
	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		socket.send_text(JSON.stringify(value))
