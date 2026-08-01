extends Node

const BundleScript = preload(
	"res://scripts/scenario_runtime/scenario_campaign_bundle.gd"
)
const SessionScript = preload(
	"res://scripts/scenario_runtime/scenario_campaign_session.gd"
)
const ScriptRuntimeScript = preload(
	"res://scripts/scenario_runtime/scenario_script_runtime.gd"
)
const CapabilityCatalogScript = preload(
	"res://scripts/scenario_runtime/scenario_capability_catalog.gd"
)
const PreviewServicesScript = preload(
	"res://scripts/scenario_runtime/preview/scenario_semantic_preview_services.gd"
)
const MapMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_map_materializer.gd"
)
const PresentationServicesScript = preload(
	"res://scripts/scenario_runtime/godot/scenario_godot_presentation_services.gd"
)
const EncounterHandlerScript = preload(
	"res://scripts/scenario_runtime/handlers/encounter_handler.gd"
)

var failures := 0


func _ready() -> void:
	await _test_map_trigger_execution_and_restore()
	await _test_modern_encounter_execution_and_restore()
	_test_specialized_encounter_response_matching()
	await _test_typed_state_and_named_variants()
	await _test_event_and_scheduled_triggers()
	if failures == 0:
		print("Remake Authored scenario logic tests passed")
		get_tree().quit(0)
	else:
		push_error("Remake Authored Map Trigger tests failed: %d" % failures)
		get_tree().quit(1)


func _test_specialized_encounter_response_matching() -> void:
	var responses := [
		{
			"id": "reply.open-sesame",
			"kind": "typed-reply",
			"label": "Speak the password",
			"match": {"text": "Open Sesame"},
		},
		{
			"id": "spell.knock",
			"kind": "spell",
			"label": "Cast Knock",
			"match": {"recordId": "shared:spell:knock"},
		},
		{
			"id": "item.key",
			"kind": "item",
			"label": "Use the silver key",
			"match": {"recordId": "402"},
		},
		{
			"id": "rogue.attempt",
			"kind": "rogue",
			"label": "Pick the lock",
			"match": {"outcome": "attempt"},
		},
		{
			"id": "rogue.success",
			"kind": "rogue",
			"label": "Lock opened",
			"match": {"outcome": "success"},
		},
	]
	_expect(
		PresentationServicesScript.matching_scenario_typed_response(
			responses,
			"  OPEN SESAME  "
		).get("id") == "reply.open-sesame",
		"Modern typed replies match case-insensitively by authored text"
	)
	_expect(
		PresentationServicesScript.matching_scenario_record_response(
			responses,
			"spell",
			["Knock", "shared:spell:knock"]
		).get("id") == "spell.knock",
		"Modern spell responses match the selected spell's stable identities"
	)
	_expect(
		PresentationServicesScript.matching_scenario_record_response(
			responses,
			"item",
			["402", "Silver Key"]
		).get("id") == "item.key",
		"Modern item responses match the selected item definition"
	)
	var presenter := PresentationServicesScript.new()
	var choice_model: Dictionary = presenter.call(
		"_scenario_response_choice_model",
		responses
	)
	_expect(
		choice_model.get("tokens", []).has("mode:typed-reply")
			and choice_model.get("tokens", []).has("mode:spell")
			and choice_model.get("tokens", []).has("mode:item")
			and choice_model.get("tokens", []).has("response:rogue.attempt")
			and not choice_model.get("tokens", []).has("response:rogue.success"),
		"specialized response launchers expose only selectable rogue attempts"
	)
	var stable_result: Dictionary = PresentationServicesScript._scenario_response_result(
		responses[1],
		{"spellName": "Knock", "recordIds": ["shared:spell:knock"]}
	)
	_expect(
		stable_result.get("responseRef", {}).get("responseId") == "spell.knock",
		"specialized selectors return the authored stable response identity"
	)
	_expect(
		EncounterHandlerScript._validate_semantic_response({
			"kind": "rogue",
			"match": {"outcome": "failure"},
		}).contains("inside its Behavior"),
		"Modern rogue result logic cannot masquerade as a selectable response"
	)


