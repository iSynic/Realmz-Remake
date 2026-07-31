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

var failures := 0


func _ready() -> void:
	await _test_map_trigger_execution_and_restore()
	await _test_modern_encounter_execution_and_restore()
	if failures == 0:
		print("Remake Authored scenario logic tests passed")
		get_tree().quit(0)
	else:
		push_error("Remake Authored Map Trigger tests failed: %d" % failures)
		get_tree().quit(1)


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
			and save_result.get("save", {}).get("schemaVersion") == 6
			and save_result.get("save", {}).get("pendingCommand") is Dictionary,
		"pending Map Trigger produces a schema-6 save"
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
	var result := session.begin_encounter("scenario.fixture.encounter")
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_picture",
		"Modern Encounter presents its opening picture"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "play_sound",
		"Modern Encounter resumes into its opening sound"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "show_text",
		"Modern Encounter presents node text"
	)
	result = await _route_and_resume(session, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "choice"
			and result.get("request", {}).get("options") == [
				"Accept the work",
			],
		"Modern Encounter filters choices through a pure availability Behavior"
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
			and result.get("commandId") == "show_text"
			and result.get("request", {}).get("text") == "The beasts turn on you.",
		"selected choice branches to the named destination scene"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "choice",
		"destination scene presents its choices"
	)
	result = await _route_and_resume(restored, result)
	_expect(
		result.get("status") == "yield"
			and result.get("commandId") == "start_battle"
			and result.get("request", {}).get("battleId") == 7,
		"selected result Behavior yields a battle through the Combat port"
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
			"schemaVersion": 3,
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
			"schemaVersion": 2,
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
	var program := {
		"kind": "function",
		"name": "fixture_encounter_default",
		"parameters": [],
		"returnType": "encounter-outcome",
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
		"returnType": "encounter-outcome",
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
		"role": "encounter",
		"hook": "result",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "encounter-outcome",
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
			"schemaVersion": 3,
			"kind": "remake-authored",
			"mapTriggers": [],
			"eventTriggers": [],
			"scheduledTriggers": [],
			"encounters": [{
				"id": encounter_id,
				"name": "Beastmaster's Offer",
				"entryNodeId": opening_id,
				"entryBehaviorId": behavior_id,
				"completionBehaviorId": completion_behavior_id,
				"repeatPolicy": "once",
				"defaultVariantId": "%s.default" % encounter_id,
				"variants": [{
					"id": "%s.default" % encounter_id,
					"name": "Default",
					"conditionBehaviorId": null,
					"behaviorId": behavior_id,
				}],
				"nodes": [
					{
						"id": opening_id,
						"name": "The Offer",
						"text": (
							"A man offers work involving a stable of wild beasts."
						),
						"pictureId": "41",
						"soundId": "42",
						"presentation": {},
						"choices": [
							{
								"id": "%s.accept" % opening_id,
								"label": "Accept the work",
								"availabilityBehaviorId": null,
								"selectionBehaviorId": null,
								"nextNodeId": stable_id,
								"outcome": "branch",
							},
							{
								"id": "%s.refuse" % opening_id,
								"label": "Refuse",
								"availabilityBehaviorId": availability_behavior_id,
								"selectionBehaviorId": null,
								"nextNodeId": null,
								"outcome": "close",
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
						"choices": [{
							"id": "%s.fight" % stable_id,
							"label": "Fight",
							"availabilityBehaviorId": null,
							"selectionBehaviorId": result_behavior_id,
							"nextNodeId": null,
							"outcome": "resolve",
						}],
					},
				],
			}],
		},
		"remakeScripts": {
			"schemaVersion": 2,
			"apiVersion": 2,
			"capabilityCatalogHash": catalog.catalog_hash(),
			"behaviors": [
				behavior,
				result_behavior,
				completion_behavior,
				availability_behavior,
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


static func _literal(value: Variant) -> Dictionary:
	return {"kind": "literal", "value": value}


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		failures += 1
		push_error("FAIL: %s" % label)
