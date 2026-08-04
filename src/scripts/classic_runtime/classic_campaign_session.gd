class_name ClassicCampaignSession
extends Node

signal timed_encounter_dispatched(encounter_id: int, trigger_id: String, result: Dictionary)

const InstallScript = preload("res://scripts/classic_runtime/classic_campaign_install.gd")
const HostScript = preload("res://scripts/classic_runtime/classic_runtime_host.gd")
const RuntimeScript = preload("res://scripts/classic_runtime/classic_runtime.gd")
const TimedEncounterSchedulerScript = preload(
	"res://scripts/classic_runtime/classic_timed_encounter_scheduler.gd"
)
const CharacterRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_rules.gd"
)
const GameplayRuleRegistryScript = preload(
	"res://scripts/scenario_runtime/gameplay_rule_registry.gd"
)
const GameplayRuleSetScript = preload(
	"res://scripts/scenario_runtime/gameplay_rule_set.gd"
)
const SAVE_SCHEMA_VERSION := 8
const IMPLEMENTATION_KIND := "scenario-interpreter"

var install: Object
var host: Object
var command_adapter: Object
var timed_encounter_scheduler := TimedEncounterSchedulerScript.new()
var gameplay_rule_registry: GameplayRuleRegistry
var gameplay_rule_set: GameplayRuleSet
var _timed_dispatch_loop_active := false


func load_installed_campaign(
	campaigns_directory: String,
	campaign_name: String,
	adapter: Object,
	prepared_install: Object = null,
	gameplay_rule_selection := {}
) -> Dictionary:
	clear()
	command_adapter = adapter
	if (
		prepared_install != null
		and str(prepared_install.get("campaign_name")) == campaign_name
		and prepared_install.get("bundle") != null
		and str(prepared_install.get("last_error")).is_empty()
	):
		install = prepared_install
	else:
		install = InstallScript.new()
		if not install.load_from_campaigns_directory(campaigns_directory, campaign_name):
			return {"status": "error", "message": install.last_error}
	var item_load_result := _load_installed_item_definitions()
	if str(item_load_result.get("status", "")) == "error":
		return item_load_result
	var rule_result := _resolve_gameplay_rules(gameplay_rule_selection)
	if str(rule_result.get("status", "")) != "ok":
		return rule_result
	host = HostScript.new()
	add_child(host)
	host.configure(self.command_adapter, gameplay_rule_set)
	host.use_campaign(install.bundle)
	host.playthrough_finished.connect(_on_host_playthrough_finished)
	return {
		"status": "ok",
		"campaignDirectory": install.campaign_directory,
		"campaignId": str(install.bundle.manifest.get("id", "")),
		"host": host,
		"gameplayRules": gameplay_rule_set.snapshot(),
	}


func _resolve_gameplay_rules(selection: Variant) -> Dictionary:
	if not (selection is Dictionary):
		return _error("Gameplay rule selection must be a dictionary")
	gameplay_rule_registry = GameplayRuleRegistryScript.new()
	if not gameplay_rule_registry.load_builtin_catalog():
		return _error(gameplay_rule_registry.last_error)
	var runtime_document: Dictionary = install.bundle.documents.get("runtime", {})
	var preset_id := str(
		selection.get(
			"presetId",
			runtime_document.get("recommendedGameplayProfile", "core.classic")
		)
	)
	var overrides: Variant = selection.get("domains", {})
	if not (overrides is Dictionary):
		return _error("Gameplay rule domain selection must be a dictionary")
	var result := gameplay_rule_registry.resolve(preset_id, overrides)
	if str(result.get("status", "")) != "ok":
		return result
	gameplay_rule_set = result["ruleset"]
	return {"status": "ok"}


func _load_installed_item_definitions() -> Dictionary:
	var main_loop := Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return {"status": "skipped"}
	var resources: Node = main_loop.root.get_node_or_null("Main/Resources")
	if resources == null or not resources.has_method("load_item_resources"):
		return {"status": "skipped"}
	var item_directory: String = install.campaign_directory.path_join("Items") + "/"
	if not FileAccess.file_exists(item_directory.path_join("stuff_book.json")):
		return {"status": "skipped"}
	var campaign_id := str(install.bundle.manifest.get("id", "")).strip_edges()
	if campaign_id.is_empty():
		return _error("Classic campaign manifest has no item catalog identity")
	if resources.has_method("is_campaign_package_active") and bool(
		resources.call(
			"is_campaign_package_active",
			str(install.campaign_name),
			str(install.bundle.package_hash()),
			campaign_id,
		)
	):
		return {"status": "ok", "cacheStatus": "memory"}
	if not resources.load_item_resources(item_directory, campaign_id, true):
		return _error("Classic campaign item definitions could not be loaded")
	return {"status": "ok"}