func _test_map_trigger_execution_and_restore() -> void:
	var bundle := _map_trigger_bundle()
	var services := PreviewServicesScript.new()
	var session := SessionScript.new()
	add_child(session)
	_expect(
		session.configure_remake_bundle(bundle, services),
		"generic campaign session configures Remake Authored logic"
	)
	_expect(
		is_instance_valid(session.host)
			and session.host.has_trigger("scenario.fixture.map-trigger"),
		"generic runtime host exposes the authored Map Trigger"
	)
	var areas: Dictionary = MapMaterializerScript.new().call(
		"_script_areas",
		bundle,
		{"levelType": "land", "index": 0},
		{}
	)
	var authored_rectangles: Array = areas.get("ScriptRects", {}).values()
	_expect(
		authored_rectangles.size() == 1
			and authored_rectangles[0].get("scriptToLoad") == "scenario.fixture.map-trigger"
			and authored_rectangles[0].get("scriptRectangle") == [[2, 2], [2, 2]],
		"native map materialization routes authored coordinates to the semantic session"
	)
	if not session.semantic_last_error.is_empty():
		push_error(session.semantic_last_error)
		return
	services.apply_fixture({"choiceResponses": [1]})
	var result := session.begin_map_trigger("scenario.fixture.map-trigger")
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text",
		"Map Trigger yields text through the central interpreter"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "choice",
		"Map Trigger resumes into a serializable choice"
	)
	var save_result := session.make_save_result()
	_expect(
		save_result.get("status") == "ok"
			and save_result.get("save", {}).get("schemaVersion") == 8
			and save_result.get("save", {}).get("pendingCommand") is Dictionary,
		"pending Map Trigger produces a schema-8 save"
	)

	var restored_services := PreviewServicesScript.new()
	var restored := SessionScript.new()
	add_child(restored)
	_expect(
		restored.configure_remake_bundle(bundle, restored_services),
		"restored generic campaign session configures"
	)
	_expect(
		restored.restore_save_payload(save_result.get("save", {})).get(
			"status"
		) == "ok",
		"Map Trigger restores at the pending choice boundary"
	)
	var pending: Dictionary = restored.interpreter.last_result
	result = await _route_and_resume(restored, pending)
	_expect(
		result.get("status") == "complete",
		"restored Map Trigger completes through the central interpreter: %s"
			% result
	)
	_expect(
		restored_services.transcript == ["A gate blocks the road."],
		"presentation state survives restoration"
	)
	_expect(
		restored.begin_map_trigger(
			"scenario.fixture.map-trigger"
		).get("reason") == "repeat-policy",
		"once-only Map Trigger cannot double-fire: %s"
			% restored.semantic_state.snapshot()
	)
	session.queue_free()
	restored.queue_free()


func _test_modern_encounter_execution_and_restore() -> void:
	var bundle := _encounter_bundle()
	var services := PreviewServicesScript.new()
	var session := SessionScript.new()
	add_child(session)
	_expect(
		session.configure_remake_bundle(bundle, services),
		"generic campaign session configures Modern Encounters"
	)
	_expect(
		is_instance_valid(session.host)
			and session.host.has_encounter("scenario.fixture.encounter"),
		"generic runtime host exposes the Modern Encounter"
	)
	var encounter_actions: Array = session.interpreter.triggers.get(
		"scenario.fixture.encounter",
		{}
	).get("actions", [])
	var has_response_instruction := encounter_actions.any(
		func(action: Dictionary) -> bool:
			return str(action.get("operation", "")) \
				== "core.encounter.request-response"
	)
	var has_legacy_encounter_instruction := encounter_actions.any(
		func(action: Dictionary) -> bool:
			return str(action.get("operation", "")) == "core.encounter.run"
	)
	_expect(
		has_response_instruction and not has_legacy_encounter_instruction,
		"Modern Encounter compiles into ordinary interpreter instructions"
	)
	var result := session.begin_encounter("scenario.fixture.encounter")
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text"
			and result.get("request", {}).get("text") == "The city remembers you.",
		"Modern Encounter selects and runs its first matching named variant"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "encounter_response"
			and result.get("request", {}).get("responses", []).size() == 1
			and result.get("request", {}).get("responses", [])[0].get("label") \
				== "Accept the work",
		"Modern Encounter presents its section and filters responses through a pure availability Behavior"
	)
	var save_result := session.make_save_result()
	_expect(
		save_result.get("status") == "ok"
			and save_result.get("save", {}).get(
				"interpreter",
				{}
			).get("activeEncounterId") == "scenario.fixture.encounter",
		"pending Modern Encounter stores its active identity"
	)

	var restored_services := PreviewServicesScript.new()
	var restored := SessionScript.new()
	add_child(restored)
	_expect(
		restored.configure_remake_bundle(bundle, restored_services),
		"restored Modern Encounter session configures"
	)
	_expect(
		restored.restore_save_payload(save_result.get("save", {})).get(
			"status"
		) == "ok",
		"Modern Encounter restores at the choice boundary"
	)
	result = await _route_and_resume(restored, restored.interpreter.last_result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "encounter_response"
			and result.get("request", {}).get("text") == "The beasts turn on you.",
		"selected response branches to the named destination section"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "start_battle"
			and result.get("request", {}).get("battleId") == 7,
		"selected result Behavior yields a battle through the Combat port"
	)
	var battle_save := restored.make_save_result()
	_expect(
		battle_save.get("status") == "ok"
			and battle_save.get("save", {}).get("activeResponseRef", {}).get(
				"responseId",
				""
			) == "scenario.fixture.encounter.stable.fight"
			and battle_save.get("save", {}).get("activeResultRef", {}).get(
				"resultId",
				""
			) == "scenario.fixture.encounter.stable.fight-result",
		"pending result execution saves stable response and result references"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text"
			and result.get("request", {}).get("text") == "The job is done.",
		"completion Behavior runs after the selected result resumes"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "complete",
		"Modern Encounter resolves through the central interpreter: %s" % result
	)
	_expect(
		restored_services.transcript == [
			"The city remembers you.",
			"A man offers work involving a stable of wild beasts.",
			"The beasts turn on you.",
			"The job is done.",
		]
			and restored_services.pictures == [41]
			and restored_services.sounds == [42]
			and restored_services.battles == [7],
		"Modern Encounter presentation state survives restoration"
	)
	_expect(
		restored.begin_encounter(
			"scenario.fixture.encounter"
		).get("reason") == "repeat-policy",
		"once-only Modern Encounter cannot double-fire"
	)
	session.queue_free()
	restored.queue_free()


