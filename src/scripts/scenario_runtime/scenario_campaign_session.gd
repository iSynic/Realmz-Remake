class_name ScenarioCampaignSession
extends ClassicCampaignSession

const BundleScript = preload(
	"res://scripts/scenario_runtime/scenario_campaign_bundle.gd"
)
const InterpreterScript = preload(
	"res://scripts/scenario_runtime/scenario_interpreter.gd"
)
const RegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_instruction_registry.gd"
)
const HandlerCatalogScript = preload(
	"res://scripts/scenario_runtime/handlers/core_handler_catalog.gd"
)
const DefaultPortsScript = preload(
	"res://scripts/scenario_runtime/default_scenario_ports.gd"
)
const SaveContractScript = preload(
	"res://scripts/scenario_runtime/scenario_save_contract.gd"
)
const SemanticStateScript = preload(
	"res://scripts/scenario_runtime/scenario_semantic_state.gd"
)
const PreviewServicesScript = preload(
	"res://scripts/scenario_runtime/preview/scenario_semantic_preview_services.gd"
)
const SemanticHostScript = preload(
	"res://scripts/scenario_runtime/scenario_semantic_runtime_host.gd"
)

const SUPPORTED_CLASSIC_KINDS := [
	"classic-interpreted",
	"classic-enhanced",
]
const REMAKE_AUTHORED_KIND := "remake-authored"

var semantic_bundle: ScenarioCampaignBundle
var interpreter: ScenarioInterpreter
var command_router: ScenarioCommandRouter
var semantic_state: ScenarioSemanticState
var semantic_services: Object
var triggers_by_id: Dictionary = {}
var encounters_by_id: Dictionary = {}
var event_triggers_by_id: Dictionary = {}
var scheduled_triggers_by_id: Dictionary = {}
var active_trigger_id := ""
var active_encounter_id := ""
var active_trigger_kind := ""
var active_scheduled_marker := -1
var pending_trigger_queue: Array = []
var active_dispatch_count := 0
var semantic_mode := false
var semantic_last_error := ""


static func validate_save_payload(
	payload: Variant,
	expected_campaign_id := "",
	expected_package_hash := "",
	expected_script_contract := {},
	expected_campaign_kind := ""
) -> Dictionary:
	if payload is Dictionary \
			and str(payload.get("campaignKind", "")) == REMAKE_AUTHORED_KIND:
		var validation := SaveContractScript.validate(payload)
		if not bool(validation.get("valid", false)):
			return {
				"status": "error",
				"message": validation.get("message", "Scenario save is invalid"),
			}
		if not expected_campaign_id.is_empty() \
				and str(payload.get("campaignId", "")) != expected_campaign_id:
			return _semantic_static_error(
				"Scenario save belongs to a different campaign"
			)
		if not expected_package_hash.is_empty() \
				and str(payload.get("packageHash", "")) != expected_package_hash:
			return _semantic_static_error(
				"Scenario save belongs to a different campaign package"
			)
		if not expected_campaign_kind.is_empty() \
				and str(payload.get("campaignKind", "")) != expected_campaign_kind:
			return _semantic_static_error(
				"Scenario save belongs to a different campaign kind"
			)
		return {"status": "ok"}
	return ClassicCampaignSession.validate_save_payload(
		payload,
		expected_campaign_id,
		expected_package_hash,
		expected_script_contract,
		expected_campaign_kind
	)


func load_installed_campaign(
	campaigns_directory: String,
	campaign_name: String,
	command_adapter: Object,
	prepared_install: Object = null,
	gameplay_rule_selection := {}
) -> Dictionary:
	var manifest_kind := _installed_campaign_kind(
		campaigns_directory,
		campaign_name
	)
	if manifest_kind == REMAKE_AUTHORED_KIND:
		clear()
		self.command_adapter = command_adapter
		if not _safe_campaign_name(campaign_name):
			return _semantic_error("Campaign name is invalid")
		var loaded_bundle := BundleScript.new()
		var campaign_directory := campaigns_directory.path_join(campaign_name)
		if not loaded_bundle.load_from_directory(campaign_directory):
			return _semantic_error(loaded_bundle.last_error)
		if not configure_remake_bundle(loaded_bundle, command_adapter):
			return _semantic_error(semantic_last_error)
		return {
			"status": "ok",
			"campaignDirectory": loaded_bundle.root_directory,
			"campaignId": str(loaded_bundle.manifest.get("id", "")),
			"campaignKind": REMAKE_AUTHORED_KIND,
			"implementationKind": IMPLEMENTATION_KIND,
			"session": self,
		}

	var result := super.load_installed_campaign(
		campaigns_directory,
		campaign_name,
		command_adapter,
		prepared_install,
		gameplay_rule_selection
	)
	if str(result.get("status", "")) != "ok":
		return result
	var loaded_kind := super._campaign_kind()
	if loaded_kind not in SUPPORTED_CLASSIC_KINDS:
		clear()
		return {
			"status": "error",
			"message": "Campaign kind '%s' has no registered session implementation"
				% loaded_kind,
		}
	if loaded_kind == "classic-enhanced" and host != null:
		event_triggers_by_id = host.enhanced_event_triggers_by_id.duplicate(true)
		scheduled_triggers_by_id = (
			host.enhanced_scheduled_triggers_by_id.duplicate(true)
		)
	result["campaignKind"] = loaded_kind
	result["implementationKind"] = IMPLEMENTATION_KIND
	return result