func activate_start_location(force_reload := false) -> Dictionary:
	if not is_instance_valid(host):
		return {"status": "error", "message": "Classic campaign runtime is not loaded"}
	var result: Variant = host.activate_start_location(force_reload)
	var normalized: Dictionary = result if result is Dictionary else {
		"status": "error",
		"message": "Classic campaign start returned an invalid result",
	}
	if str(normalized.get("status", "")) != "error":
		_drain_timed_encounter_scans()
		host.call_deferred("emit_lifecycle_event", "map-enter", {
			"event": "map-enter",
			"location": install.bundle.start_location().duplicate(true),
		})
	return normalized


func apply_character_rules(party: Array) -> Dictionary:
	if install == null or install.bundle == null:
		return {"status": "error", "message": "Classic campaign runtime is not loaded"}
	return CharacterRulesScript.apply_party(install.bundle, party)


func on_native_time_advanced(
	previous_time: int,
	current_time: int,
	native_location: Dictionary = {}
) -> Dictionary:
	if not is_instance_valid(host) or host.runtime == null:
		return _error("Classic campaign runtime is not loaded")
	if gameplay_rule_set != null and not bool(
		gameplay_rule_set.options("mapTime").get("timedEncounters", true)
	):
		return {
			"status": "ok",
			"queuedDays": 0,
			"dispatched": 0,
			"disabledByGameplayRules": true,
		}
	var defer_dispatch := bool(native_location.get("deferDispatch", false))
	var location := native_location.duplicate(true)
	location.erase("deferDispatch")
	if not location.is_empty():
		var location_result := sync_native_location(location)
		if str(location_result.get("status", "")) == "error":
			return location_result

	var runtime_state: Object = host.runtime.runtime_state
	var queued_days := 0
	if current_time > previous_time:
		for scenario_day: int in timed_encounter_scheduler.crossed_days(
			previous_time,
			current_time
		):
			if runtime_state.enqueue_timed_encounter_day(scenario_day):
				queued_days += 1
	if not defer_dispatch and (
		queued_days > 0 or not runtime_state.pending_timed_encounter_scan().is_empty()
	):
		_drain_timed_encounter_scans()
	host.call_deferred("emit_lifecycle_event", "time-advanced", {
		"event": "time-advanced",
		"previousTime": previous_time,
		"currentTime": current_time,
		"elapsedSeconds": maxi(0, current_time - previous_time),
		"location": location,
	})
	return {
		"status": "ok",
		"queuedDays": queued_days,
		"deferred": defer_dispatch,
	}


func _drain_timed_encounter_scans() -> void:
	if _timed_dispatch_loop_active \
			or not is_instance_valid(host) \
			or host.runtime == null \
			or host.active \
			or host.has_restored_continuation():
		return
	_timed_dispatch_loop_active = true
	var runtime_state: Object = host.runtime.runtime_state
	while not runtime_state.pending_timed_encounter_scan().is_empty():
		if host.active or host.has_restored_continuation():
			break
		var pending_scan: Dictionary = runtime_state.pending_timed_encounter_scan()
		var scan_result: Dictionary = timed_encounter_scheduler.scan_day(
			install.bundle,
			runtime_state,
			int(pending_scan.get("day", -1)),
			int(pending_scan.get("nextIndex", 0)),
			Callable(self, "_party_has_timed_item"),
			Callable(self, "_resolve_rule_modifier_value")
		)
		if str(scan_result.get("status", "")) == "error":
			push_error(str(scan_result.get("message", "Classic timed-encounter scan failed")))
			runtime_state.finish_pending_timed_encounter_day()
			continue
		runtime_state.set_pending_timed_encounter_index(
			int(scan_result.get("nextIndex", 0))
		)
		if bool(scan_result.get("complete", false)):
			runtime_state.finish_pending_timed_encounter_day()
			continue

		var dispatch: Dictionary = scan_result.get("dispatch", {})
		var encounter_id := int(dispatch.get("encounterId", -1))
		var trigger_id := str(dispatch.get("triggerId", ""))
		var trigger_result := {}
		if trigger_id.is_empty() or not host.has_trigger(trigger_id):
			trigger_result = _error(
				"Timed encounter %d references missing trigger '%s'" % [
					encounter_id,
					trigger_id,
				]
			)
		else:
			trigger_result = await host.run_trigger(
				trigger_id,
				0,
				{
					"scenarioDay": int(dispatch.get("scenarioDay", -1)),
					"timedEncounterId": encounter_id,
				}
			)
		timed_encounter_dispatched.emit(encounter_id, trigger_id, trigger_result)
		if str(trigger_result.get("status", "")) == "error":
			push_error(str(trigger_result.get(
				"message",
				"Classic timed encounter %d stopped" % encounter_id
			)))
		# Resume after the macro so opcode 54 can alter a later record in this scan.
	_timed_dispatch_loop_active = false