func _test_typed_state_and_named_variants() -> void:
	var bundle := _state_variant_bundle()
	var services := PreviewServicesScript.new()
	var session := SessionScript.new()
	add_child(session)
	_expect(
		session.configure_remake_bundle(bundle, services),
		"typed-state variant fixture configures"
	)
	var result := session.begin_map_trigger("scenario.fixture.stateful-trigger")
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text"
			and result.get("request", {}).get("text") == "First visit",
		"default variant runs before map-scoped state is set"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "complete",
		"default stateful variant completes"
	)
	var script_state: Dictionary = (
		session.interpreter.scenario_script_runtime.snapshot()
	)
	_expect(
		script_state.get("persistentValues", {}).get(
			"map\u001fland:0\u001fopened",
			false
		) == true,
		"context-owned map state is stored under the current map: %s"
			% script_state.get("persistentValues", {})
	)
	var save_result := session.make_save_result()
	var restored_services := PreviewServicesScript.new()
	var restored := SessionScript.new()
	add_child(restored)
	var restored_configured := restored.configure_remake_bundle(
		bundle,
		restored_services
	)
	var restore_result := (
		restored.restore_save_payload(save_result.get("save", {}))
		if restored_configured
		else {"status": "error", "message": restored.semantic_last_error}
	)
	_expect(
		restored_configured and restore_result.get("status") == "ok",
		"typed map state restores through save schema 8: %s"
			% restore_result
	)
	result = restored.begin_map_trigger("scenario.fixture.stateful-trigger")
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text"
			and result.get("request", {}).get("text") == "Already opened",
		"restored state selects the first matching named variant"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "complete",
		"selected named variant completes"
	)
	var bad_write: Dictionary = restored.interpreter.scenario_script_runtime.call(
		"_write_state",
		{
			"scope": "map",
			"ownerId": "land:0",
			"name": "opened",
			"value": "not a bool",
		}
	)
	_expect(
		bad_write.get("status") == "error",
		"typed state rejects a value that does not match its definition"
	)
	var invalid_bundle := _state_variant_bundle()
	invalid_bundle.documents["remakeScripts"]["stateDefinitions"][0][
		"defaultValue"
	] = "not a bool"
	var invalid := SessionScript.new()
	add_child(invalid)
	_expect(
		not invalid.configure_remake_bundle(
			invalid_bundle,
			PreviewServicesScript.new()
		),
		"runtime readiness rejects invalid typed-state defaults"
	)
	session.queue_free()
	restored.queue_free()
	invalid.queue_free()