func configure_remake_bundle(
	campaign_bundle: ScenarioCampaignBundle,
	runtime_services: Object = null
) -> bool:
	clear()
	semantic_mode = true
	semantic_bundle = campaign_bundle
	if semantic_bundle == null \
			or semantic_bundle.campaign_kind() != REMAKE_AUTHORED_KIND:
		return _semantic_fail(
			"Remake Authored session requires a remake-authored campaign bundle"
		)
	var logic: Variant = semantic_bundle.documents.get("remakeLogic", {})
	var scripts: Variant = semantic_bundle.documents.get("remakeScripts", {})
	if not (logic is Dictionary) or not (scripts is Dictionary):
		return _semantic_fail("Remake scenario documents are unavailable")

	semantic_state = SemanticStateScript.new()
	semantic_state.configure(semantic_bundle.package_hash())
	semantic_services = (
		runtime_services
		if runtime_services != null
		else PreviewServicesScript.new()
	)
	if semantic_services.has_method("configure_classic_bundle"):
		semantic_services.call("configure_classic_bundle", semantic_bundle)
	var start: Variant = semantic_bundle.documents.get(
		"scenario",
		{}
	).get("startup", {})
	if semantic_services.has_method("configure"):
		semantic_services.call(
			"configure",
			start if start is Dictionary else {}
		)
	var location := _semantic_location()
	semantic_state.set_location(
		str(location.get("levelType", "land")),
		int(location.get("levelIndex", 0)),
		int(location.get("x", 0)),
		int(location.get("y", 0))
	)
	semantic_state.begin_map_entry(
		"%s:%d" % [
			location.get("levelType", "land"),
			location.get("levelIndex", 0),
		]
	)

	var registry := RegistryScript.new()
	if not HandlerCatalogScript.register_all(registry):
		return _semantic_fail(registry.last_error)
	var vm_triggers := _build_vm_triggers(logic)
	if vm_triggers.is_empty() and (
		not logic.get("mapTriggers", []).is_empty()
		or not logic.get("eventTriggers", []).is_empty()
		or not logic.get("scheduledTriggers", []).is_empty()
		or not logic.get("encounters", []).is_empty()
	):
		return false
	interpreter = InterpreterScript.new()
	interpreter.configure(registry, vm_triggers)
	var script_result := interpreter.configure_scenario_scripts(
		scripts,
		semantic_state,
		semantic_bundle
	)
	if str(script_result.get("status", "")) != "ok":
		return _semantic_fail(str(script_result.get("message", "")))

	var ports_result := DefaultPortsScript.create(semantic_services)
	if str(ports_result.get("status", "")) != "ok":
		return _semantic_fail(str(ports_result.get("message", "")))
	command_router = ports_result["router"]
	host = SemanticHostScript.new()
	add_child(host)
	host.configure(self)
	return true


func begin_map_trigger(trigger_id: String, context := {}) -> Dictionary:
	if not semantic_mode or interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	var trigger: Dictionary = triggers_by_id.get(trigger_id, {})
	if trigger.is_empty():
		return _semantic_error("Map Trigger '%s' is unavailable" % trigger_id)
	if not bool(trigger.get("enabled", true)):
		return {"status": "skipped", "reason": "disabled"}
	if not semantic_state.can_run_trigger(trigger):
		return {"status": "skipped", "reason": "repeat-policy"}
	var activation_id := _optional_id(
		trigger.get("activationConditionBehaviorId")
	)
	if not activation_id.is_empty():
		var activation := _evaluate_condition(
			activation_id,
			{"mapTrigger": trigger.duplicate(true)},
			"Map Trigger activation"
		)
		if str(activation.get("status", "")) == "error":
			return activation
		if not bool(activation.get("value", false)):
			return {"status": "skipped", "reason": "activation-condition"}
	var chance := clampi(int(trigger.get("chance", 100)), 0, 100)
	if chance <= 0 \
			or (chance < 100 and semantic_state.roll_percent() > chance):
		return {"status": "skipped", "reason": "chance"}
	var variant_result := _select_named_variant(
		trigger,
		{"mapTrigger": trigger.duplicate(true)},
		"Map Trigger"
	)
	if str(variant_result.get("status", "")) == "error":
		return variant_result
	var selected_variant: Dictionary = variant_result.get("variant", {})
	_set_vm_behavior(
		trigger_id,
		str(selected_variant.get("behaviorId", ""))
	)
	active_trigger_id = trigger_id
	active_encounter_id = ""
	active_trigger_kind = "map"
	active_scheduled_marker = -1
	var execution_context := context.duplicate(true) \
		if context is Dictionary else {}
	execution_context["mapTrigger"] = trigger.duplicate(true)
	execution_context["activeVariantId"] = str(
		selected_variant.get("id", "")
	)
	var started := interpreter.start(trigger_id, 0, execution_context)
	if str(started.get("status", "")) != "ok":
		return started
	return _finish_if_complete(interpreter.run(interpreter))


func begin_encounter(
	encounter_id: String,
	context := {},
	start_section_id := ""
) -> Dictionary:
	if not semantic_mode or interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	var encounter: Dictionary = encounters_by_id.get(encounter_id, {})
	if encounter.is_empty():
		return _semantic_error(
			"Modern Encounter '%s' is unavailable" % encounter_id
		)
	if not semantic_state.can_run_encounter(encounter):
		return {"status": "skipped", "reason": "repeat-policy"}
	var active_encounter := encounter.duplicate(true)
	var variant_result := _select_named_variant(
		active_encounter,
		{"encounter": active_encounter.duplicate(true)},
		"Modern Encounter"
	)
	if str(variant_result.get("status", "")) == "error":
		return variant_result
	var selected_variant: Dictionary = variant_result.get("variant", {})
	active_encounter["activeVariantId"] = str(
		selected_variant.get("id", "")
	)
	active_encounter["variantBehaviorId"] = str(
		selected_variant.get("behaviorId", "")
	)
	if not start_section_id.is_empty():
		var found := false
		for section_value: Variant in active_encounter.get("sections", []):
			if section_value is Dictionary \
					and str(section_value.get("id", "")) == start_section_id:
				found = true
				break
		if not found:
			return _semantic_error(
				"Modern Encounter '%s' has no section '%s'"
				% [encounter_id, start_section_id]
			)
		active_encounter["entrySectionId"] = start_section_id
	_set_vm_encounter(encounter_id, active_encounter)
	active_encounter_id = encounter_id
	active_trigger_id = ""
	active_trigger_kind = "encounter"
	active_scheduled_marker = -1
	var execution_context := context.duplicate(true) \
		if context is Dictionary else {}
	execution_context["encounter"] = active_encounter.duplicate(true)
	execution_context["activeVariantId"] = str(
		selected_variant.get("id", "")
	)
	var started := interpreter.start(encounter_id, 0, execution_context)
	if str(started.get("status", "")) != "ok":
		return started
	return _finish_if_complete(interpreter.run(interpreter))


