class_name ScenarioPreviewHost
extends Node

const PROTOCOL_VERSION := 1
const InstallScript = preload(
	"res://scripts/classic_runtime/classic_campaign_install.gd"
)
const MapMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_map_materializer.gd"
)
const ItemMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_item_materializer.gd"
)
const BestiaryMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_bestiary_materializer.gd"
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
var _preview_watches: Array[String] = []


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
		"set-watches":
			var watch_result := _set_preview_watches(message.get("watches", []))
			_respond(request_id, watch_result)
		"capture-screenshot":
			call_deferred("_capture_screenshot", request_id)
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
	var materialize_result := _materialize_preview_runtime(
		install.bundle,
		normalized
	)
	if str(materialize_result.get("status", "")) != "ok":
		_respond(request_id, materialize_result)
		return
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


func _materialize_preview_runtime(bundle: Object, directory: String) -> Dictionary:
	var materializers := [
		{
			"name": "maps",
			"instance": MapMaterializerScript.new(),
		},
		{
			"name": "items",
			"instance": ItemMaterializerScript.new(),
		},
		{
			"name": "bestiary",
			"instance": BestiaryMaterializerScript.new(),
		},
	]
	for descriptor: Dictionary in materializers:
		var materializer: Object = descriptor["instance"]
		var result: Dictionary = materializer.materialize(bundle, directory)
		if str(result.get("status", "")) != "ok":
			return {
				"status": "error",
				"message": "Preview %s could not be generated: %s" % [
					descriptor["name"],
					materializer.last_error,
				],
			}
	return {"status": "ok"}


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
	var fixture_result := await _apply_preview_fixture(fixture)
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
	elif kind in [
		"encounter",
		"spell",
		"item",
		"monster",
		"lifecycle",
		"rule",
	]:
		var normalized_entry := _normalized_role_entry(entry)
		if str(normalized_entry.get("status", "")) == "error":
			_launching = false
			_respond(request_id, normalized_entry)
			return
		call_deferred("_run_preview_role", normalized_entry)
	else:
		_launching = false
		_respond(request_id, {
			"status": "error",
			"message": "Preview entry kind '%s' is unavailable" % kind,
		})
		return
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
	var watch_result := _set_preview_watches(fixture.get("watches", []))
	if str(watch_result.get("status", "")) == "error":
		return watch_result
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
	var location_value: Variant = fixture.get("location")
	if location_value is Dictionary:
		var location: Dictionary = location_value
		var teleport_result: Dictionary = await session.host.command_router.route(
			"teleport",
			{
				"levelType": str(location.get("levelType", "land")),
				"levelIndex": int(location.get("levelIndex", 0)),
				"x": int(location.get("x", 0)),
				"y": int(location.get("y", 0)),
				"source": "providence-preview-profile",
			}
		)
		if str(teleport_result.get("status", "")) == "error":
			return teleport_result
	return {
		"status": "ok",
		"profileId": str(fixture.get("profileId", "")),
		"gameplayProfile": str(fixture.get("gameplayProfile", "core.classic")),
	}


func _set_preview_watches(watches_value: Variant) -> Dictionary:
	if not (watches_value is Array) or watches_value.size() > 64:
		return {
			"status": "error",
			"message": "Preview watches must be an array of at most 64 paths",
		}
	var next: Array[String] = []
	for watch_value: Variant in watches_value:
		if not (watch_value is String):
			return {
				"status": "error",
				"message": "Preview watch paths must be strings",
			}
		var path := str(watch_value).strip_edges()
		if path.is_empty() or path.length() > 160:
			return {
				"status": "error",
				"message": "Preview watch path is empty or too long",
			}
		if path not in next:
			next.append(path)
	_preview_watches = next
	return {
		"status": "ok",
		"watches": _watch_report(),
	}