func _test_event_and_scheduled_triggers() -> void:
	var bundle := _event_schedule_bundle()
	var services := PreviewServicesScript.new()
	var session := SessionScript.new()
	add_child(session)
	_expect(
		session.configure_remake_bundle(bundle, services),
		"Event and Scheduled Trigger fixture configures"
	)
	var result := session.begin_event_dispatch("map-enter", {
		"location": {
			"levelType": "land",
			"levelIndex": 0,
			"x": 2,
			"y": 2,
		},
	})
	_expect(
		result.get("status") == "yield"
			and result.get("request", {}).get("text") == "First map event",
		"Event Triggers begin in priority and stable-ID order"
	)
	var queued_lifecycle: Dictionary = await session.host.emit_lifecycle_event(
		"time-advanced",
		{
			"event": "time-advanced",
			"previousTime": 0,
			"currentTime": 60,
		}
	)
	_expect(
		queued_lifecycle.get("queued") == true,
		"lifecycle events raised while a trigger yields join the bounded queue"
	)
	var save_result := session.make_save_result()
	_expect(
		save_result.get("status") == "ok"
			and save_result.get("save", {}).get(
				"interpreter",
				{}
			).get("pendingTriggerQueue", []).size() == 1
			and save_result.get("save", {}).get(
				"interpreter",
				{}
			).get("lifecycleEventQueue", []).size() == 1,
		"pending Trigger and lifecycle-event queues are serialized"
	)
	var restored_services := PreviewServicesScript.new()
	var restored := SessionScript.new()
	add_child(restored)
	_expect(
		restored.configure_remake_bundle(bundle, restored_services)
			and restored.restore_save_payload(
				save_result.get("save", {})
			).get("status") == "ok"
			and restored.host.lifecycle_event_queue_snapshot().size() == 1,
		"Trigger and lifecycle-event queues restore at a yielded command"
	)
	result = await _route_and_resume(restored, restored.interpreter.last_result)
	_expect(
		result.get("status") == "yield"
			and result.get("request", {}).get("text") == "Second map event",
		"resuming one Event Trigger advances into the next trigger"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "complete"
			and result.get("handled") == true,
		"Event Trigger dispatch completes after all matching triggers"
	)
	await get_tree().process_frame
	_expect(
		restored.host.lifecycle_event_queue_snapshot().is_empty(),
		"restored lifecycle events drain after the active trigger completes"
	)

	result = restored.begin_scheduled_dispatch({
		"elapsedMinutes": 60,
		"day": 1,
		"minute": 60,
	})
	_expect(
		result.get("status") == "yield"
			and result.get("request", {}).get("text") == "The hourly bell rings.",
		"due recurring Scheduled Trigger runs at its first interval"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "complete"
			and restored.semantic_state.scheduled_markers.get(
				"scenario.fixture.hourly",
				-1
			) == 60,
		"Scheduled Trigger completion records its due marker"
	)
	_expect(
		restored.begin_scheduled_dispatch({
			"elapsedMinutes": 60,
			"day": 1,
			"minute": 60,
		}).get("handled") == false,
		"the same recurring interval cannot fire twice"
	)
	result = restored.begin_scheduled_dispatch({
		"elapsedMinutes": 120,
		"day": 1,
		"minute": 120,
	})
	_expect(
		result.get("status") == "yield",
		"the next recurring interval becomes due"
	)
	await _route_and_resume(restored, result)
	var absolute := {
		"id": "scenario.fixture.absolute",
		"schedule": {
			"kind": "absolute",
			"day": 2,
			"minute": 30,
		},
	}
	_expect(
		restored.semantic_state.scheduled_due_marker(
			absolute,
			{"day": 1, "minute": 1439, "elapsedMinutes": 1439}
		) == -1
			and restored.semantic_state.scheduled_due_marker(
				absolute,
				{"day": 2, "minute": 30, "elapsedMinutes": 1470}
			) == 1470,
		"absolute schedules use the one-based scenario day shown in the game"
	)
	session.queue_free()
	restored.queue_free()


func _route_and_resume(
	session: ScenarioCampaignSession,
	yielded: Dictionary
) -> Dictionary:
	var response: Dictionary = await session.command_router.route(
		str(yielded.get("commandId", "")),
		yielded.get("request", {})
	)
	return session.resume_remake_command(response)