func _resolve_rule_modifier_value(
	event_id: String,
	base_value: float,
	context: Dictionary
) -> float:
	if not is_instance_valid(host) or not host.has_method("resolve_rule_modifiers"):
		return base_value
	var result: Variant = host.call(
		"resolve_rule_modifiers",
		event_id,
		base_value,
		context
	)
	if not (result is Dictionary) or str(result.get("status", "")) != "ok":
		var message := (
			str(result.get("message", ""))
			if result is Dictionary else ""
		)
		push_error(
			message if not message.is_empty()
			else "Scenario rule modifier '%s' failed" % event_id
		)
		return base_value
	return float(result.get("value", base_value))


func _party_has_timed_item(item_id: int) -> bool:
	if command_adapter == null or not command_adapter.has_method("classic_party_has_item"):
		return false
	var item_texts: Array = []
	if install != null and install.bundle != null:
		var item_text: Dictionary = install.bundle.get_item_text(item_id)
		if not item_text.is_empty():
			item_texts.append(item_text)
	var result: Variant = command_adapter.call(
		"classic_party_has_item",
		item_id,
		item_texts
	)
	return result is Dictionary \
		and str(result.get("status", "")) != "error" \
		and bool(result.get("possessed", false))


func _on_host_playthrough_finished(_result: Dictionary) -> void:
	if not _timed_dispatch_loop_active:
		call_deferred("_drain_timed_encounter_scans")


func make_save_payload() -> Dictionary:
	var result := make_save_result()
	return result.get("payload", {}) if str(result.get("status", "")) == "ok" else {}


func validate_save_point() -> Dictionary:
	if not is_instance_valid(host) or host.runtime == null:
		return _error("Classic campaign runtime is not loaded")
	if (
		host.active
		and gameplay_rule_set != null
		and not bool(
			gameplay_rule_set.options("persistence").get("continuationSaves", true)
		)
	):
		return _error(
			"The selected gameplay rules require finishing the current scenario action before saving"
		)
	var result: Dictionary = host.make_continuation_snapshot()
	return {"status": "ok"} if str(result.get("status", "")) == "ok" else result


func make_save_result() -> Dictionary:
	if not is_instance_valid(host) or host.runtime == null:
		return _error("Classic campaign runtime is not loaded")
	var runtime_state: Object = host.runtime.runtime_state
	if runtime_state == null or not runtime_state.has_method("snapshot"):
		return _error("Classic campaign runtime state is unavailable")
	var continuation_result: Dictionary = host.make_continuation_snapshot()
	if str(continuation_result.get("status", "")) != "ok":
		return continuation_result
	var port_state: Dictionary = host.snapshot_port_state()
	var mixed_state: Dictionary = host.runtime.interpreter.mixed_execution_state()
	return {
		"status": "ok",
		"payload": {
			"schemaVersion": SAVE_SCHEMA_VERSION,
			"campaignId": _campaign_id(),
			"campaignKind": _campaign_kind(),
			"implementationKind": IMPLEMENTATION_KIND,
			"campaignContentVersion": _campaign_content_version(),
			"campaignPackageHash": _campaign_package_hash(),
			"scriptApiVersions": {"scenarioScripts": 3},
			"scenarioScriptContract": _scenario_script_contract(),
			"requiredPlugins": _required_plugins(),
			"runtimeState": runtime_state.call("snapshot"),
			"portState": port_state,
			"continuationState": continuation_result["snapshot"],
			"enhancedTriggerState": host.snapshot_enhanced_trigger_state(),
			"activeSemanticReplacements": _active_semantic_replacements(),
			"activeResponseRef": mixed_state.get("activeResponseRef"),
			"activeResultRef": mixed_state.get("activeResultRef"),
			"mixedSequenceCursor": mixed_state.get("mixedSequenceCursor", {}),
			"resultTransitionCount": int(mixed_state.get("resultTransitionCount", 0)),
			"attachmentOrder": mixed_state.get("attachmentOrder", []),
			"gameplayRules": gameplay_rule_set.snapshot(),
		},
	}