func _capture_screenshot(request_id: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		_respond(request_id, {
			"status": "error",
			"message": "Remake could not capture the preview window",
		})
		return
	var maximum_width := 1024
	var maximum_height := 720
	if image.get_width() > maximum_width or image.get_height() > maximum_height:
		var scale := minf(
			float(maximum_width) / float(image.get_width()),
			float(maximum_height) / float(image.get_height())
		)
		image.resize(
			maxi(1, int(round(float(image.get_width()) * scale))),
			maxi(1, int(round(float(image.get_height()) * scale))),
			Image.INTERPOLATE_LANCZOS
		)
	var bytes := image.save_jpg_to_buffer(0.86)
	var encoded := Marshalls.raw_to_base64(bytes)
	if encoded.length() > 800_000:
		bytes = image.save_jpg_to_buffer(0.68)
		encoded = Marshalls.raw_to_base64(bytes)
	if encoded.length() > 800_000:
		_respond(request_id, {
			"status": "error",
			"message": "Preview screenshot exceeded the protocol size limit",
		})
		return
	_respond(request_id, {
		"status": "ok",
		"screenshot": {
			"mimeType": "image/jpeg",
			"base64": encoded,
			"width": image.get_width(),
			"height": image.get_height(),
		},
	})


static func _apply_optional_stat(
	source: Dictionary,
	stats: Dictionary,
	source_key: String,
	stat_key: String
) -> void:
	if source.has(source_key) and source.get(source_key) != null:
		stats[stat_key] = int(source[source_key])


func _run_preview_trigger(trigger_id: String, slot: int) -> void:
	var debug_result := _prepare_debugger_for_entry()
	if str(debug_result.get("status", "")) != "ok":
		_send({
			"type": "runtime-error",
			"message": debug_result.get("message", "Scenario debugger is unavailable"),
		})
		return
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
	var debug_result := _prepare_debugger_for_entry()
	if str(debug_result.get("status", "")) != "ok":
		_send({
			"type": "runtime-error",
			"message": debug_result.get("message", "Scenario debugger is unavailable"),
		})
		return
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


func _run_preview_role(entry: Dictionary) -> void:
	var debug_result := _prepare_debugger_for_entry()
	if str(debug_result.get("status", "")) != "ok":
		_send({
			"type": "runtime-error",
			"message": debug_result.get("message", "Scenario debugger is unavailable"),
		})
		return
	var role := str(entry.get("role", ""))
	var hook := str(entry.get("hook", ""))
	var result := {}
	if role == "rule-modifier":
		result = session.host.resolve_rule_modifiers(
			hook,
			float(entry.get("baseValue", 50.0)),
			_preview_role_request(entry)
		)
	elif role == "lifecycle" and str(entry.get("behaviorId", "")).is_empty():
		result = await session.host.emit_lifecycle_event(
			hook,
			_preview_role_request(entry)
		)
	else:
		result = await session.host.run_behavior_binding(
			str(entry.get("behaviorId", "")),
			role,
			hook,
			str(entry.get("targetKind", "")),
			str(entry.get("recordId", "")),
			int(entry.get("slot", -1)),
			_preview_role_request(entry)
		)
	_send({
		"type": "runtime-event",
		"event": "%s-preview-finished" % role,
		"entry": entry,
		"result": result,
		"trace": _vm_trace(),
		"debugger": _debugger_snapshot(),
		"state": _state_summary(),
		"assertions": _assertion_report(),
	})


func _normalized_role_entry(entry: Dictionary) -> Dictionary:
	var result := entry.duplicate(true)
	var kind := str(result.get("kind", ""))
	var role := str(result.get("role", _role_for_entry_kind(kind)))
	var behavior_id := str(result.get("behaviorId", ""))
	var document: Dictionary = install.bundle.documents.get("remakeScripts", {})
	var selected_binding := {}
	for binding_value: Variant in document.get("bindings", []):
		if not (binding_value is Dictionary):
			continue
		var binding: Dictionary = binding_value
		if not behavior_id.is_empty() \
				and str(binding.get("behaviorId", "")) != behavior_id:
			continue
		if not role.is_empty() and str(binding.get("role", "")) != role:
			continue
		selected_binding = binding
		break
	if selected_binding.is_empty():
		return {
			"status": "error",
			"message": (
				"Preview behavior '%s' has no %s binding"
				% [behavior_id, role]
			),
		}
	result["status"] = "ok"
	result["behaviorId"] = str(selected_binding.get("behaviorId", behavior_id))
	result["role"] = str(selected_binding.get("role", role))
	for field: String in ["hook", "targetKind", "recordId"]:
		if str(result.get(field, "")).is_empty():
			result[field] = str(selected_binding.get(field, ""))
	var slot_value: Variant = result.get("slot")
	if slot_value == null:
		slot_value = selected_binding.get("slot", -1)
	result["slot"] = int(slot_value)
	if result["hook"].is_empty() \
			or result["targetKind"].is_empty() \
			or result["recordId"].is_empty():
		return {
			"status": "error",
			"message": "Preview behavior binding is incomplete",
		}
	return result


func _preview_role_request(entry: Dictionary) -> Dictionary:
	var role := str(entry.get("role", ""))
	var record_id := str(entry.get("recordId", ""))
	var context: Dictionary = (
		entry.get("context", {}).duplicate(true)
		if entry.get("context", {}) is Dictionary else {}
	)
	var party := _preview_party_summary()
	var request := {
		"source": "providence-preview",
		"preview": true,
		"slot": int(entry.get("slot", -1)),
		"recordId": record_id,
		"party": party,
		"world": {
			"location": _current_location(),
			"totalSeconds": int(GameGlobal.time),
			"questValues": _preview_quest_values(),
		},
		"context": context,
	}
	match role:
		"encounter":
			request.merge({
				"encounterId": record_id,
				"encounterKind": str(entry.get(
					"targetKind",
					"simpleEncounter"
				)),
				"outcome": int(context.get("outcome", 1)),
				"response": context.get("response", {}),
			}, true)
		"spell":
			var caster: Dictionary = party[0] if not party.is_empty() else {}
			var targets: Array = (
				party.slice(1) if party.size() > 1 else [caster]
			)
			request.merge({
				"spell": {
					"ids": [record_id],
					"name": str(context.get("spellName", "Preview Spell")),
					"power": int(context.get("power", 1)),
				},
				"caster": caster,
				"targets": targets,
				"cast": {
					"mode": str(context.get("mode", "field")),
					"preview": true,
				},
			}, true)
		"item":
			var user: Dictionary = party[0] if not party.is_empty() else {}
			request.merge({
				"item": {
					"definitionId": record_id,
					"instanceId": "preview:%s" % record_id,
					"charges": int(context.get("charges", 1)),
					"state": context.get("itemState", {}),
				},
				"definition": {
					"id": record_id,
					"name": str(context.get("itemName", "Preview Item")),
				},
				"user": user,
				"target": user,
				"hook": str(entry.get("hook", "")),
			}, true)
		"monster-ai":
			request.merge({
				"monster": {
					"id": record_id,
					"name": str(context.get("monsterName", "Preview Monster")),
					"health": int(context.get("health", 10)),
					"maximumHealth": int(context.get("maximumHealth", 10)),
					"spellPoints": int(context.get("spellPoints", 0)),
					"maximumSpellPoints": int(context.get("maximumSpellPoints", 0)),
					"position": context.get("position", {"x": 0, "y": 0}),
					"faction": int(context.get("faction", 1)),
					"alive": true,
				},
				"combat": {
					"active": StateMachine.is_combat_state(),
					"party": party,
					"seed": int(context.get("rngSeed", 1)),
				},
			}, true)
		"lifecycle":
			request["event"] = str(entry.get("hook", ""))
		"rule-modifier":
			request.merge({
				"event": str(entry.get("hook", "")),
				"baseValue": float(entry.get("baseValue", 50.0)),
				"currentValue": float(entry.get("baseValue", 50.0)),
				"minimum": float(context.get("minimum", -INF)),
				"maximum": float(context.get("maximum", INF)),
				"pure": true,
			}, true)
	return request


static func _role_for_entry_kind(kind: String) -> String:
	return str({
		"encounter": "encounter",
		"spell": "spell",
		"item": "item",
		"monster": "monster-ai",
		"lifecycle": "lifecycle",
		"rule": "rule-modifier",
	}.get(kind, ""))


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
	var behavior_entries: Dictionary = {
		"action": [],
		"encounter": [],
		"spell": [],
		"item": [],
		"monster-ai": [],
		"lifecycle": [],
		"rule-modifier": [],
		"helper": [],
	}
	var document: Dictionary = install.bundle.documents.get("remakeScripts", {})
	var behaviors_by_id := {}
	for behavior_value: Variant in document.get("behaviors", []):
		if behavior_value is Dictionary:
			behaviors_by_id[str(behavior_value.get("id", ""))] = behavior_value
	for binding_value: Variant in document.get("bindings", []):
		if not (binding_value is Dictionary):
			continue
		var binding: Dictionary = binding_value
		var behavior_id := str(binding.get("behaviorId", ""))
		var behavior: Dictionary = behaviors_by_id.get(behavior_id, {})
		var role := str(binding.get("role", behavior.get("role", "")))
		if not behavior_entries.has(role):
			continue
		behavior_entries[role].append({
			"behaviorId": behavior_id,
			"name": str(behavior.get("name", behavior_id)),
			"hook": str(binding.get("hook", behavior.get("hook", ""))),
			"targetKind": str(binding.get("targetKind", "")),
			"recordId": str(binding.get("recordId", "")),
			"slot": binding.get("slot"),
		})
	for behavior_id: Variant in behaviors_by_id:
		var behavior: Dictionary = behaviors_by_id[behavior_id]
		if str(behavior.get("kind", "")) != "helper":
			continue
		behavior_entries["helper"].append({
			"behaviorId": str(behavior_id),
			"name": str(behavior.get("name", behavior_id)),
		})
	return {
		"start": install.bundle.get_start(),
		"actionPoints": action_points,
		"battles": battles,
		"behaviors": behavior_entries,
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
	summary["watches"] = _watch_report(summary)
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


func _watch_report(state: Dictionary = {}) -> Array:
	var summary := state if not state.is_empty() else _state_without_assertions()
	if not summary.has("debugger"):
		summary["debugger"] = _debugger_snapshot()
	var result: Array = []
	for path: String in _preview_watches:
		var resolved := _value_at_path(summary, path)
		result.append({
			"path": path,
			"found": bool(resolved.get("found", false)),
			"value": resolved.get("value"),
		})
	return result


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


func _prepare_debugger_for_entry() -> Dictionary:
	var result := _configure_scenario_debugger()
	if bool(result.get("deferred", false)):
		return {
			"status": "error",
			"message": "Scenario debugger is not ready for the selected preview entry",
		}
	return result


func _debugger_snapshot() -> Dictionary:
	if not is_instance_valid(session) \
			or session.host == null \
			or session.host.runtime == null \
			or session.host.runtime.interpreter == null \
			or session.host.runtime.interpreter.scenario_script_runtime == null:
		return {"enabled": false, "paused": false}
	return session.host.runtime.interpreter.scenario_script_runtime.debugger_snapshot()


func _current_location() -> Dictionary:
	var x := 0
	var y := 0
	if is_instance_valid(GameGlobal.map):
		var map_character: Variant = GameGlobal.map.get("owcharacter")
		if not is_instance_valid(map_character):
			map_character = GameGlobal.map.get("focuscharacter")
		if is_instance_valid(map_character):
			x = int(map_character.get("tile_position_x"))
			y = int(map_character.get("tile_position_y"))
	return {
		"map": GameGlobal.currentmap_name,
		"x": x,
		"y": y,
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