func begin_event_dispatch(event_name: String, context := {}) -> Dictionary:
	if not semantic_mode or interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	if interpreter.pending_command != null or not pending_trigger_queue.is_empty():
		return _semantic_error("Another scenario dispatch is already active")
	var normalized_event := _normalize_event_name(event_name)
	var event_context := context.duplicate(true) if context is Dictionary else {}
	event_context["event"] = normalized_event
	var only_trigger_id := str(event_context.get("onlyTriggerId", ""))
	var candidates: Array = []
	for trigger_value: Variant in event_triggers_by_id.values():
		var trigger: Dictionary = trigger_value
		if bool(trigger.get("enabled", true)) \
				and str(trigger.get("event", "")) == normalized_event \
				and (
					only_trigger_id.is_empty()
					or str(trigger.get("id", "")) == only_trigger_id
				):
			candidates.append(trigger)
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_priority := int(left.get("priority", 0))
		var right_priority := int(right.get("priority", 0))
		return (
			left_priority < right_priority
			if left_priority != right_priority
			else str(left.get("id", "")) < str(right.get("id", ""))
		)
	)
	pending_trigger_queue = candidates.map(
		func(trigger: Dictionary) -> Dictionary:
			return {
				"kind": "event",
				"id": str(trigger.get("id", "")),
				"context": event_context.duplicate(true),
				"scheduledMarker": -1,
			}
	)
	active_dispatch_count = 0
	return _start_next_queued_trigger()


func begin_scheduled_dispatch(clock: Dictionary, context := {}) -> Dictionary:
	if not semantic_mode or interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	if interpreter.pending_command != null or not pending_trigger_queue.is_empty():
		return _semantic_error("Another scenario dispatch is already active")
	var clock_validation := _validate_schedule_clock(clock)
	if str(clock_validation.get("status", "")) == "error":
		return clock_validation
	var schedule_context := context.duplicate(true) if context is Dictionary else {}
	schedule_context["clock"] = clock.duplicate(true)
	schedule_context["location"] = _semantic_location()
	var only_trigger_id := str(schedule_context.get("onlyTriggerId", ""))
	var candidates: Array = []
	for trigger_value: Variant in scheduled_triggers_by_id.values():
		var trigger: Dictionary = trigger_value
		if not bool(trigger.get("enabled", true)) \
				or not _scheduled_location_matches(trigger) \
				or (
					not only_trigger_id.is_empty()
					and str(trigger.get("id", "")) != only_trigger_id
				):
			continue
		var marker := semantic_state.scheduled_due_marker(trigger, clock)
		if marker < 0:
			continue
		candidates.append({
			"trigger": trigger,
			"marker": marker,
		})
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_trigger: Dictionary = left.get("trigger", {})
		var right_trigger: Dictionary = right.get("trigger", {})
		var left_priority := int(left_trigger.get("priority", 0))
		var right_priority := int(right_trigger.get("priority", 0))
		return (
			left_priority < right_priority
			if left_priority != right_priority
			else str(left_trigger.get("id", "")) < str(
				right_trigger.get("id", "")
			)
		)
	)
	pending_trigger_queue = candidates.map(
		func(candidate: Dictionary) -> Dictionary:
			var trigger: Dictionary = candidate.get("trigger", {})
			return {
				"kind": "scheduled",
				"id": str(trigger.get("id", "")),
				"context": schedule_context.duplicate(true),
				"scheduledMarker": int(candidate.get("marker", -1)),
			}
	)
	active_dispatch_count = 0
	return _start_next_queued_trigger()


func resume_remake_command(response: Dictionary) -> Dictionary:
	if not semantic_mode or interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	var result := _finish_if_complete(interpreter.resume(response, interpreter))
	if host != null and host.has_method("_schedule_event_queue_drain"):
		host.call_deferred("_schedule_event_queue_drain")
	return result


func run_map_trigger(trigger_id: String, context := {}) -> Dictionary:
	var result := begin_map_trigger(trigger_id, context)
	while str(result.get("status", "")) == "yield":
		var response: Dictionary = await command_router.route(
			str(result.get("commandId", "")),
			result.get("request", {})
		)
		if str(response.get("status", "")) == "error":
			return response
		result = resume_remake_command(response)
	return result


func run_encounter(
	encounter_id: String,
	context := {},
	start_section_id := ""
) -> Dictionary:
	var result := begin_encounter(encounter_id, context, start_section_id)
	while str(result.get("status", "")) == "yield":
		var response: Dictionary = await command_router.route(
			str(result.get("commandId", "")),
			result.get("request", {})
		)
		if str(response.get("status", "")) == "error":
			return response
		result = resume_remake_command(response)
	return result


func run_event(event_name: String, context := {}) -> Dictionary:
	var result := begin_event_dispatch(event_name, context)
	while str(result.get("status", "")) == "yield":
		var response: Dictionary = await command_router.route(
			str(result.get("commandId", "")),
			result.get("request", {})
		)
		if str(response.get("status", "")) == "error":
			return response
		result = resume_remake_command(response)
	return result


func run_scheduled(clock: Dictionary, context := {}) -> Dictionary:
	var result := begin_scheduled_dispatch(clock, context)
	while str(result.get("status", "")) == "yield":
		var response: Dictionary = await command_router.route(
			str(result.get("commandId", "")),
			result.get("request", {})
		)
		if str(response.get("status", "")) == "error":
			return response
		result = resume_remake_command(response)
	return result


func make_save_payload() -> Dictionary:
	if not semantic_mode:
		return super.make_save_payload()
	var result := _make_semantic_save()
	return result.get("save", {}) if str(result.get("status", "")) == "ok" else {}


func make_save_result() -> Dictionary:
	if not semantic_mode:
		return super.make_save_result()
	var result := _make_semantic_save()
	if str(result.get("status", "")) == "ok":
		result["payload"] = result.get("save", {}).duplicate(true)
	return result


func restore_save_payload(payload: Dictionary) -> Dictionary:
	if not semantic_mode:
		return super.restore_save_payload(payload)
	return _restore_semantic_save(payload)


func state_summary() -> Dictionary:
	if not semantic_mode:
		return {
			"campaignKind": super._campaign_kind(),
			"implementationKind": IMPLEMENTATION_KIND,
		}
	return {
		"campaignId": str(semantic_bundle.manifest.get("id", "")),
		"campaignKind": REMAKE_AUTHORED_KIND,
		"activeTriggerId": active_trigger_id,
		"activeEncounterId": active_encounter_id,
		"activeTriggerKind": active_trigger_kind,
		"activeScheduledMarker": active_scheduled_marker,
		"pendingTriggerQueue": pending_trigger_queue.duplicate(true),
		"location": _semantic_location(),
		"semanticState": (
			semantic_state.snapshot() if semantic_state != null else {}
		),
		"scriptState": (
			interpreter.scenario_script_runtime.snapshot()
			if interpreter != null and interpreter.scenario_script_runtime != null
			else {}
		),
		"pendingCommand": (
			interpreter.pending_command.to_dictionary()
			if interpreter != null and interpreter.pending_command != null
			else null
		),
	}