func restore_save_payload(payload: Dictionary) -> Dictionary:
	var prepared_result := _prepare_save_payload(payload)
	if str(prepared_result.get("status", "")) != "ok":
		return prepared_result
	var prepared_payload: Dictionary = prepared_result["payload"]
	var validation := validate_save_payload(
		prepared_payload,
		_campaign_id(),
		_campaign_package_hash(),
		_scenario_script_contract(),
		_campaign_kind()
	)
	if str(validation.get("status", "")) != "ok":
		return validation
	if not is_instance_valid(host) or host.runtime == null:
		return _error("Classic campaign runtime is not loaded")
	var rules_restore := gameplay_rule_registry.restore(prepared_payload["gameplayRules"])
	if str(rules_restore.get("status", "")) != "ok":
		return rules_restore
	gameplay_rule_set = rules_restore["ruleset"]
	host.cancel_pending_campaign_start()
	var previous_enhanced_trigger_state: Dictionary = (
		host.snapshot_enhanced_trigger_state()
	)
	host.configure(command_adapter, gameplay_rule_set)
	var runtime_state: Object = host.runtime.runtime_state
	var previous_runtime_state: Dictionary = runtime_state.call("snapshot")
	var previous_continuation_result: Dictionary = host.make_continuation_snapshot()
	if str(previous_continuation_result.get("status", "")) != "ok":
		return previous_continuation_result
	var previous_port_state: Dictionary = host.snapshot_port_state()
	runtime_state.call("restore", prepared_payload["runtimeState"])
	var enhanced_result: Dictionary = host.restore_enhanced_trigger_state(
		prepared_payload.get("enhancedTriggerState", {})
	)
	if str(enhanced_result.get("status", "")) == "error":
		_rollback_restore(
			runtime_state,
			previous_runtime_state,
			previous_port_state,
			previous_continuation_result["snapshot"],
			previous_enhanced_trigger_state
		)
		return enhanced_result
	var port_result: Dictionary = host.restore_port_state(
		prepared_payload.get("portState", {})
	)
	if str(port_result.get("status", "")) == "error":
		_rollback_restore(
			runtime_state,
			previous_runtime_state,
			previous_port_state,
			previous_continuation_result["snapshot"],
			previous_enhanced_trigger_state
		)
		return port_result
	var continuation_state: Dictionary = prepared_payload.get("continuationState", {
		"schemaVersion": RuntimeScript.CONTINUATION_SCHEMA_VERSION,
		"state": "idle",
	})
	var continuation_result: Dictionary = host.restore_continuation(continuation_state)
	if str(continuation_result.get("status", "")) != "ok":
		_rollback_restore(
			runtime_state,
			previous_runtime_state,
			previous_port_state,
			previous_continuation_result["snapshot"],
			previous_enhanced_trigger_state
		)
	if str(continuation_result.get("status", "")) == "ok":
		host.call_deferred("emit_lifecycle_event", "campaign-resume", {
			"event": "campaign-resume",
			"migrated": bool(prepared_result.get("migrated", false)),
		})
	return continuation_result