func _map_trigger_bundle() -> ScenarioCampaignBundle:
	var catalog := CapabilityCatalogScript.new()
	catalog.load_builtin()
	var program := {
		"kind": "function",
		"name": "fixture_map_trigger",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {
					"text": _literal("A gate blocks the road."),
				},
				"sourceNode": "text",
			},
			{
				"kind": "operation",
				"capability": "core.presentation.choice",
				"arguments": {
					"prompt": _literal("Continue?"),
					"options": {
						"kind": "array",
						"values": [
							_literal("No"),
							_literal("Yes"),
						],
					},
				},
				"sourceNode": "choice",
			},
			{
				"kind": "return",
				"value": {
					"kind": "record",
					"fields": {
						"kind": _literal("continue"),
					},
				},
				"sourceNode": "return",
			},
		],
	}
	var state_schema := {}
	var behavior := {
		"id": "scenario.fixture.map-trigger.run",
		"name": "Fixture Map Trigger",
		"description": "Exercises Remake Authored trigger execution.",
		"kind": "entry",
		"role": "action",
		"hook": "run",
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "action-outcome",
		"requestedCapabilities": [
			"core.presentation.text",
			"core.presentation.choice",
		],
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(program),
		"program": program,
	}
	var trigger_id := "scenario.fixture.map-trigger"
	var variant_id := "%s.default" % trigger_id
	var bundle := BundleScript.new()
	bundle.manifest = {
		"format": "realmz-remake-scenario",
		"formatVersion": 3,
		"campaignKind": "remake-authored",
		"id": "fixture.remake-authored-map-trigger",
		"name": "Remake Authored Map Trigger Fixture",
		"contentVersion": "0.1.0",
		"integrity": {
			"packageHash": "b".repeat(64),
		},
	}
	bundle.documents = {
		"scenario": {
			"startup": {"mapId": "land:0", "x": 2, "y": 2},
		},
		"remakeLogic": {
			"schemaVersion": 5,
			"kind": "remake-authored",
			"mapTriggers": [{
				"id": trigger_id,
				"name": "Gate",
				"location": {
					"kind": "point",
					"mapId": "land:0",
					"x": 2,
					"y": 2,
					"width": 1,
					"height": 1,
				},
				"event": "enter",
				"enabled": true,
				"chance": 100,
				"priority": 0,
				"repeatPolicy": "once",
				"defaultVariantId": variant_id,
				"variants": [{
					"id": variant_id,
					"name": "Default",
					"conditionBehaviorId": null,
					"behaviorId": behavior["id"],
				}],
				"activationConditionBehaviorId": null,
			}],
			"eventTriggers": [],
			"scheduledTriggers": [],
			"encounters": [],
		},
		"remakeScripts": {
			"schemaVersion": 3,
			"apiVersion": 2,
			"capabilityCatalogHash": catalog.catalog_hash(),
			"behaviors": [behavior],
			"bindings": [],
			"stateDefinitions": [],
			"migrations": [],
		},
		"runtime": {
			"recommendedGameplayProfile": "core.classic",
			"requiredPlugins": [],
		},
	}
	return bundle