func validate_save_point() -> Dictionary:
	if not semantic_mode:
		return super.validate_save_point()
	var result := _make_semantic_save()
	return {"status": "ok"} if str(result.get("status", "")) == "ok" else result


func apply_character_rules(party: Array) -> Dictionary:
	if not semantic_mode:
		return super.apply_character_rules(party)
	if party.is_empty():
		return _semantic_error("Select at least one character")
	return {"status": "ok"}


func activate_start_location(force_reload := false) -> Dictionary:
	if not semantic_mode:
		return super.activate_start_location(force_reload)
	if semantic_services == null \
			or not semantic_services.has_method("activate_classic_start"):
		return _semantic_error("Remake Authored map services are unavailable")
	var location := (
		_semantic_location()
		if force_reload and not _semantic_location().is_empty()
		else semantic_bundle.start_location()
	)
	if location.is_empty():
		return _semantic_error("Remake Authored campaign start is invalid")
	semantic_state.set_location(
		str(location.get("levelType", "land")),
		int(location.get("levelIndex", 0)),
		int(location.get("x", 0)),
		int(location.get("y", 0))
	)
	var map_id := "%s:%d" % [
		location.get("levelType", "land"),
		location.get("levelIndex", 0),
	]
	if not force_reload and semantic_state.current_map_entry(map_id) == 0:
		semantic_state.begin_map_entry(map_id)
	var result: Variant = semantic_services.call(
		"activate_classic_start",
		location
	)
	var normalized: Dictionary = result if result is Dictionary else {
		"status": "error",
		"message": "Remake Authored campaign start returned an invalid result",
	}
	if (
		str(normalized.get("status", "")) != "error"
		and host != null
		and not force_reload
	):
		host.call_deferred("emit_lifecycle_event", "campaign-start", {
			"event": "campaign-start",
			"campaignId": str(semantic_bundle.manifest.get("id", "")),
		})
		host.call_deferred("emit_lifecycle_event", "map-enter", {
			"event": "map-enter",
			"location": location.duplicate(true),
		})
	return normalized


func on_native_time_advanced(
	previous_time: int,
	current_time: int,
	native_location: Dictionary = {}
) -> Dictionary:
	if not semantic_mode:
		return super.on_native_time_advanced(
			previous_time,
			current_time,
			native_location
		)
	var location := native_location.duplicate(true)
	var defer_dispatch := bool(location.get("deferDispatch", false))
	location.erase("deferDispatch")
	if not location.is_empty():
		var location_result := sync_native_location(location)
		if str(location_result.get("status", "")) == "error":
			return location_result
	if not defer_dispatch and host != null:
		host.call_deferred("emit_lifecycle_event", "time-advanced", {
			"event": "time-advanced",
			"previousTime": previous_time,
			"currentTime": current_time,
			"elapsedSeconds": maxi(0, current_time - previous_time),
			"location": location,
		})
	return {
		"status": "ok",
		"deferred": defer_dispatch,
	}


func sync_native_location(location: Dictionary) -> Dictionary:
	if not semantic_mode:
		return super.sync_native_location(location)
	var map_name := str(location.get("mapName", ""))
	var level_type := "dungeon" if map_name.begins_with("mapd_") else "land"
	var level_text := (
		map_name.trim_prefix("mapd_")
		if level_type == "dungeon"
		else map_name.trim_prefix("map_")
	)
	if not level_text.is_valid_int():
		return _semantic_error("Remake Authored save location is invalid")
	semantic_state.set_location(
		level_type,
		int(level_text),
		int(location.get("x", 0)),
		int(location.get("y", 0))
	)
	return {"status": "ok"}


func resume_saved_continuation() -> Dictionary:
	if not semantic_mode:
		return super.resume_saved_continuation()
	if interpreter == null or interpreter.pending_command == null:
		return {"status": "ok", "handled": false}
	var pending := interpreter.last_result
	var response: Dictionary = await command_router.route(
		str(pending.get("commandId", "")),
		pending.get("request", {})
	)
	if str(response.get("status", "")) == "error":
		return response
	return resume_remake_command(response)


func clear() -> void:
	super.clear()
	semantic_bundle = null
	interpreter = null
	command_router = null
	semantic_state = null
	semantic_services = null
	triggers_by_id.clear()
	encounters_by_id.clear()
	event_triggers_by_id.clear()
	scheduled_triggers_by_id.clear()
	active_trigger_id = ""
	active_encounter_id = ""
	active_trigger_kind = ""
	active_scheduled_marker = -1
	pending_trigger_queue.clear()
	active_dispatch_count = 0
	semantic_mode = false
	semantic_last_error = ""