func _prepare_save_payload(payload: Dictionary) -> Dictionary:
	var prepared := payload.duplicate(true)
	if str(prepared.get("campaignPackageHash", "")) == _campaign_package_hash():
		return {"status": "ok", "payload": prepared}
	if str(prepared.get("campaignId", "")) != _campaign_id():
		return {
			"status": "ok",
			"payload": prepared,
		}
	var from_version := str(prepared.get("campaignContentVersion", ""))
	var to_version := _campaign_content_version()
	if from_version.is_empty() or to_version.is_empty() \
			or from_version == to_version:
		return _error(
			"Classic save belongs to a different build of this campaign"
		)
	if not is_instance_valid(host) \
			or host.runtime == null \
			or host.runtime.interpreter == null \
			or host.runtime.interpreter.scenario_script_runtime == null:
		return _error("Scenario state migration runtime is unavailable")
	var continuation: Variant = prepared.get("continuationState", {})
	if not (continuation is Dictionary):
		return _error("Scenario state migration requires a valid continuation")
	var migrated_result: Dictionary = (
		host.runtime.interpreter.scenario_script_runtime.migrate_snapshot(
			continuation.get("scenarioScriptRuntime", {}),
			from_version,
			to_version
		)
	)
	if str(migrated_result.get("status", "")) != "ok":
		return _error(
			"Campaign update cannot restore this save: %s" % migrated_result.get(
				"message",
				"state migration failed"
			)
		)
	var migrated_snapshot: Dictionary = migrated_result["snapshot"]
	continuation["scenarioScriptRuntime"] = migrated_snapshot
	if str(continuation.get("state", "")) == "suspended":
		var execution_state: Variant = continuation.get("executionState", {})
		if not (execution_state is Dictionary):
			return _error(
				"Scenario update cannot migrate an invalid suspended continuation"
			)
		execution_state["scenarioScriptRuntime"] = migrated_snapshot
		continuation["executionState"] = execution_state
	prepared["continuationState"] = continuation
	prepared["campaignContentVersion"] = to_version
	prepared["campaignPackageHash"] = _campaign_package_hash()
	prepared["campaignKind"] = _campaign_kind()
	prepared["implementationKind"] = IMPLEMENTATION_KIND
	prepared["scenarioScriptContract"] = _scenario_script_contract()
	prepared["activeSemanticReplacements"] = _active_semantic_replacements()
	prepared["requiredPlugins"] = _required_plugins()
	return {
		"status": "ok",
		"payload": prepared,
		"migrated": true,
		"fromContentVersion": from_version,
		"toContentVersion": to_version,
	}


func _rollback_restore(
	runtime_state: Object,
	previous_runtime_state: Dictionary,
	previous_port_state: Dictionary,
	previous_continuation_state: Dictionary,
	previous_enhanced_trigger_state: Dictionary
) -> void:
	runtime_state.call("restore", previous_runtime_state)
	host.restore_port_state(previous_port_state)
	host.restore_continuation(previous_continuation_state)
	host.restore_enhanced_trigger_state(previous_enhanced_trigger_state)


func has_pending_continuation() -> bool:
	return is_instance_valid(host) and host.has_restored_continuation()


func resume_saved_continuation() -> Dictionary:
	if not is_instance_valid(host):
		return _error("Classic campaign runtime is not loaded")
	return host.resume_restored_continuation()


func restore_legacy_native_location(_location: Dictionary) -> Dictionary:
	return _error(
		"This save predates the current scenario runtime and cannot be upgraded; "
		+ "start a new playthrough"
	)


func sync_native_location(location: Dictionary) -> Dictionary:
	if not is_instance_valid(host) or host.runtime == null:
		return _error("Classic campaign runtime is not loaded")
	var map_name := str(location.get("mapName", ""))
	var level_type := ""
	var level_text := ""
	if map_name.begins_with("mapd_"):
		level_type = "dungeon"
		level_text = map_name.trim_prefix("mapd_")
	elif map_name.begins_with("map_"):
		level_type = "land"
		level_text = map_name.trim_prefix("map_")
	if level_type.is_empty() or not level_text.is_valid_int():
		return _error("Older Classic save has an unrecognized map '%s'" % map_name)
	host.runtime.runtime_state.set_location(
		level_type,
		int(level_text),
		int(location.get("x", 0)),
		int(location.get("y", 0))
	)
	return {"status": "ok"}


func acquired_player_map_entries() -> Array:
	if not is_instance_valid(host) or host.runtime == null \
			or install == null or install.bundle == null:
		return []
	var runtime_state: Object = host.runtime.runtime_state
	if runtime_state == null or not runtime_state.has_method("is_map_owned"):
		return []
	var map_ids: Array = install.bundle.player_maps_by_id.keys()
	map_ids.sort()
	var entries: Array = []
	for map_id_value: Variant in map_ids:
		var map_id := int(map_id_value)
		if not runtime_state.call("is_map_owned", map_id):
			continue
		var map_record: Dictionary = install.bundle.get_player_map(map_id)
		if map_record.is_empty():
			continue
		var runtime_path := ""
		if command_adapter != null and command_adapter.has_method("runtime_media_path"):
			runtime_path = str(command_adapter.call("runtime_media_path", map_record, "image/"))
		var current_position := {
			"levelType": str(runtime_state.get("level_type")),
			"levelIndex": int(runtime_state.get("level_index")),
			"x": int(runtime_state.get("x")),
			"y": int(runtime_state.get("y")),
		}
		entries.append({
			"record": map_record.duplicate(true),
			"runtimeMediaPath": runtime_path,
			"nativeMapName": "%s_%d" % [
				"mapd" if bool(map_record.get("isDungeon", false)) else "map",
				int(map_record.get("level", 0)),
			],
			"currentPosition": current_position,
		})
	return entries