func _encounter_bundle() -> ScenarioCampaignBundle:
	var catalog := CapabilityCatalogScript.new()
	catalog.load_builtin()
	var behavior_id := "scenario.fixture.encounter.default.behavior"
	var result_behavior_id := "scenario.fixture.encounter.stable.fight.result"
	var completion_behavior_id := "scenario.fixture.encounter.complete"
	var availability_behavior_id := "scenario.fixture.encounter.refuse.available"
	var remembered_behavior_id := "scenario.fixture.encounter.remembered"
	var remembered_condition_id := "%s.condition" % remembered_behavior_id
	var program := {
		"kind": "function",
		"name": "fixture_encounter_default",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [{
			"kind": "return",
			"value": {
				"kind": "record",
				"fields": {"kind": _literal("continue")},
			},
		}],
	}
	var state_schema := {}
	var behavior := {
		"id": behavior_id,
		"name": "Fixture Encounter Default",
		"description": "Default Modern Encounter behavior.",
		"kind": "entry",
		"role": "encounter",
		"hook": "enter",
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "encounter-outcome",
		"requestedCapabilities": [],
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(program),
		"program": program,
	}
	var result_program := {
		"kind": "function",
		"name": "fixture_encounter_fight",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.encounter.start-battle",
				"arguments": {"battleId": _literal(7)},
				"sourceNode": "battle",
			},
			{
				"kind": "return",
				"value": {
					"kind": "record",
					"fields": {"kind": _literal("continue")},
				},
			},
		],
	}
	var result_behavior := {
		"id": result_behavior_id,
		"name": "Fight the Beasts",
		"description": "Starts the encounter battle.",
		"kind": "entry",
		"role": "action",
		"hook": "run",
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "action-outcome",
		"requestedCapabilities": ["core.encounter.start-battle"],
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(result_program),
		"program": result_program,
	}
	var completion_program := {
		"kind": "function",
		"name": "fixture_encounter_complete",
		"parameters": [],
		"returnType": "encounter-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {"text": _literal("The job is done.")},
				"sourceNode": "complete-text",
			},
			{
				"kind": "return",
				"value": {
					"kind": "record",
					"fields": {"kind": _literal("continue")},
				},
			},
		],
	}
	var completion_behavior := {
		"id": completion_behavior_id,
		"name": "Complete the Offer",
		"description": "Runs after the encounter resolves.",
		"kind": "entry",
		"role": "encounter",
		"hook": "complete",
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "encounter-outcome",
		"requestedCapabilities": ["core.presentation.text"],
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(completion_program),
		"program": completion_program,
	}
	var availability_program := {
		"kind": "function",
		"name": "fixture_refuse_available",
		"parameters": [],
		"returnType": "bool",
		"body": [{
			"kind": "return",
			"value": _literal(false),
		}],
	}
	var availability_behavior := {
		"id": availability_behavior_id,
		"name": "Refuse is unavailable",
		"description": "Exercises pure encounter choice availability.",
		"kind": "helper",
		"role": "helper",
		"hook": "",
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "bool",
		"requestedCapabilities": [],
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(availability_program),
		"program": availability_program,
	}
	var remembered_program := {
		"kind": "function",
		"name": "fixture_encounter_remembered",
		"parameters": [],
		"returnType": "encounter-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {"text": _literal("The city remembers you.")},
			},
			{
				"kind": "return",
				"value": {
					"kind": "record",
					"fields": {"kind": _literal("continue")},
				},
			},
		],
	}
	var remembered_behavior := _safe_behavior(
		remembered_behavior_id,
		"Remembered Arrival",
		"entry",
		"encounter",
		"enter",
		"encounter-outcome",
		["core.presentation.text"],
		remembered_program,
		state_schema
	)
	var remembered_condition_program := {
		"kind": "function",
		"name": "fixture_encounter_is_remembered",
		"parameters": [],
		"returnType": "bool",
		"body": [{"kind": "return", "value": _literal(true)}],
	}
	var remembered_condition := _safe_behavior(
		remembered_condition_id,
		"City Remembers Party",
		"helper",
		"helper",
		"",
		"bool",
		[],
		remembered_condition_program,
		state_schema
	)
	var encounter_id := "scenario.fixture.encounter"
	var opening_id := "%s.opening" % encounter_id
	var stable_id := "%s.stable" % encounter_id
	var bundle := BundleScript.new()
	bundle.manifest = {
		"format": "realmz-remake-scenario",
		"formatVersion": 3,
		"campaignKind": "remake-authored",
		"id": "fixture.remake-authored-encounter",
		"name": "Remake Authored Encounter Fixture",
		"contentVersion": "0.1.0",
		"integrity": {"packageHash": "c".repeat(64)},
	}
	bundle.documents = {
		"scenario": {
			"startup": {"mapId": "land:0", "x": 2, "y": 2},
		},
		"remakeLogic": {
			"schemaVersion": 5,
			"kind": "remake-authored",
			"mapTriggers": [],
			"eventTriggers": [],
			"scheduledTriggers": [],
			"encounters": [{
				"id": encounter_id,
				"name": "Beastmaster's Offer",
				"entrySectionId": opening_id,
				"entryBehaviorId": behavior_id,
				"completionBehaviorId": completion_behavior_id,
				"repeatPolicy": "once",
				"defaultVariantId": "%s.default" % encounter_id,
				"variants": [
					{
						"id": "%s.remembered" % encounter_id,
						"name": "Remembered",
						"conditionBehaviorId": remembered_condition_id,
						"behaviorId": remembered_behavior_id,
					},
					{
						"id": "%s.default" % encounter_id,
						"name": "Default",
						"conditionBehaviorId": null,
						"behaviorId": behavior_id,
					},
				],
				"sections": [
					{
						"id": opening_id,
						"name": "The Offer",
						"text": (
							"A man offers work involving a stable of wild beasts."
						),
						"pictureId": "41",
						"soundId": "42",
						"presentation": {},
						"responses": [
							{
								"id": "%s.accept" % opening_id,
								"kind": "choice",
								"label": "Accept the work",
								"match": {},
								"availabilityBehaviorId": null,
								"selectionBehaviorId": null,
								"resultId": "%s.accept-result" % opening_id,
							},
							{
								"id": "%s.refuse" % opening_id,
								"kind": "choice",
								"label": "Refuse",
								"match": {},
								"availabilityBehaviorId": availability_behavior_id,
								"selectionBehaviorId": null,
								"resultId": "%s.refuse-result" % opening_id,
							},
						],
					},
					{
						"id": stable_id,
						"name": "At the Stable",
						"text": "The beasts turn on you.",
						"pictureId": null,
						"soundId": null,
						"presentation": {},
						"responses": [{
							"id": "%s.fight" % stable_id,
							"kind": "choice",
							"label": "Fight",
							"match": {},
							"availabilityBehaviorId": null,
							"selectionBehaviorId": null,
							"resultId": "%s.fight-result" % stable_id,
						}],
					},
				],
				"results": [
					{
						"id": "%s.accept-result" % opening_id,
						"name": "Accept the Work",
						"behaviorId": null,
						"terminal": {"kind": "section", "sectionId": stable_id},
					},
					{
						"id": "%s.refuse-result" % opening_id,
						"name": "Refuse",
						"behaviorId": null,
						"terminal": {"kind": "close"},
					},
					{
						"id": "%s.fight-result" % stable_id,
						"name": "Fight the Beasts",
						"behaviorId": result_behavior_id,
						"terminal": {"kind": "close"},
					},
				],
			}],
		},
		"remakeScripts": {
			"schemaVersion": 3,
			"apiVersion": 2,
			"capabilityCatalogHash": catalog.catalog_hash(),
			"behaviors": [
				behavior,
				result_behavior,
				completion_behavior,
				availability_behavior,
				remembered_behavior,
				remembered_condition,
			],
			"bindings": [],
			"stateDefinitions": [],
			"migrations": [],
		},
		"runtime": {
			"recommendedGameplayProfile": "core.classic",
			"requiredPlugins": [],
		},
	}
	return bundle