func _build_vm_triggers(logic: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for trigger_value: Variant in logic.get("mapTriggers", []):
		if not (trigger_value is Dictionary):
			_semantic_fail("Remake Map Trigger entry is invalid")
			return {}
		var trigger: Dictionary = trigger_value
		var trigger_id := str(trigger.get("id", ""))
		if trigger_id.is_empty() or result.has(trigger_id):
			_semantic_fail("Remake Map Trigger IDs must be unique")
			return {}
		var default_variant := _default_variant(trigger)
		if default_variant.is_empty():
			_semantic_fail("Map Trigger '%s' has no default variant" % trigger_id)
			return {}
		triggers_by_id[trigger_id] = trigger.duplicate(true)
		result[trigger_id] = {
			"id": trigger_id,
			"actions": [
				_script_call(str(default_variant.get("behaviorId", ""))),
			],
		}
	for trigger_value: Variant in logic.get("eventTriggers", []):
		if not (trigger_value is Dictionary):
			_semantic_fail("Remake Event Trigger entry is invalid")
			return {}
		var trigger: Dictionary = trigger_value
		var trigger_id := str(trigger.get("id", ""))
		if trigger_id.is_empty() or result.has(trigger_id):
			_semantic_fail("Semantic trigger IDs must be unique")
			return {}
		var event_name := _normalize_event_name(str(trigger.get("event", "")))
		if event_name.is_empty():
			_semantic_fail("Event Trigger '%s' has an invalid event" % trigger_id)
			return {}
		var behavior_id := str(trigger.get("behaviorId", ""))
		if behavior_id.is_empty():
			_semantic_fail("Event Trigger '%s' has no behavior" % trigger_id)
			return {}
		trigger["event"] = event_name
		event_triggers_by_id[trigger_id] = trigger.duplicate(true)
		result[trigger_id] = {
			"id": trigger_id,
			"actions": [_script_call(behavior_id)],
		}
	for trigger_value: Variant in logic.get("scheduledTriggers", []):
		if not (trigger_value is Dictionary):
			_semantic_fail("Remake Scheduled Trigger entry is invalid")
			return {}
		var trigger: Dictionary = trigger_value
		var trigger_id := str(trigger.get("id", ""))
		if trigger_id.is_empty() or result.has(trigger_id):
			_semantic_fail("Semantic trigger IDs must be unique")
			return {}
		var schedule_validation := _validate_schedule(trigger.get("schedule", {}))
		if str(schedule_validation.get("status", "")) == "error":
			_semantic_fail(
				"Scheduled Trigger '%s': %s"
				% [trigger_id, schedule_validation.get("message", "invalid schedule")]
			)
			return {}
		var behavior_id := str(trigger.get("behaviorId", ""))
		if behavior_id.is_empty():
			_semantic_fail("Scheduled Trigger '%s' has no behavior" % trigger_id)
			return {}
		scheduled_triggers_by_id[trigger_id] = trigger.duplicate(true)
		result[trigger_id] = {
			"id": trigger_id,
			"actions": [_script_call(behavior_id)],
		}
	for encounter_value: Variant in logic.get("encounters", []):
		if not (encounter_value is Dictionary):
			_semantic_fail("Modern Encounter entry is invalid")
			return {}
		var encounter: Dictionary = encounter_value
		var encounter_id := str(encounter.get("id", ""))
		if encounter_id.is_empty() or result.has(encounter_id):
			_semantic_fail("Semantic trigger and Encounter IDs must be unique")
			return {}
		if _default_variant(encounter).is_empty():
			_semantic_fail(
				"Modern Encounter '%s' has no default variant" % encounter_id
			)
			return {}
		encounters_by_id[encounter_id] = encounter.duplicate(true)
		var encounter_actions := _compile_encounter_actions(encounter)
		if encounter_actions.is_empty():
			_semantic_fail(
				"Modern Encounter '%s' could not compile an execution plan"
				% encounter_id
			)
			return {}
		result[encounter_id] = {
			"id": encounter_id,
			"actions": encounter_actions,
		}
	return result


func _start_next_queued_trigger() -> Dictionary:
	while not pending_trigger_queue.is_empty():
		var queued_value: Variant = pending_trigger_queue.pop_front()
		if not (queued_value is Dictionary):
			continue
		var queued: Dictionary = queued_value
		var kind := str(queued.get("kind", ""))
		var trigger_id := str(queued.get("id", ""))
		var trigger: Dictionary = (
			event_triggers_by_id.get(trigger_id, {})
			if kind == "event"
			else scheduled_triggers_by_id.get(trigger_id, {})
		)
		if trigger.is_empty() or not bool(trigger.get("enabled", true)):
			continue
		var condition_id := _optional_id(trigger.get("conditionBehaviorId"))
		var context: Dictionary = (
			queued.get("context", {}).duplicate(true)
			if queued.get("context", {}) is Dictionary
			else {}
		)
		context["trigger"] = trigger.duplicate(true)
		context["triggerKind"] = kind
		if not condition_id.is_empty():
			var condition := _evaluate_condition(
				condition_id,
				context,
				"%s Trigger '%s' condition"
					% [kind.capitalize(), trigger.get("name", trigger_id)]
			)
			if str(condition.get("status", "")) == "error":
				pending_trigger_queue.clear()
				return condition
			if not bool(condition.get("value", false)):
				continue
		_set_vm_behavior(trigger_id, str(trigger.get("behaviorId", "")))
		active_trigger_id = trigger_id
		active_encounter_id = ""
		active_trigger_kind = kind
		active_scheduled_marker = int(queued.get("scheduledMarker", -1))
		context["activeTriggerId"] = trigger_id
		var started := interpreter.start(trigger_id, 0, context)
		if str(started.get("status", "")) != "ok":
			pending_trigger_queue.clear()
			return started
		active_dispatch_count += 1
		var result := interpreter.run(interpreter)
		if str(result.get("status", "")) in ["complete", "halt"]:
			_mark_active_execution_complete()
			continue
		return result
	var handled := active_dispatch_count > 0
	active_dispatch_count = 0
	return {
		"status": "complete",
		"reason": "dispatch-complete",
		"handled": handled,
	}


func _validate_schedule(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _semantic_error("schedule must be an object")
	var schedule: Dictionary = value
	match str(schedule.get("kind", "")):
		"absolute":
			var day := int(schedule.get("day", -1))
			var minute := int(schedule.get("minute", -1))
			if day < 1 or minute < 0 or minute >= 1440:
				return _semantic_error(
					"absolute schedule requires a scenario day of 1 or later and a minute from 0 to 1439"
				)
		"elapsed":
			if int(schedule.get("elapsedMinutes", -1)) < 0:
				return _semantic_error(
					"elapsed schedule requires non-negative elapsed minutes"
				)
		"recurring":
			if int(schedule.get("intervalMinutes", 0)) <= 0:
				return _semantic_error(
					"recurring schedule requires a positive interval"
				)
		_:
			return _semantic_error("schedule kind is unsupported")
	return {"status": "ok"}


func _validate_schedule_clock(clock: Variant) -> Dictionary:
	if not (clock is Dictionary):
		return _semantic_error("Schedule clock must be an object")
	var value: Dictionary = clock
	var elapsed := int(value.get("elapsedMinutes", -1))
	var day := int(value.get("day", -1))
	var minute := int(value.get("minute", -1))
	if elapsed < 0 and (day < 0 or minute < 0 or minute >= 1440):
		return _semantic_error(
			"Schedule clock requires elapsed minutes or a valid day and minute"
		)
	return {"status": "ok"}


func _scheduled_location_matches(trigger: Dictionary) -> bool:
	var location_value: Variant = trigger.get("location")
	if location_value == null:
		return true
	if not (location_value is Dictionary):
		return false
	var required: Dictionary = location_value
	var current := _semantic_location()
	var current_map_id := "%s:%d" % [
		current.get("levelType", "land"),
		current.get("levelIndex", 0),
	]
	if str(required.get("mapId", "")) != current_map_id:
		return false
	var x := int(current.get("x", 0))
	var y := int(current.get("y", 0))
	var left := int(required.get("x", 0))
	var top := int(required.get("y", 0))
	var width := maxi(1, int(required.get("width", 1)))
	var height := maxi(1, int(required.get("height", 1)))
	return x >= left and x < left + width and y >= top and y < top + height


func _normalize_event_name(value: String) -> String:
	var normalized := value.strip_edges().to_lower()
	var aliases := {
		"campaign-complete": "campaign-end",
		"party-moved": "movement",
		"rest-start": "rest-start",
		"rest-complete": "rest",
		"time-advanced": "time",
		"battle-complete": "battle-end",
		"character-defeated": "character-defeat",
		"party-defeated": "party-defeat",
	}
	normalized = str(aliases.get(normalized, normalized))
	return normalized if normalized in [
		"campaign-start",
		"campaign-end",
		"map-enter",
		"map-leave",
		"movement",
		"rest-start",
		"rest",
		"time",
		"battle-start",
		"battle-end",
		"character-defeat",
		"party-defeat",
		"spell",
		"item",
		"combat-round",
	] else ""


func _select_named_variant(
	record: Dictionary,
	condition_context: Dictionary,
	label: String
) -> Dictionary:
	for variant_value: Variant in record.get("variants", []):
		if not (variant_value is Dictionary):
			continue
		var variant: Dictionary = variant_value
		if str(variant.get("id", "")) == str(
			record.get("defaultVariantId", "")
		):
			continue
		var condition_id := _optional_id(variant.get("conditionBehaviorId"))
		if condition_id.is_empty():
			continue
		var condition := _evaluate_condition(
			condition_id,
			condition_context,
			"%s variant '%s'" % [label, variant.get("name", "")]
		)
		if str(condition.get("status", "")) == "error":
			return condition
		if bool(condition.get("value", false)):
			return {
				"status": "ok",
				"variant": variant.duplicate(true),
			}
	var default_variant := _default_variant(record)
	if default_variant.is_empty():
		return _semantic_error("%s has no default variant" % label)
	return {
		"status": "ok",
		"variant": default_variant.duplicate(true),
	}


func _evaluate_condition(
	behavior_id: String,
	condition_context: Dictionary,
	label: String
) -> Dictionary:
	var step := interpreter.execute_scenario_script(
		behavior_id,
		{},
		condition_context
	)
	if step == null:
		return _semantic_error("%s returned no result" % label)
	if step.kind == ScenarioStepResult.ERROR:
		return _semantic_error(str(step.data.get(
			"message",
			"%s failed" % label
		)))
	if step.kind != ScenarioStepResult.CONTINUE:
		return _semantic_error(
			"%s must be pure and non-yielding" % label
		)
	var value: Variant = step.data.get("value")
	if not (value is bool):
		return _semantic_error("%s must return bool" % label)
	return {"status": "ok", "value": value}


func _set_vm_behavior(trigger_id: String, behavior_id: String) -> void:
	var vm_trigger: Dictionary = interpreter.triggers.get(trigger_id, {})
	vm_trigger["actions"] = [_script_call(behavior_id)]
	interpreter.triggers[trigger_id] = vm_trigger


func _set_vm_encounter(encounter_id: String, encounter: Dictionary) -> void:
	var vm_trigger: Dictionary = interpreter.triggers.get(encounter_id, {})
	vm_trigger["actions"] = _compile_encounter_actions(encounter)
	interpreter.triggers[encounter_id] = vm_trigger


func _finish_if_complete(result: Dictionary) -> Dictionary:
	if str(result.get("status", "")) not in ["complete", "halt"]:
		return result
	var completed_dispatch := active_trigger_kind in ["event", "scheduled"]
	_mark_active_execution_complete()
	if not pending_trigger_queue.is_empty():
		return _start_next_queued_trigger()
	if completed_dispatch:
		var handled := active_dispatch_count > 0
		active_dispatch_count = 0
		return {
			"status": "complete",
			"reason": "dispatch-complete",
			"handled": handled,
		}
	return result


func _mark_active_execution_complete() -> void:
	if active_trigger_kind == "map" and triggers_by_id.has(active_trigger_id):
		semantic_state.mark_trigger_completed(triggers_by_id[active_trigger_id])
	elif active_trigger_kind == "scheduled" \
			and scheduled_triggers_by_id.has(active_trigger_id):
		semantic_state.mark_scheduled_trigger(
			active_trigger_id,
			active_scheduled_marker
		)
	if active_trigger_kind == "encounter" \
			and encounters_by_id.has(active_encounter_id):
		semantic_state.mark_encounter_completed(
			encounters_by_id[active_encounter_id]
		)
	active_trigger_id = ""
	active_encounter_id = ""
	active_trigger_kind = ""
	active_scheduled_marker = -1


func _make_semantic_save() -> Dictionary:
	if interpreter == null:
		return _semantic_error("Remake Authored session is not configured")
	var scripts: Dictionary = semantic_bundle.documents.get(
		"remakeScripts",
		{}
	)
	var vm_snapshot := interpreter.snapshot()
	var mixed_state := interpreter.mixed_execution_state()
	var service_snapshot := {}
	if semantic_services != null and semantic_services.has_method("snapshot"):
		service_snapshot = semantic_services.call("snapshot")
	var payload := {
		"schemaVersion": SaveContractScript.SCHEMA_VERSION,
		"campaignId": str(semantic_bundle.manifest.get("id", "")),
		"campaignKind": REMAKE_AUTHORED_KIND,
		"implementationKind": IMPLEMENTATION_KIND,
		"contentVersion": str(
			semantic_bundle.manifest.get("contentVersion", "0.1.0")
		),
		"packageHash": semantic_bundle.package_hash(),
		"capabilityCatalogHash": str(
			scripts.get("capabilityCatalogHash", "")
		),
		"behaviorHashes": _current_behavior_hashes(scripts),
		"stateSchemaVersions": _current_state_schema_versions(scripts),
		"interpreter": {
			"vm": vm_snapshot,
			"semanticState": semantic_state.snapshot(),
			"ports": command_router.snapshot_state(),
			"services": service_snapshot,
			"activeTriggerId": active_trigger_id,
			"activeEncounterId": active_encounter_id,
			"activeTriggerKind": active_trigger_kind,
			"activeScheduledMarker": active_scheduled_marker,
			"pendingTriggerQueue": pending_trigger_queue.duplicate(true),
			"activeDispatchCount": active_dispatch_count,
			"lifecycleEventQueue": (
				host.lifecycle_event_queue_snapshot()
				if host != null
				and host.has_method("lifecycle_event_queue_snapshot")
				else []
			),
		},
		"pendingCommand": vm_snapshot.get("pendingCommand"),
		"activeResponseRef": mixed_state.get("activeResponseRef"),
		"activeResultRef": mixed_state.get("activeResultRef"),
		"mixedSequenceCursor": mixed_state.get("mixedSequenceCursor", {}),
		"resultTransitionCount": int(mixed_state.get("resultTransitionCount", 0)),
		"attachmentOrder": mixed_state.get("attachmentOrder", []),
		"resolvedGameplayRules": {
			"preset": str(
				semantic_bundle.documents.get("runtime", {}).get(
					"recommendedGameplayProfile",
					"core.classic"
				)
			),
		},
		"requiredPlugins": semantic_bundle.documents.get("runtime", {}).get(
			"requiredPlugins",
			[]
		).duplicate(true),
	}
	var validation := SaveContractScript.validate(payload)
	if not bool(validation.get("valid", false)):
		return _semantic_error(str(validation.get(
			"message",
			"Remake Authored save is invalid"
		)))
	return {"status": "ok", "save": payload}


func _restore_semantic_save(payload: Variant) -> Dictionary:
	var validation := SaveContractScript.validate(payload)
	if not bool(validation.get("valid", false)):
		return _semantic_error(str(validation.get(
			"message",
			"Remake Authored save is invalid"
		)))
	var saved: Dictionary = payload
	var compatibility := _validate_semantic_save_compatibility(saved)
	if str(compatibility.get("status", "")) != "ok":
		return compatibility
	var session_state: Variant = saved.get("interpreter", {})
	if not (session_state is Dictionary):
		return _semantic_error("Remake Authored save has no session state")
	var state_result := semantic_state.restore(
		session_state.get("semanticState", {})
	)
	if str(state_result.get("status", "")) != "ok":
		return state_result
	if not session_state.get("services", {}).is_empty() \
			and semantic_services != null \
			and semantic_services.has_method("restore"):
		var services_result: Dictionary = semantic_services.call(
			"restore",
			session_state.get("services", {})
		)
		if str(services_result.get("status", "")) != "ok":
			return services_result
	var port_result := command_router.restore_state(
		session_state.get("ports", {})
	)
	if str(port_result.get("status", "")) != "ok":
		return port_result
	var vm_result := interpreter.restore(session_state.get("vm", {}))
	if str(vm_result.get("status", "")) != "ok":
		return vm_result
	active_trigger_id = str(session_state.get("activeTriggerId", ""))
	active_encounter_id = str(session_state.get("activeEncounterId", ""))
	active_trigger_kind = str(session_state.get("activeTriggerKind", ""))
	active_scheduled_marker = int(
		session_state.get("activeScheduledMarker", -1)
	)
	var saved_queue: Variant = session_state.get("pendingTriggerQueue", [])
	if not (saved_queue is Array):
		return _semantic_error("Saved scenario trigger queue is invalid")
	pending_trigger_queue = saved_queue.duplicate(true)
	active_dispatch_count = int(session_state.get("activeDispatchCount", 0))
	if host != null and host.has_method("restore_lifecycle_event_queue"):
		var event_queue_result: Dictionary = host.restore_lifecycle_event_queue(
			session_state.get("lifecycleEventQueue", [])
		)
		if str(event_queue_result.get("status", "")) == "error":
			return event_queue_result
	return {"status": "ok"}


func _validate_semantic_save_compatibility(saved: Dictionary) -> Dictionary:
	var current_values := {
		"campaignId": str(semantic_bundle.manifest.get("id", "")),
		"contentVersion": str(
			semantic_bundle.manifest.get("contentVersion", "0.1.0")
		),
		"packageHash": semantic_bundle.package_hash(),
	}
	for field_name: String in current_values:
		if str(saved.get(field_name, "")) != str(current_values[field_name]):
			return _semantic_error(
				"Remake Authored save %s does not match the loaded campaign"
					% field_name
			)
	var scripts: Dictionary = semantic_bundle.documents.get(
		"remakeScripts",
		{}
	)
	if str(saved.get("capabilityCatalogHash", "")) != str(
		scripts.get("capabilityCatalogHash", "")
	):
		return _semantic_error(
			"Saved scenario capability catalog is unavailable"
		)
	if saved.get("behaviorHashes", {}) != _current_behavior_hashes(scripts):
		return _semantic_error(
			"Saved scenario behavior hashes do not match the campaign"
		)
	if saved.get(
		"stateSchemaVersions",
		{}
	) != _current_state_schema_versions(scripts):
		return _semantic_error(
			"Saved scenario state schemas do not match the campaign"
		)
	var required_plugins: Variant = semantic_bundle.documents.get(
		"runtime",
		{}
	).get("requiredPlugins", [])
	if saved.get("requiredPlugins", []) != required_plugins:
		return _semantic_error(
			"Saved scenario plug-in requirements do not match the campaign"
		)
	return {"status": "ok"}


func _semantic_location() -> Dictionary:
	if semantic_state != null and not semantic_state.location.is_empty():
		return semantic_state.location.duplicate(true)
	if semantic_services != null:
		var value: Variant = semantic_services.get("location")
		if value is Dictionary:
			return value.duplicate(true)
	return {
		"levelType": "land",
		"levelIndex": 0,
		"x": 0,
		"y": 0,
	}


static func _current_behavior_hashes(scripts: Dictionary) -> Dictionary:
	var behavior_hashes: Dictionary = {}
	for behavior_value: Variant in scripts.get("behaviors", []):
		if behavior_value is Dictionary:
			behavior_hashes[str(behavior_value.get("id", ""))] = str(
				behavior_value.get("contentHash", "")
			)
	return behavior_hashes


static func _current_state_schema_versions(scripts: Dictionary) -> Dictionary:
	var versions: Dictionary = {}
	for definition_value: Variant in scripts.get("stateDefinitions", []):
		if definition_value is Dictionary:
			var definition: Dictionary = definition_value
			var key := "%s\u001f%s\u001f%s" % [
				definition.get("scope", "campaign"),
				definition.get("ownerId", ""),
				definition.get("name", ""),
			]
			versions[key] = int(definition.get("schemaVersion", 1))
	return versions


static func _default_variant(trigger: Dictionary) -> Dictionary:
	var default_id := str(trigger.get("defaultVariantId", ""))
	for variant_value: Variant in trigger.get("variants", []):
		if variant_value is Dictionary \
				and str(variant_value.get("id", "")) == default_id:
			return variant_value
	return {}


static func _script_call(
	behavior_id: String,
	role := "action",
	hook := "run"
) -> Dictionary:
	return {
		"kind": "semantic",
		"operation": "core.script.call",
		"parameters": {
			"behaviorId": behavior_id,
			"arguments": {},
			"attachment": {
				"role": role,
				"hook": hook,
			},
		},
	}


static func _compile_encounter_actions(encounter: Dictionary) -> Array:
	var actions: Array = []
	var encounter_id := str(encounter.get("id", ""))
	if encounter_id.is_empty():
		return []
	var variant_behavior_id := str(encounter.get("variantBehaviorId", ""))
	if variant_behavior_id.is_empty():
		var fallback_variant := _default_variant(encounter)
		variant_behavior_id = str(fallback_variant.get("behaviorId", ""))
	if not variant_behavior_id.is_empty():
		actions.append(_script_call(variant_behavior_id, "encounter", "enter"))
	var entry_behavior_id := _optional_id(encounter.get("entryBehaviorId"))
	if not entry_behavior_id.is_empty():
		actions.append(_script_call(entry_behavior_id, "encounter", "enter"))

	var section_indexes: Dictionary = {}
	var request_indexes: Dictionary = {}
	var sections: Variant = encounter.get("sections", [])
	var results: Variant = encounter.get("results", [])
	if not (sections is Array) or sections.is_empty() or not (results is Array):
		return []
	var ordered_sections: Array = sections.duplicate(true)
	var entry_section_id := str(encounter.get("entrySectionId", ""))
	if not entry_section_id.is_empty():
		for section_index: int in range(ordered_sections.size()):
			var candidate: Variant = ordered_sections[section_index]
			if candidate is Dictionary \
					and str(candidate.get("id", "")) == entry_section_id:
				if section_index > 0:
					ordered_sections.push_front(ordered_sections.pop_at(section_index))
				break
	for section_value: Variant in ordered_sections:
		if not (section_value is Dictionary):
			return []
		var section: Dictionary = section_value
		var section_id := str(section.get("id", ""))
		if section_id.is_empty() or section_indexes.has(section_id):
			return []
		section_indexes[section_id] = actions.size()
		request_indexes[section_id] = actions.size()
		actions.append({
			"kind": "semantic",
			"operation": "core.encounter.request-response",
			"parameters": {
				"encounterId": encounter_id,
				"section": section.duplicate(true),
				"targets": {},
			},
		})

	var result_by_id: Dictionary = {}
	for result_value: Variant in results:
		if not (result_value is Dictionary):
			return []
		var result: Dictionary = result_value
		var result_id := str(result.get("id", ""))
		if result_id.is_empty() or result_by_id.has(result_id):
			return []
		result_by_id[result_id] = result
	var response_targets: Dictionary = {}
	var terminal_action_indexes: Array = []
	for section_value: Variant in ordered_sections:
		var section: Dictionary = section_value
		var section_id := str(section.get("id", ""))
		var section_targets: Dictionary = {}
		for response_value: Variant in section.get("responses", []):
			if not (response_value is Dictionary):
				return []
			var response: Dictionary = response_value
			var response_id := str(response.get("id", ""))
			var result: Dictionary = result_by_id.get(
				str(response.get("resultId", "")),
				{}
			)
			if response_id.is_empty() or result.is_empty():
				return []
			section_targets[response_id] = actions.size()
			var selection_behavior_id := _optional_id(
				response.get("selectionBehaviorId")
			)
			if not selection_behavior_id.is_empty():
				actions.append(_script_call(
					selection_behavior_id,
					"encounter",
					"response"
				))
			var result_reference := {
				"kind": "remake-result",
				"encounterId": encounter_id,
				"resultId": str(result.get("id", "")),
			}
			actions.append({
				"kind": "semantic",
				"operation": "core.flow.mark-result",
				"parameters": {"resultRef": result_reference.duplicate(true)},
			})
			var result_behavior_id := _optional_id(result.get("behaviorId"))
			if not result_behavior_id.is_empty():
				actions.append(_script_call(result_behavior_id, "action", "run"))
			terminal_action_indexes.append(actions.size())
			actions.append({
				"kind": "semantic",
				"operation": "core.flow.branch",
				"parameters": {
					"actionIndex": -1,
					"terminal": result.get("terminal", {}).duplicate(true),
				},
			})
		response_targets[section_id] = section_targets

	var completion_index := actions.size()
	var completion_behavior_id := _optional_id(encounter.get("completionBehaviorId"))
	if not completion_behavior_id.is_empty():
		actions.append(_script_call(
			completion_behavior_id,
			"encounter",
			"complete"
		))
	actions.append({
		"kind": "semantic",
		"operation": "core.flow.halt",
		"parameters": {
			"reason": "encounter-complete",
			"outcome": "close",
		},
	})

	for section_id: Variant in request_indexes:
		var request_index := int(request_indexes[section_id])
		actions[request_index]["parameters"]["targets"] = (
			response_targets.get(section_id, {}).duplicate(true)
		)
	for terminal_index_value: Variant in terminal_action_indexes:
		var terminal_index := int(terminal_index_value)
		var parameters: Dictionary = actions[terminal_index]["parameters"]
		var terminal: Dictionary = parameters.get("terminal", {})
		var terminal_kind := str(terminal.get("kind", "return"))
		var destination := str(terminal.get("sectionId", ""))
		parameters["actionIndex"] = int(
			section_indexes.get(destination, completion_index)
			if terminal_kind in ["section", "repeat-section"]
			else completion_index
		)
		parameters.erase("terminal")
	return actions


static func _optional_id(value: Variant) -> String:
	return str(value) if value is String else ""


static func _installed_campaign_kind(
	campaigns_directory: String,
	campaign_name: String
) -> String:
	if not _safe_campaign_name(campaign_name):
		return ""
	var path := campaigns_directory.path_join(
		campaign_name
	).path_join("campaign.json")
	if not FileAccess.file_exists(path):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return str(parsed.get("campaignKind", "")) if parsed is Dictionary else ""


static func _safe_campaign_name(value: String) -> bool:
	return (
		not value.is_empty()
		and value == value.strip_edges()
		and value not in [".", ".."]
		and not value.contains("/")
		and not value.contains("\\")
		and not value.contains(":")
		and not value.is_absolute_path()
	)


func _semantic_fail(message: String) -> bool:
	semantic_last_error = message
	return false


func _semantic_error(message: String) -> Dictionary:
	semantic_last_error = message
	return {"status": "error", "message": message}


static func _semantic_static_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}