static func validate_save_payload(
	payload: Variant,
	expected_campaign_id := "",
	expected_package_hash := "",
	expected_script_contract := {},
	expected_campaign_kind := ""
) -> Dictionary:
	if payload is Dictionary and payload.is_empty():
		return _error(
			"This save predates the current scenario runtime and cannot be upgraded; "
			+ "start a new playthrough"
		)
	if not (payload is Dictionary):
		return _error("Classic save data is not a dictionary")
	if not payload.has("schemaVersion"):
		return _error("Classic save data has no schema version")
	var version := int(payload.get("schemaVersion", 0))
	if version != SAVE_SCHEMA_VERSION:
		return _error(
			(
				"Save schema %d is incompatible with scenario runtime schema %d; "
				+ "start a new playthrough"
			) % [
				version,
				SAVE_SCHEMA_VERSION,
			]
		)
	if not expected_campaign_id.is_empty():
		var saved_campaign_id := str(payload.get("campaignId", ""))
		if saved_campaign_id != expected_campaign_id:
			return _error(
				"Classic save belongs to campaign '%s', not '%s'" % [
					saved_campaign_id,
					expected_campaign_id,
				]
			)
	var saved_campaign_kind := str(payload.get("campaignKind", ""))
	if saved_campaign_kind not in [
		"classic-interpreted",
		"classic-enhanced",
		"remake-authored",
	]:
		return _error("Scenario save has an unsupported campaign kind")
	if not expected_campaign_kind.is_empty() \
			and saved_campaign_kind != expected_campaign_kind:
		return _error(
			"Scenario save belongs to campaign kind '%s', not '%s'" % [
				saved_campaign_kind,
				expected_campaign_kind,
			]
		)
	if str(payload.get("implementationKind", "")) != IMPLEMENTATION_KIND:
		return _error("Scenario save has an incompatible interpreter implementation")
	if not expected_package_hash.is_empty():
		var saved_package_hash := str(payload.get("campaignPackageHash", ""))
		if saved_package_hash != expected_package_hash:
			return _error(
				"Classic save belongs to a different build of this campaign"
			)
	var script_versions: Variant = payload.get("scriptApiVersions")
	if not (script_versions is Dictionary) \
			or int(script_versions.get("scenarioScripts", 0)) != 3:
		return _error("Scenario script save API is unavailable or incompatible")
	var saved_script_contract: Variant = payload.get("scenarioScriptContract")
	if not (saved_script_contract is Dictionary):
		return _error("Scenario script save contract is missing")
	if not (expected_script_contract as Dictionary).is_empty() \
			and saved_script_contract != expected_script_contract:
		return _error(
			"Scenario scripts or their state schemas changed; start a new playthrough"
		)
	if not (payload.get("runtimeState") is Dictionary):
		return _error("Classic save data has no runtime state")
	if not (payload.get("portState") is Dictionary):
		return _error("Scenario runtime save data has invalid port state")
	if not (payload.get("enhancedTriggerState") is Dictionary):
		return _error("Scenario runtime save data has invalid Enhanced trigger state")
	if not (payload.get("activeSemanticReplacements") is Array):
		return _error("Scenario runtime save data has invalid semantic replacements")
	if payload.get("activeResponseRef") != null \
			and not (payload.get("activeResponseRef") is Dictionary):
		return _error("Scenario runtime save data has an invalid active response")
	if payload.get("activeResultRef") != null \
			and not (payload.get("activeResultRef") is Dictionary):
		return _error("Scenario runtime save data has an invalid active result")
	if not (payload.get("mixedSequenceCursor") is Dictionary):
		return _error("Scenario runtime save data has an invalid mixed-sequence cursor")
	var transition_count: Variant = payload.get("resultTransitionCount")
	if not _is_nonnegative_integer_number(transition_count):
		return _error("Scenario runtime save data has an invalid result transition count")
	if not (payload.get("attachmentOrder") is Array):
		return _error("Scenario runtime save data has an invalid attachment order")
	var continuation_value: Variant = payload.get("continuationState")
	var continuation_result: Dictionary = RuntimeScript.validate_continuation_snapshot(
		continuation_value
	)
	if str(continuation_result.get("status", "")) != "ok":
		return continuation_result
	if str(continuation_value.get("state", "")) == "suspended" \
			and not (continuation_value.get("commandContext", {}) is Dictionary):
		return _error("Classic continuation has an invalid command context")
	var gameplay_rule_validation := GameplayRuleSetScript.validate_snapshot(
		payload.get("gameplayRules")
	)
	if not bool(gameplay_rule_validation.get("valid", false)):
		return _error(str(gameplay_rule_validation.get(
			"message",
			"Saved gameplay rules are invalid"
		)))
	return {"status": "ok"}