func _state_variant_bundle() -> ScenarioCampaignBundle:
	var catalog := CapabilityCatalogScript.new()
	catalog.load_builtin()
	var trigger_id := "scenario.fixture.stateful-trigger"
	var default_id := "%s.default" % trigger_id
	var opened_id := "%s.opened" % trigger_id
	var default_program := {
		"kind": "function",
		"name": "open_the_gate",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.state.write",
				"arguments": {
					"scope": _literal("map"),
					"name": _literal("opened"),
					"value": _literal(true),
				},
			},
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {"text": _literal("First visit")},
			},
			_action_return(),
		],
	}
	var opened_program := {
		"kind": "function",
		"name": "return_to_the_gate",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {"text": _literal("Already opened")},
			},
			_action_return(),
		],
	}
	var condition_program := {
		"kind": "function",
		"name": "gate_is_open",
		"parameters": [],
		"returnType": "bool",
		"body": [{
			"kind": "return",
			"value": {
				"kind": "variable",
				"scope": "persistent",
				"stateScope": "map",
				"ownerId": "",
				"name": "opened",
			},
		}],
	}
	var state_schema := {}
	var default_behavior := _safe_behavior(
		"%s.run" % default_id,
		"Open the Gate",
		"entry",
		"action",
		"run",
		"action-outcome",
		["core.state.write", "core.presentation.text"],
		default_program,
		state_schema
	)
	var opened_behavior := _safe_behavior(
		"%s.run" % opened_id,
		"Already Open",
		"entry",
		"action",
		"run",
		"action-outcome",
		["core.presentation.text"],
		opened_program,
		state_schema
	)
	var condition_behavior := _safe_behavior(
		"%s.condition" % opened_id,
		"Gate Is Open",
		"helper",
		"helper",
		"",
		"bool",
		[],
		condition_program,
		state_schema
	)
	var bundle := BundleScript.new()
	bundle.manifest = {
		"format": "realmz-remake-scenario",
		"formatVersion": 3,
		"campaignKind": "remake-authored",
		"id": "fixture.remake-authored-state-variants",
		"name": "Typed State and Variants Fixture",
		"contentVersion": "0.1.0",
		"integrity": {"packageHash": "d".repeat(64)},
	}
	bundle.documents = {
		"scenario": {
			"startup": {"mapId": "land:0", "x": 2, "y": 2},
		},
		"remakeLogic": {
			"schemaVersion": 5,
			"kind": "remake-authored",
			"mapTriggers": [{
				"id": trigger_id,
				"name": "Stateful Gate",
				"location": {
					"kind": "point",
					"mapId": "land:0",
					"x": 2,
					"y": 2,
					"width": 1,
					"height": 1,
				},
				"event": "enter",
				"enabled": true,
				"chance": 100,
				"priority": 0,
				"repeatPolicy": "always",
				"defaultVariantId": default_id,
				"variants": [
					{
						"id": opened_id,
						"name": "Already Open",
						"conditionBehaviorId": condition_behavior["id"],
						"behaviorId": opened_behavior["id"],
					},
					{
						"id": default_id,
						"name": "First Visit",
						"conditionBehaviorId": null,
						"behaviorId": default_behavior["id"],
					},
				],
				"activationConditionBehaviorId": null,
			}],
			"eventTriggers": [],
			"scheduledTriggers": [],
			"encounters": [],
		},
		"remakeScripts": {
			"schemaVersion": 3,
			"apiVersion": 2,
			"capabilityCatalogHash": catalog.catalog_hash(),
			"behaviors": [
				default_behavior,
				opened_behavior,
				condition_behavior,
			],
			"bindings": [],
			"stateDefinitions": [{
				"name": "opened",
				"displayName": "Gate Opened",
				"documentation": "Tracks the gate independently on each map.",
				"scope": "map",
				"ownerId": "",
				"schemaVersion": 1,
				"valueType": "bool",
				"maxLength": null,
				"defaultValue": false,
			}],
			"migrations": [],
		},
		"runtime": {
			"recommendedGameplayProfile": "core.classic",
			"requiredPlugins": [],
		},
	}
	return bundle


