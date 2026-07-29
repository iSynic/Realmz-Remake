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
var _debug_breakpoints: Array = []
var _debug_pause_on_start := false
var _preview_assertions: Array = []


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
		"set-breakpoints":
			var breakpoints: Variant = message.get("breakpoints", [])
			if not (breakpoints is Array):
				_respond(request_id, {
					"status": "error",
					"message": "Preview breakpoints must be an array",
				})
			else:
				_debug_breakpoints = breakpoints.duplicate(true)
				_debug_pause_on_start = bool(message.get("pauseOnStart", false))
				_respond(request_id, _configure_scenario_debugger())
		"debug-state":
			_respond(request_id, {
				"status": "ok",
				"debugger": _debugger_snapshot(),
			})
		"debug-command":
			if not is_instance_valid(session) or session.host == null:
				_respond(request_id, {
					"status": "error",
					"message": "Preview scenario runtime is unavailable",
				})
			else:
				_respond(
					request_id,
					session.host.resume_scenario_debugger(
						str(message.get("action", "resume"))
					)
				)
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
	var entry: Dictionary = entry_value if entry_value is Dictionary else {}
	var fixture: Dictionary = (
		entry.get("fixture", {})
		if entry.get("fixture", {}) is Dictionary
		else {}
	)
	var panel_result := await _launch_deterministic_party(fixture)
	if str(panel_result.get("status", "")) != "ok":
		_launching = false
		_respond(request_id, panel_result)
		return
	session = GameGlobal.classic_campaign_session
	var fixture_result := _apply_preview_fixture(fixture)
	if str(fixture_result.get("status", "")) == "error":
		_launching = false
		_respond(request_id, fixture_result)
		return
	_debug_breakpoints = entry.get("breakpoints", []).duplicate(true) \
		if entry.get("breakpoints", []) is Array else []
	_debug_pause_on_start = bool(entry.get("pauseOnStart", false))
	var debug_result := _configure_scenario_debugger()
	if str(debug_result.get("status", "")) == "error":
		_launching = false
		_respond(request_id, debug_result)
		return
	if not session.host.command_started.is_connected(_on_command_started):
		session.host.command_started.connect(_on_command_started)
	if not session.host.command_finished.is_connected(_on_command_finished):
		session.host.command_finished.connect(_on_command_finished)
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
	elif kind == "behavior":
		var behavior_id := str(entry.get("behaviorId", ""))
		if behavior_id.is_empty():
			_launching = false
			_respond(request_id, {
				"status": "error",
				"message": "Preview behavior ID is unavailable",
			})
			return
		call_deferred(
			"_run_preview_behavior",
			behavior_id,
			entry.get("arguments", {}),
			entry.get("context", {})
		)
	_respond(request_id, {
		"status": "ok",
		"entry": entry,
		"location": _current_location(),
		"party": GameGlobal.player_characters.map(
			func(character: Variant) -> String: return str(character.get("name"))
		),
		"fixture": fixture_result,
		"assertions": _assertion_report(),
	})
	_launching = false