static func _is_nonnegative_integer_number(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number := float(value)
	return number >= 0.0 and number == floorf(number)


func _campaign_id() -> String:
	if install == null or install.bundle == null:
		return ""
	return str(install.bundle.manifest.get("id", ""))


func _campaign_kind() -> String:
	if install == null or install.bundle == null:
		return ""
	return str(install.bundle.manifest.get("campaignKind", ""))


func _active_semantic_replacements() -> Array:
	if install == null or install.bundle == null:
		return []
	var logic: Variant = install.bundle.documents.get("remakeLogic", {})
	if not (logic is Dictionary):
		return []
	var replacements: Variant = logic.get("replacements", [])
	return replacements.duplicate(true) if replacements is Array else []


func _campaign_package_hash() -> String:
	if install == null or install.bundle == null:
		return ""
	return install.bundle.package_hash()


func _campaign_content_version() -> String:
	if install == null or install.bundle == null:
		return ""
	return str(install.bundle.manifest.get(
		"contentVersion",
		install.bundle.manifest.get("version", "")
	))


func _required_plugins() -> Array:
	if install == null or install.bundle == null:
		return []
	var runtime_document: Variant = install.bundle.documents.get("runtime", {})
	if not (runtime_document is Dictionary):
		return []
	var requirements: Variant = runtime_document.get("requiredPlugins", [])
	return requirements.duplicate(true) if requirements is Array else []


func _scenario_script_contract() -> Dictionary:
	if install == null or install.bundle == null:
		return {}
	var document: Variant = install.bundle.documents.get("remakeScripts", {})
	if not (document is Dictionary):
		return {}
	var behaviors: Array[Dictionary] = []
	for behavior_value: Variant in document.get("behaviors", []):
		if not (behavior_value is Dictionary):
			continue
		behaviors.append({
			"id": str(behavior_value.get("id", "")),
			"role": str(behavior_value.get("role", "")),
			"hook": str(behavior_value.get("hook", "")),
			"tier": str(behavior_value.get("tier", "")),
			"apiVersion": int(behavior_value.get("apiVersion", 0)),
			"behaviorVersion": int(behavior_value.get("behaviorVersion", 0)),
			"stateSchemaVersion": int(
				behavior_value.get("stateSchemaVersion", 0)
			),
			"contentHash": str(behavior_value.get("contentHash", "")),
			"stateSchemaHash": str(
				behavior_value.get("stateSchemaHash", "")
			),
		})
	behaviors.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return left["id"] < right["id"]
	)
	var state_definitions: Array = document.get(
		"stateDefinitions",
		[]
	).duplicate(true)
	state_definitions.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return (
			"%s:%s:%s" % [
				left.get("scope", ""),
				left.get("ownerId", ""),
				left.get("name", ""),
			]
			<
			"%s:%s:%s" % [
				right.get("scope", ""),
				right.get("ownerId", ""),
				right.get("name", ""),
			]
		)
	)
	return {
		"capabilityCatalogHash": str(document.get("capabilityCatalogHash", "")),
		"behaviors": behaviors,
		"stateDefinitions": state_definitions,
		"migrations": document.get("migrations", []).duplicate(true),
		"requiredPlugins": _required_plugins(),
	}


static func _error(message: String) -> Dictionary:
	return {"status": "error", "message": message}


func clear() -> void:
	_timed_dispatch_loop_active = false
	if is_instance_valid(host):
		host.queue_free()
	host = null
	install = null
	command_adapter = null
	gameplay_rule_registry = null
	gameplay_rule_set = null