func _event_schedule_bundle() -> ScenarioCampaignBundle:
	var catalog := CapabilityCatalogScript.new()
	catalog.load_builtin()
	var behaviors := [
		_safe_behavior(
			"scenario.fixture.event-first.run",
			"First Map Event",
			"entry",
			"action",
			"run",
			"action-outcome",
			["core.presentation.text"],
			_text_action_program("event_first", "First map event"),
			{}
		),
		_safe_behavior(
			"scenario.fixture.event-second.run",
			"Second Map Event",
			"entry",
			"action",
			"run",
			"action-outcome",
			["core.presentation.text"],
			_text_action_program("event_second", "Second map event"),
			{}
		),
		_safe_behavior(
			"scenario.fixture.hourly.run",
			"Hourly Bell",
			"entry",
			"action",
			"run",
			"action-outcome",
			["core.presentation.text"],
			_text_action_program(
				"hourly_bell",
				"The hourly bell rings."
			),
			{}
		),
	]
	var bundle := BundleScript.new()
	bundle.manifest = {
		"format": "realmz-remake-scenario",
		"formatVersion": 3,
		"campaignKind": "remake-authored",
		"id": "fixture.remake-authored-events",
		"name": "Event and Scheduled Trigger Fixture",
		"contentVersion": "0.1.0",
		"integrity": {"packageHash": "e".repeat(64)},
	}
	bundle.documents = {
		"scenario": {
			"startup": {"mapId": "land:0", "x": 2, "y": 2},
		},
		"remakeLogic": {
			"schemaVersion": 5,
			"kind": "remake-authored",
			"mapTriggers": [],
			"eventTriggers": [
				{
					"id": "scenario.fixture.event-second",
					"name": "Second Map Event",
					"event": "map-enter",
					"enabled": true,
					"priority": 20,
					"conditionBehaviorId": null,
					"behaviorId": "scenario.fixture.event-second.run",
				},
				{
					"id": "scenario.fixture.event-first",
					"name": "First Map Event",
					"event": "map-enter",
					"enabled": true,
					"priority": 10,
					"conditionBehaviorId": null,
					"behaviorId": "scenario.fixture.event-first.run",
				},
			],
			"scheduledTriggers": [{
				"id": "scenario.fixture.hourly",
				"name": "Hourly Bell",
				"enabled": true,
				"priority": 0,
				"schedule": {
					"kind": "recurring",
					"day": null,
					"minute": null,
					"elapsedMinutes": null,
					"intervalMinutes": 60,
				},
				"location": {
					"kind": "point",
					"mapId": "land:0",
					"x": 2,
					"y": 2,
					"width": 1,
					"height": 1,
				},
				"conditionBehaviorId": null,
				"behaviorId": "scenario.fixture.hourly.run",
			}],
			"encounters": [],
		},
		"remakeScripts": {
			"schemaVersion": 3,
			"apiVersion": 2,
			"capabilityCatalogHash": catalog.catalog_hash(),
			"behaviors": behaviors,
			"bindings": [],
			"stateDefinitions": [],
			"migrations": [],
		},
		"runtime": {
			"recommendedGameplayProfile": "core.classic",
			"requiredPlugins": [],
		},
	}
	return bundle


static func _text_action_program(name: String, text: String) -> Dictionary:
	return {
		"kind": "function",
		"name": name,
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {"text": _literal(text)},
			},
			_action_return(),
		],
	}


static func _safe_behavior(
	id: String,
	name: String,
	kind: String,
	role: String,
	hook: String,
	return_type: String,
	capabilities: Array,
	program: Dictionary,
	state_schema: Dictionary
) -> Dictionary:
	return {
		"id": id,
		"name": name,
		"description": name,
		"kind": kind,
		"role": role,
		"hook": hook,
		"libraryScope": "project",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": return_type,
		"requestedCapabilities": capabilities,
		"stateSchema": state_schema,
		"stateSchemaHash": ScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {},
		"contentHash": ScriptRuntimeScript._sha256_json(program),
		"program": program,
	}


static func _action_return() -> Dictionary:
	return {
		"kind": "return",
		"value": {
			"kind": "record",
			"fields": {"kind": _literal("continue")},
		},
	}


static func _literal(value: Variant) -> Dictionary:
	return {"kind": "literal", "value": value}


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		failures += 1
		push_error("FAIL: %s" % label)