func _launch_deterministic_party(fixture: Dictionary = {}) -> Dictionary:
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
	var gameplay_profile := str(
		fixture.get("gameplayProfile", "core.classic")
	).strip_edges()
	if gameplay_profile not in ["core.classic", "core.samuel"]:
		return {
			"status": "error",
			"message": "Preview gameplay profile is unavailable",
		}
	campaign_panel.gameplay_rule_selection = {
		"presetId": gameplay_profile,
		"domains": {},
	}
	var buttons: Array = campaign_panel.charPickRect.eligibleContainer.get_children()
	var configured_party: Array = (
		fixture.get("party", []) if fixture.get("party", []) is Array else []
	)
	var requested_names: Array[String] = []
	for member_value: Variant in configured_party:
		if not (member_value is Dictionary):
			continue
		var member_name := str(member_value.get("name", "")).strip_edges()
		if not member_name.is_empty():
			requested_names.append(member_name)
	if requested_names.is_empty():
		for button: Node in buttons:
			var character: Variant = button.get("character")
			if character == null or bool(button.get("disabled")):
				continue
			campaign_panel.charPickRect._on_char_button_pressed(button)
			campaign_panel.charPickRect._on_AddButton_pressed()
			if campaign_panel.pickedparty.size() >= 6:
				break
	else:
		for requested_name: String in requested_names:
			var selected_button: Node = null
			for button: Node in buttons:
				var character: Variant = button.get("character")
				if character != null \
						and not bool(button.get("disabled")) \
						and str(character.get("name")).nocasecmp_to(
							requested_name
						) == 0:
					selected_button = button
					break
			if selected_button == null:
				return {
					"status": "error",
					"message": (
						"Preview party character '%s' is unavailable"
						% requested_name
					),
				}
			campaign_panel.charPickRect._on_char_button_pressed(selected_button)
			campaign_panel.charPickRect._on_AddButton_pressed()
	if campaign_panel.pickedparty.is_empty() or campaign_panel.startButton.disabled:
		return {"status": "error", "message": "Preview test party could not be admitted"}
	campaign_panel._on_StartButton_pressed()
	for _frame: int in 600:
		if is_instance_valid(GameGlobal.classic_campaign_session) \
				and StateMachine._state_name == "Exploration":
			return {"status": "ok"}
		await get_tree().process_frame
	return {"status": "error", "message": "Preview campaign did not enter exploration"}


func _apply_preview_fixture(fixture: Dictionary) -> Dictionary:
	_preview_assertions = (
		fixture.get("assertions", []).duplicate(true)
		if fixture.get("assertions", []) is Array
		else []
	)
	if fixture.is_empty():
		return {"status": "ok", "profileId": ""}
	var wealth: Dictionary = (
		fixture.get("wealth", {}) if fixture.get("wealth", {}) is Dictionary else {}
	)
	GameGlobal.money_pool = [
		maxi(0, int(wealth.get("gold", 0))),
		maxi(0, int(wealth.get("gems", 0))),
		maxi(0, int(wealth.get("jewelry", 0))),
	]
	GameGlobal.time = maxi(0, int(fixture.get("totalSeconds", 0)))
	if not is_instance_valid(session) \
			or session.host == null \
			or session.host.runtime == null:
		return {"status": "error", "message": "Preview runtime state is unavailable"}
	var runtime_state: Object = session.host.runtime.runtime_state
	for flag_value: Variant in fixture.get("questFlags", []):
		if not (flag_value is Dictionary):
			return {"status": "error", "message": "Preview quest flag is invalid"}
		var quest_id := int(flag_value.get("id", -1))
		if quest_id < 0:
			return {"status": "error", "message": "Preview quest flag ID is invalid"}
		runtime_state.set_quest_value(quest_id, int(flag_value.get("value", 0)))
	var configured_party: Array = (
		fixture.get("party", []) if fixture.get("party", []) is Array else []
	)
	for member_value: Variant in configured_party:
		if not (member_value is Dictionary):
			return {"status": "error", "message": "Preview party override is invalid"}
		var slot := int(member_value.get("slot", -1))
		if slot < 0 or slot >= GameGlobal.player_characters.size():
			return {
				"status": "error",
				"message": "Preview party slot %d is unavailable" % (slot + 1),
			}
		var character: Variant = GameGlobal.player_characters[slot]
		var stats: Variant = character.get("stats")
		if not (stats is Dictionary):
			return {"status": "error", "message": "Preview character stats are unavailable"}
		_apply_optional_stat(member_value, stats, "maximumHealth", "maxHP")
		_apply_optional_stat(member_value, stats, "health", "curHP")
		_apply_optional_stat(member_value, stats, "maximumSpellPoints", "maxSP")
		_apply_optional_stat(member_value, stats, "spellPoints", "curSP")
		if member_value.has("itemIds"):
			var item_ids: Variant = member_value.get("itemIds", [])
			if not (item_ids is Array):
				return {"status": "error", "message": "Preview item IDs are invalid"}
			character.item_inventory.clear()
			var resources: Variant = NodeAccess.__Resources()
			for item_id_value: Variant in item_ids:
				var item_id := int(item_id_value)
				var item: Variant = resources.create_classic_item_instance(item_id)
				if item == null \
						or not character.add_inventory_item(item, -1, true):
					return {
						"status": "error",
						"message": (
							"Preview item %d could not be added to party slot %d"
							% [item_id, slot + 1]
						),
					}
	var script_runtime: Object = (
		session.host.runtime.interpreter.scenario_script_runtime
		if session.host.runtime.interpreter != null
		else null
	)
	if script_runtime != null:
		script_runtime.rng_state = maxi(1, int(fixture.get("rngSeed", 1)))
	return {
		"status": "ok",
		"profileId": str(fixture.get("profileId", "")),
		"gameplayProfile": str(fixture.get("gameplayProfile", "core.classic")),
	}


