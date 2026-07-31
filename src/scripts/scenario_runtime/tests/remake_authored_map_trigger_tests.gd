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
	if failures == 0:
		print("Remake Authored Map Trigger tests passed")
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


static func _literal(value: Variant) -> Dictionary:
	return {"kind": "literal", "value": value}


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		failures += 1
		push_error("FAIL: %s" % label)