static func _apply_optional_stat(
	source: Dictionary,
	stats: Dictionary,
	source_key: String,
	stat_key: String
) -> void:
	if source.has(source_key) and source.get(source_key) != null:
		stats[stat_key] = int(source[source_key])


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
		"assertions": _assertion_report(),
	})


func _run_preview_behavior(
	behavior_id: String,
	arguments_value: Variant,
	context_value: Variant
) -> void:
	var arguments: Dictionary = (
		arguments_value if arguments_value is Dictionary else {}
	)
	var context: Dictionary = (
		context_value if context_value is Dictionary else {}
	)
	var result: Dictionary = await session.host.run_bound_behavior(
		behavior_id,
		arguments,
		context
	)
	_send({
		"type": "runtime-event",
		"event": "behavior-finished",
		"behaviorId": behavior_id,
		"result": result,
		"trace": _vm_trace(),
		"debugger": _debugger_snapshot(),
		"assertions": _assertion_report(),
	})


func _on_command_started(command: String, payload: Dictionary) -> void:
	_send({
		"type": "runtime-event",
		"event": "command-started",
		"command": command,
		"payload": payload,
		"location": _current_location(),
		"debugger": _debugger_snapshot(),
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
	for script_value: Variant in document.get("behaviors", []):
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
	var summary := {
		"campaignId": (
			install.bundle.manifest.get("id", "") if install != null else ""
		),
		"location": _current_location(),
		"state": StateMachine._state_name,
		"wealth": {
			"gold": int(GameGlobal.money_pool[0]),
			"gems": int(GameGlobal.money_pool[1]),
			"jewelry": int(GameGlobal.money_pool[2]),
		},
		"totalSeconds": int(GameGlobal.time),
		"party": _preview_party_summary(),
		"questValues": _preview_quest_values(),
		"commandPending": (
			session.host.active if is_instance_valid(session) else false
		),
		"debugger": _debugger_snapshot(),
	}
	summary["assertions"] = _assertion_report(summary)
	return summary


func _preview_party_summary() -> Array:
	var result: Array = []
	for index: int in range(GameGlobal.player_characters.size()):
		var character: Variant = GameGlobal.player_characters[index]
		var stats: Variant = character.get("stats")
		if not (stats is Dictionary):
			stats = {}
		var item_ids: Array = []
		for item_value: Variant in character.get("item_inventory"):
			for item_id: int in NodeAccess.__Resources().item_classic_ids(item_value):
				if item_id not in item_ids:
					item_ids.append(item_id)
		item_ids.sort()
		result.append({
			"slot": index,
			"name": str(character.get("name")),
			"health": int(stats.get("curHP", 0)),
			"maximumHealth": int(stats.get("maxHP", 0)),
			"spellPoints": int(stats.get("curSP", 0)),
			"maximumSpellPoints": int(stats.get("maxSP", 0)),
			"itemIds": item_ids,
		})
	return result


func _preview_quest_values() -> Dictionary:
	if not is_instance_valid(session) \
			or session.host == null \
			or session.host.runtime == null:
		return {}
	var runtime_state: Object = session.host.runtime.runtime_state
	if runtime_state == null or not runtime_state.has_method("snapshot"):
		return {}
	var snapshot: Dictionary = runtime_state.snapshot()
	var values: Variant = snapshot.get("questValues", {})
	return values.duplicate(true) if values is Dictionary else {}


func _assertion_report(state: Dictionary = {}) -> Dictionary:
	var summary := state if not state.is_empty() else _state_without_assertions()
	var checks: Array = []
	var passed := 0
	for assertion_value: Variant in _preview_assertions:
		if not (assertion_value is Dictionary):
			checks.append({"passed": false, "message": "Assertion is invalid"})
			continue
		var assertion: Dictionary = assertion_value
		var path := str(assertion.get("path", "")).strip_edges()
		var actual_result := _value_at_path(summary, path)
		var expected: Variant = JSON.parse_string(str(assertion.get("value", "")))
		if expected == null and str(assertion.get("value", "")) != "null":
			expected = str(assertion.get("value", ""))
		var operator := str(assertion.get("operator", "equals"))
		var actual: Variant = actual_result.get("value")
		var matches := bool(actual_result.get("found", false)) \
			and _assertion_matches(actual, expected, operator)
		if matches:
			passed += 1
		checks.append({
			"path": path,
			"operator": operator,
			"expected": expected,
			"actual": actual,
			"passed": matches,
		})
	return {
		"total": checks.size(),
		"passed": passed,
		"failed": checks.size() - passed,
		"checks": checks,
	}


func _state_without_assertions() -> Dictionary:
	return {
		"campaignId": (
			install.bundle.manifest.get("id", "") if install != null else ""
		),
		"location": _current_location(),
		"state": StateMachine._state_name,
		"wealth": {
			"gold": int(GameGlobal.money_pool[0]),
			"gems": int(GameGlobal.money_pool[1]),
			"jewelry": int(GameGlobal.money_pool[2]),
		},
		"totalSeconds": int(GameGlobal.time),
		"party": _preview_party_summary(),
		"questValues": _preview_quest_values(),
	}


static func _value_at_path(root: Variant, path: String) -> Dictionary:
	if path.is_empty():
		return {"found": false}
	var current: Variant = root
	for segment: String in path.split(".", false):
		if current is Dictionary and current.has(segment):
			current = current[segment]
		elif current is Array and segment.is_valid_int():
			var index := int(segment)
			if index < 0 or index >= current.size():
				return {"found": false}
			current = current[index]
		else:
			return {"found": false}
	return {"found": true, "value": current}


static func _assertion_matches(
	actual: Variant,
	expected: Variant,
	operator: String
) -> bool:
	match operator:
		"equals":
			return actual == expected
		"not-equals":
			return actual != expected
		"at-least":
			return (
				(actual is int or actual is float)
				and (expected is int or expected is float)
				and float(actual) >= float(expected)
			)
		"at-most":
			return (
				(actual is int or actual is float)
				and (expected is int or expected is float)
				and float(actual) <= float(expected)
			)
	return false


func _configure_scenario_debugger() -> Dictionary:
	if not is_instance_valid(session) \
			or session.host == null \
			or session.host.runtime == null \
			or session.host.runtime.interpreter == null \
			or session.host.runtime.interpreter.scenario_script_runtime == null:
		return {"status": "ok", "deferred": true}
	return session.host.runtime.interpreter.scenario_script_runtime.configure_debugger(
		_debug_breakpoints,
		_debug_pause_on_start
	)


func _debugger_snapshot() -> Dictionary:
	if not is_instance_valid(session) \
			or session.host == null \
			or session.host.runtime == null \
			or session.host.runtime.interpreter == null \
			or session.host.runtime.interpreter.scenario_script_runtime == null:
		return {"enabled": false, "paused": false}
	return session.host.runtime.interpreter.scenario_script_runtime.debugger_snapshot()


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
