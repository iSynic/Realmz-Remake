extends Node

const BundleScript = preload(
	"res://scripts/classic_runtime/classic_campaign_bundle.gd"
)
const CampaignSessionScript = preload(
	"res://scripts/classic_runtime/classic_campaign_session.gd"
)
const ClassicRuntimeStateScript = preload(
	"res://scripts/classic_runtime/classic_runtime_state.gd"
)
const ClassicOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_opcode_runtime.gd"
)
const CoreHandlersScript = preload(
	"res://scripts/scenario_runtime/handlers/core_handler_catalog.gd"
)
const FixtureHandlerScript = preload(
	"res://scripts/scenario_runtime/extensions/runtime_fixture_handler.gd"
)
const DefaultPortsScript = preload(
	"res://scripts/scenario_runtime/default_scenario_ports.gd"
)
const ExtensionRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_extension_registry.gd"
)
const RuleRegistryScript = preload(
	"res://scripts/scenario_runtime/gameplay_rule_registry.gd"
)
const InstructionRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_instruction_registry.gd"
)
const InterpreterScript = preload(
	"res://scripts/scenario_runtime/scenario_interpreter.gd"
)
const CapabilityCatalogScript = preload(
	"res://scripts/scenario_runtime/scenario_capability_catalog.gd"
)
const ScenarioScriptRuntimeScript = preload(
	"res://scripts/scenario_runtime/scenario_script_runtime.gd"
)
const ScenarioScriptHandlerScript = preload(
	"res://scripts/scenario_runtime/handlers/scenario_script_handler.gd"
)
const ScenarioStepResultScript = preload(
	"res://scripts/scenario_runtime/scenario_step_result.gd"
)
const ScenarioGodotServicesScript = preload(
	"res://scripts/scenario_runtime/godot/scenario_godot_services.gd"
)
const HostScript = preload(
	"res://scripts/classic_runtime/classic_runtime_host.gd"
)
const RuntimeScript = preload(
	"res://scripts/classic_runtime/classic_runtime.gd"
)
const RuleModifierPipelineScript = preload(
	"res://scripts/scenario_runtime/scenario_rule_modifier_pipeline.gd"
)

const V3_FIXTURE := \
	"res://scripts/classic_runtime/tests/fixtures/war_in_the_sword_lands_gosub"
const V1_FIXTURE := \
	"res://scripts/scenario_runtime/tests/fixtures/v1_rejected"

var failures := 0


func _ready() -> void:
	_test_v3_bundle_contract()
	_test_extension_registry()
	await _test_gameplay_rules()
	_test_handler_registry()
	_test_command_ports()
	_test_scenario_vm()
	_test_classic_execution_state_ownership()
	_test_classic_dispatcher_noops()
	await _test_builtin_extension_execution()
	_test_safe_script_quest_slice()
	_test_nested_safe_behavior_execution()
	_test_spell_effect_lifecycle()
	_test_campaign_completion_state()
	_test_behavior_role_capability_validation()
	_test_typed_role_outcomes()
	await _test_rule_modifier_pipeline()
	await _test_native_spell_behavior_hooks()
	_test_old_save_rejection()
	if failures == 0:
		print("Scenario runtime tests passed")
		get_tree().quit(0)
	else:
		push_error("Scenario runtime tests failed: %d" % failures)
		get_tree().quit(1)


func _test_v3_bundle_contract() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "v3 bundle loads")
	if not bundle.last_error.is_empty():
		push_error(bundle.last_error)
	_expect(
		str(bundle.manifest.get("format", "")) == "realmz-remake-scenario",
		"v3 bundle uses generalized identity"
	)
	_expect(bundle.documents.has("runtime"), "v3 bundle includes runtime document")
	var action: Dictionary = bundle.documents["scripts"]["triggers"][0]["actions"][0]
	_expect(action.get("kind") == "classic", "Classic instruction kind is explicit")
	_expect(action.get("rawCode") == action.get("code"), "Classic instruction preserves raw code")

	var old_bundle := BundleScript.new()
	_expect(not old_bundle.load_from_directory(V1_FIXTURE), "v1 bundle is rejected")
	_expect(
		old_bundle.last_error.contains("Unsupported scenario campaign format"),
		"obsolete bundle rejection identifies the unsupported contract"
	)


func _test_extension_registry() -> void:
	var registry := ExtensionRegistryScript.new()
	_expect(registry.load_builtin_catalog(), "built-in extension catalog loads")
	var valid := registry.validate_requirements([{
		"id": "scenario.runtime-fixture",
		"apiVersion": 1,
		"configuration": {"marker": "test"},
	}])
	_expect(bool(valid.get("valid", false)), "built-in extension requirement resolves")
	_expect(
		not registry.binding_descriptor(
			"semanticOperations", "scenario.runtime-fixture.mark"
		).is_empty(),
		"semantic operation exposes its authoring schema"
	)
	var missing := registry.validate_requirements([{
		"id": "scenario.missing",
		"apiVersion": 1,
		"configuration": {},
	}])
	_expect(not bool(missing.get("valid", false)), "missing extension blocks readiness")
	var invalid_configuration := registry.validate_requirements([{
		"id": "scenario.runtime-fixture",
		"apiVersion": 1,
		"configuration": {"unknown": true},
	}])
	_expect(
		not bool(invalid_configuration.get("valid", false)),
		"extension configuration is checked against its schema"
	)
	var replacement := registry.register_descriptor({
		"id": "scenario.invalid",
		"apiVersion": 1,
		"capabilities": {"commands": ["core.teleport"]},
	})
	_expect(not replacement, "extension cannot replace a reserved core binding")


func _test_gameplay_rules() -> void:
	var registry := RuleRegistryScript.new()
	_expect(registry.load_builtin_catalog(), "gameplay rule catalog loads")
	var classic_result := registry.resolve("core.classic")
	var samuel_result := registry.resolve("core.samuel")
	_expect(classic_result.get("status") == "ok", "Classic gameplay preset resolves")
	_expect(samuel_result.get("status") == "ok", "Samuel gameplay preset resolves")
	if classic_result.get("status") != "ok" or samuel_result.get("status") != "ok":
		return
	var classic: GameplayRuleSet = classic_result["ruleset"]
	var samuel: GameplayRuleSet = samuel_result["ruleset"]
	_expect(
		classic.provider_id("mapTime") != samuel.provider_id("mapTime"),
		"Classic and Samuel map providers are distinct"
	)
	var advertised_options: Dictionary = {}
	for provider_value: Variant in registry.catalog().get("providers", []):
		if not (provider_value is Dictionary) \
				or not str(provider_value.get("id", "")).begins_with("core."):
			continue
		for option_id: String in provider_value.get("options", {}):
			advertised_options[option_id] = true
	for unsupported_option: String in [
		"minutesPerStep",
		"initiative",
		"enforceUniqueItems",
		"statistics",
		"pacing",
		"strictContentHash",
	]:
		_expect(
			not advertised_options.has(unsupported_option),
			"rules catalog does not advertise unwired option '%s'" % unsupported_option
		)
	var mixed_result := registry.resolve("core.classic", {
		"combat": {"providerId": "core.samuel.combat"},
		"presentation": {
			"providerId": "scenario.runtime-fixture.presentation-rules",
			"options": {"fixtureMarker": true},
		},
	})
	_expect(mixed_result.get("status") == "ok", "domain-mixed gameplay rules resolve")
	if mixed_result.get("status") == "ok":
		var mixed: GameplayRuleSet = mixed_result["ruleset"]
		_expect(
			mixed.provider_id("combat") == samuel.provider_id("combat"),
			"mixed rules replace the selected domain"
		)
		_expect(
			mixed.provider_id("mapTime") == classic.provider_id("mapTime"),
			"mixed rules preserve unselected domains"
		)
		_expect(
			mixed.provider_id("presentation")
				== "scenario.runtime-fixture.presentation-rules",
			"built-in extension rule provider can replace one domain"
		)
		var restored := registry.restore(mixed.snapshot())
		_expect(restored.get("status") == "ok", "save-pinned rules restore exactly")
		var mixed_ports := DefaultPortsScript.create(RefCounted.new(), mixed)
		_expect(
			mixed_ports.get("status") == "ok",
			"mixed rules configure the six command ports"
		)
		if mixed_ports.get("status") == "ok":
			var mixed_router: ScenarioCommandRouter = mixed_ports["router"]
			var macro_result: Dictionary = await mixed_router.route(
				"activate_battle_round_macro",
				{}
			)
			_expect(
				bool(macro_result.get("skipped", false)),
				"Samuel combat provider disables Classic battle macros"
			)
			var condition_result: Dictionary = await mixed_router.route(
				"give_character_condition",
				{}
			)
			_expect(
				str(condition_result.get("status", "")) == "error",
				"mixed profile leaves the Classic character domain unchanged"
			)
	var samuel_ports := DefaultPortsScript.create(RefCounted.new(), samuel)
	_expect(
		samuel_ports.get("status") == "ok",
		"Samuel rules configure the six command ports"
	)
	if samuel_ports.get("status") == "ok":
		var samuel_router: ScenarioCommandRouter = samuel_ports["router"]
		var condition_result: Dictionary = await samuel_router.route(
			"give_character_condition",
			{}
		)
		_expect(
			bool(condition_result.get("skipped", false)),
			"Samuel character provider omits Classic-only conditions"
		)
		var click_result: Dictionary = await samuel_router.route(
			"wait_for_click",
			{}
		)
		_expect(
			bool(click_result.get("skipped", false)),
			"Samuel presentation provider skips authored click pacing"
		)


func _test_handler_registry() -> void:
	var registry := InstructionRegistryScript.new()
	_expect(CoreHandlersScript.register_all(registry), "core opcode families register")
	_expect(
		registry.registered_classic_opcodes() \
			== PackedInt32Array(ClassicOpcodeRuntimeScript.HANDLED_OPCODES),
		"every supported Classic opcode registers exactly once"
	)
	var fixture_handler := FixtureHandlerScript.new()
	_expect(registry.register_handler(fixture_handler), "semantic fixture handler registers")
	_expect(
		not registry.register_handler(FixtureHandlerScript.new()),
		"duplicate handler registration is rejected"
	)


func _test_command_ports() -> void:
	var result := DefaultPortsScript.create(RefCounted.new())
	_expect(result.get("status") == "ok", "six default command ports register")
	if result.get("status") != "ok":
		return
	var router: ScenarioCommandRouter = result["router"]
	for command_id: String in [
		"teleport",
		"start_battle",
		"give_treasure",
		"pick_characters",
		"show_text",
		"snapshot_runtime",
		"complete_campaign",
	]:
		_expect(
			router.port_for_command(command_id) != null,
			"command '%s' has one port owner" % command_id
		)
		var port := router.port_for_command(command_id)
		_expect(
			port.request_contracts().has(command_id)
				and port.response_contracts().has(command_id),
			"command '%s' declares request and response contracts" % command_id
		)
	var production_result := DefaultPortsScript.create(
		ScenarioGodotServicesScript.new()
	)
	_expect(
		production_result.get("status") == "ok",
		"production Godot service implements every owned command operation"
	)
	var incomplete_result := DefaultPortsScript.create(
		IncompleteScenarioGodotServices.new()
	)
	_expect(
		incomplete_result.get("status") == "error"
			and str(incomplete_result.get("message", "")).contains(
				"requires missing Godot service method"
		),
		"production service contract rejects a missing command operation"
	)
	var encounter_services := ScenarioGodotServicesScript.new()
	var simple_choices: Dictionary = encounter_services.build_simple_encounter_choices({
		"texts": ["First", "", "Third"],
		"choiceResults": [2, 0, 4],
	})
	_expect(
		simple_choices.get("slots", []) == [0, 2]
			and simple_choices.get("outcomes", []) == ["2", "4"],
		"simple encounter choices retain authored option slots"
	)
	var complex_choices: Dictionary = encounter_services.build_complex_action_choices({
		"texts": ["Look", "*", "Leave"],
		"actionResult": 3,
	}, false)
	_expect(
		complex_choices.get("slots", []) == [0, 2]
			and complex_choices.get("tokens", []) == ["action:3", "action:3"],
		"complex encounter choices retain authored option slots"
	)


func _test_scenario_vm() -> void:
	var registry := InstructionRegistryScript.new()
	_expect(
		registry.register_handler(FixtureHandlerScript.new()),
		"VM fixture handler registers"
	)
	var vm := InterpreterScript.new()
	vm.configure(registry, {
		"fixture": {
			"id": "fixture",
			"actions": [{
				"kind": "semantic",
				"slot": 0,
				"operation": "scenario.runtime-fixture.mark",
				"parameters": {"marker": "vm"},
			}],
		},
	})
	_expect(vm.start("fixture").get("status") == "ok", "VM starts a semantic trigger")
	var yielded := vm.run(RefCounted.new())
	_expect(yielded.get("status") == "yield", "VM yields one routed command")
	_expect(
		yielded.get("commandId") == "scenario.runtime-fixture.present",
		"VM preserves semantic command identity"
	)
	var snapshot := vm.snapshot()
	_expect(
		InterpreterScript.validate_snapshot(snapshot).get("valid") == true,
		"VM snapshot validates with one pending record"
	)
	var resumed := vm.resume({"status": "ok"}, RefCounted.new())
	_expect(resumed.get("status") == "complete", "VM resumes through its owning handler")


func _test_classic_execution_state_ownership() -> void:
	var bundle := BundleScript.new()
	bundle.manifest = {
		"start": {
			"levelType": "land",
			"levelIndex": 0,
			"x": 0,
			"y": 0,
		},
	}
	var trigger := {
		"id": "Data ED3:macro:12",
		"source": "Data ED3",
		"recordIndex": 12,
		"actions": [],
	}
	var next_trigger := {
		"id": "Data ED3:macro:13",
		"source": "Data ED3",
		"recordIndex": 13,
		"actions": [],
	}
	bundle.triggers_by_id[trigger["id"]] = trigger
	bundle.triggers_by_id[next_trigger["id"]] = next_trigger
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var vm := InterpreterScript.new()
	vm.configure(bundle, state)
	_expect(
		vm.classic_execution_state != null,
		"Classic VM owns its execution state"
	)
	_expect(
		vm.begin_trigger(trigger["id"]),
		"Classic VM starts an interpreter-owned execution state"
	)
	_expect(
		vm.classic_execution_state.current_trigger.get("id") \
			== trigger["id"],
		"Classic cursor is stored on the interpreter-owned state"
	)
	var saved := vm.make_execution_snapshot()
	_expect(
		saved.get("status") == "ok",
		"Interpreter-owned Classic state produces a save snapshot"
	)
	var restored_state := ClassicRuntimeStateScript.new()
	restored_state.configure_from_bundle(bundle)
	var restored_vm := InterpreterScript.new()
	restored_vm.configure(bundle, restored_state)
	_expect(
		restored_vm.restore_execution_snapshot(
			saved.get("snapshot", {})
		).get("status") == "ok",
		"Interpreter-owned Classic state restores a save snapshot"
	)
	_expect(
		restored_vm.classic_execution_state.current_trigger.get("id") \
			== trigger["id"],
		"Restored Classic cursor remains interpreter-owned"
	)
	restored_vm.classic_execution_state.loaded_simple_encounter_id = 41
	restored_vm.classic_execution_state.loaded_complex_encounter_id = 42
	_expect(
		restored_vm.begin_trigger(next_trigger["id"]),
		"Classic VM starts a later action point"
	)
	_expect(
		restored_vm.classic_execution_state.loaded_simple_encounter_id == 41
			and restored_vm.classic_execution_state.loaded_complex_encounter_id == 42,
		"Loaded encounter buffers survive action-point activation"
	)


func _test_classic_dispatcher_noops() -> void:
	var bundle := BundleScript.new()
	bundle.manifest = {
		"start": {"levelType": "land", "levelIndex": 0, "x": 0, "y": 0},
	}
	var trigger := {
		"id": "Data ED3:macro:73",
		"source": "Data ED3",
		"recordIndex": 73,
		"actions": [{
			"kind": "classic",
			"slot": 2,
			"rawCode": 200,
			"code": 200,
			"id": 0,
			"gosub": false,
		}],
	}
	bundle.triggers_by_id[trigger["id"]] = trigger
	bundle.dispatcher_noop_keys["Data ED3:macro:73:2:200"] = true
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var vm := InterpreterScript.new()
	vm.configure(bundle, state)
	_expect(
		vm.begin_trigger(trigger["id"], 2),
		"Classic VM starts an evidence-listed dispatcher no-op"
	)
	var result := vm.run_until_yield()
	_expect(
		result.get("status") == "completed",
		"Classic VM skips an evidence-listed dispatcher no-op"
	)
	_expect(
		vm.trace.size() == 1 and vm.trace[0].get("code") == 200,
		"Classic VM keeps a skipped dispatcher no-op in its trace"
	)

	bundle.dispatcher_noop_keys.clear()
	state = ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	vm = InterpreterScript.new()
	vm.configure(bundle, state)
	_expect(
		vm.begin_trigger(trigger["id"], 2),
		"Classic VM starts an unsupported dispatcher opcode fixture"
	)
	result = vm.run_until_yield()
	_expect(
		result.get("status") == "unsupported",
		"Classic VM reports an opcode without dispatcher no-op evidence"
	)


func _test_builtin_extension_execution() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "extension host fixture bundle loads")
	if not bundle.last_error.is_empty():
		return
	bundle.documents["runtime"]["requiredExtensions"] = [{
		"id": "scenario.runtime-fixture",
		"apiVersion": 1,
		"configuration": {"marker": "host"},
	}]
	bundle.documents["runtime"]["bindings"] = {
		"spells": {
			"echo": {
				"kind": "extension",
				"providerId": "scenario.runtime-fixture.echo-spell",
			},
		},
		"items": {
			"echo": {
				"kind": "extension",
				"providerId": "scenario.runtime-fixture.echo-item",
			},
		},
		"encounters": {
			"echo": {
				"kind": "extension",
				"providerId": "scenario.runtime-fixture.echo-encounter",
			},
		},
		"monsterAi": {
			"echo": {
				"kind": "extension",
				"providerId": "scenario.runtime-fixture.echo-ai",
			},
		},
		"lifecycle": {
			"load": {
				"kind": "extension",
				"providerId": "scenario.runtime-fixture.lifecycle",
			},
		},
		"ruleModifiers": {},
	}
	bundle.documents["scripts"]["triggers"].append({
		"id": "scenario-runtime:semantic",
		"source": "Remake runtime fixture",
		"recordIndex": 0,
		"active": true,
		"callable": true,
		"actions": [{
			"kind": "semantic",
			"slot": 0,
			"operation": "scenario.runtime-fixture.mark",
			"parameters": {"marker": "host"},
		}],
	})
	_expect(
		bundle._validate_document_contract(),
		"compiled campaign accepts a declared built-in semantic operation"
	)
	if not bundle.last_error.is_empty():
		return
	bundle._build_indexes()
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var interpreter := InterpreterScript.new()
	interpreter.configure(bundle, state)
	_expect(
		interpreter.begin_trigger("scenario-runtime:semantic"),
		"semantic operation starts through Classic compatibility"
	)
	var semantic_yield := interpreter.run_until_yield()
	_expect(
		semantic_yield.get("command") == "scenario.runtime-fixture.present",
		"semantic compatibility execution yields its extension command"
	)
	var waiting := interpreter.run_until_yield()
	_expect(
		waiting.get("status") == "error"
			and str(waiting.get("message", "")).contains("waiting"),
		"semantic extension commands wait for an explicit response"
	)
	_expect(
		interpreter.pending_command != null,
		"waiting preserves the semantic extension continuation"
	)
	_expect(
		interpreter.resume_command({"status": "ok"}).get("status") == "completed",
		"semantic extension resumes only after its required response"
	)
	var host := HostScript.new()
	add_child(host)
	host.configure(RefCounted.new())
	var commands: Array[String] = []
	var completions: Array[Dictionary] = []
	host.command_started.connect(func(command: String, _payload: Dictionary) -> void:
		commands.append(command)
	)
	host.playthrough_completed.connect(func(result: Dictionary) -> void:
		completions.append(result)
	)
	host.use_campaign(bundle)
	_expect(
		host.start_trigger("scenario-runtime:semantic"),
		"semantic operation starts through the normal runtime host"
	)
	await get_tree().process_frame
	_expect(
		commands == ["scenario.runtime-fixture.present"],
		"semantic operation yields its built-in extension command"
	)
	_expect(
		completions.size() == 1,
		"semantic extension resumes through its handler to completion"
	)
	for capability_and_binding: Array in [
		["spells", "scenario.runtime-fixture.echo-spell"],
		["itemBehaviors", "scenario.runtime-fixture.echo-item"],
		["encounterResolvers", "scenario.runtime-fixture.echo-encounter"],
		["monsterAiProviders", "scenario.runtime-fixture.echo-ai"],
		["lifecycleHooks", "scenario.runtime-fixture.lifecycle"],
	]:
		var provider_result := bundle.extension_registry.invoke_binding(
			capability_and_binding[0],
			capability_and_binding[1],
			{"fixture": true},
			host
		)
		_expect(
			provider_result.get("status") == "ok"
				and provider_result.get("marker") == "host",
			"built-in fixture invokes %s" % capability_and_binding[0]
		)
	host.queue_free()


func _test_safe_script_quest_slice() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "safe script fixture bundle loads")
	if not bundle.last_error.is_empty():
		return
	var program := {
		"kind": "function",
		"name": "offer_quest",
		"parameters": [],
		"returnType": "void",
		"body": [
			{
				"kind": "operation",
				"capability": "core.state.write",
				"arguments": {
					"scope": {"kind": "literal", "value": "quest"},
					"id": {"kind": "literal", "value": 42},
					"value": {"kind": "literal", "value": 1},
				},
				"sourceNode": "quest-write",
			},
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {
					"text": {"kind": "literal", "value": "The quest has begun."},
				},
				"sourceNode": "quest-text",
			},
			{
				"kind": "operation",
				"capability": "core.presentation.choice",
				"arguments": {
					"prompt": {"kind": "literal", "value": "Help the town?"},
					"options": {
						"kind": "array",
						"values": [
							{"kind": "literal", "value": "Yes"},
							{"kind": "literal", "value": "No"},
						],
					},
				},
				"result": "answer",
				"sourceNode": "quest-choice",
			},
			{
				"kind": "operation",
				"capability": "core.map.teleport",
				"arguments": {
					"levelType": {"kind": "literal", "value": "land"},
					"levelIndex": {"kind": "literal", "value": 2},
					"x": {"kind": "literal", "value": 10},
					"y": {"kind": "literal", "value": 6},
				},
				"sourceNode": "quest-teleport",
			},
			{
				"kind": "operation",
				"capability": "core.encounter.start-battle",
				"arguments": {
					"battleId": {"kind": "literal", "value": 7},
				},
				"sourceNode": "quest-battle",
			},
			{
				"kind": "operation",
				"capability": "core.lifecycle.complete-campaign",
				"arguments": {
					"ending": {"kind": "literal", "value": "victory"},
				},
				"result": "campaign_completed",
				"sourceNode": "quest-complete",
			},
			{
				"kind": "return",
				"value": {
					"kind": "literal",
					"value": {"kind": "continue"},
				},
				"sourceNode": "quest-return",
			},
		],
	}
	var state_schema: Dictionary = {}
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "safe script capability catalog loads")
	var script := {
		"id": "scenario.test.offer-quest",
		"name": "Offer quest",
		"description": "Scenario runtime quest vertical slice.",
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
			"core.encounter.start-battle",
			"core.lifecycle.complete-campaign",
			"core.map.teleport",
			"core.presentation.choice",
			"core.presentation.text",
			"core.state.write",
		],
		"stateSchema": state_schema,
		"stateSchemaHash": ScenarioScriptRuntimeScript._sha256_json(state_schema),
		"sourceMap": {
			"quest-text": {"line": 2, "column": 1},
			"quest-choice": {"line": 3, "column": 1},
			"quest-teleport": {"line": 4, "column": 1},
			"quest-battle": {"line": 5, "column": 1},
		},
		"contentHash": ScenarioScriptRuntimeScript._sha256_json(program),
		"program": program,
	}
	bundle.documents["remakeScripts"] = {
		"schemaVersion": 2,
		"apiVersion": 2,
		"capabilityCatalogHash": catalog.catalog_hash(),
		"limits": {
			"maxArrayLength": 256,
			"maxAstNodes": 4096,
			"maxCallDepth": 32,
			"executionBudget": 65536,
		},
		"capabilities": script["requestedCapabilities"],
		"behaviors": [script],
		"bindings": [],
		"stateDefinitions": [{
			"name": "story_phase",
			"displayName": "Story Phase",
			"documentation": "Persistent fixture state.",
			"scope": "campaign",
			"ownerId": "",
			"schemaVersion": 1,
			"valueType": "int",
			"maxLength": null,
			"defaultValue": 0,
		}],
		"migrations": [],
	}
	var trigger_id := str(bundle.documents["scripts"]["triggers"][0]["id"])
	bundle.triggers_by_id[trigger_id]["actions"] = [{
		"kind": "semantic",
		"slot": 0,
			"operation": "core.script.call",
			"parameters": {
				"behaviorId": script["id"],
				"argumentBindings": {},
			},
		}]
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var interpreter := InterpreterScript.new()
	interpreter.configure(bundle, state)
	_expect(
		interpreter.scenario_script_runtime != null
			and interpreter.scenario_script_runtime.last_error.is_empty(),
		"safe script configures under the central scenario interpreter"
	)
	_expect(interpreter.begin_trigger(trigger_id), "safe script action point starts")
	var result := interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text",
		"safe script yields presentation text through its owning port"
	)
	_expect(
		state.get_quest_value(42) == 1,
		"safe script mutates the Classic quest flag store"
	)
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "choice",
		"safe script resumes into a choice"
	)
	var saved := interpreter.make_execution_snapshot()
	var saved_validation := InterpreterScript.validate_execution_snapshot(
		saved.get("snapshot")
	)
	_expect(
		saved.get("status") == "ok"
			and saved_validation.get("status") == "ok",
		"pending safe-script dialogue has a valid serializable snapshot: %s"
			% saved_validation.get("message", "")
	)
	_expect(
		saved.get("snapshot", {}).get("scenarioScriptRuntime", {}).get(
			"pendingOperation",
			{}
		).get("sourceNode") == "quest-choice",
		"safe-script snapshot retains source-map identity"
	)
	result = interpreter.resume_command({"choice": 0})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "teleport"
			and result.get("payload", {}).get("levelIndex") == 2,
		"safe script resumes into a typed teleport command"
	)
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "start_battle"
			and result.get("payload", {}).get("battleId") == 7,
		"safe script resumes into a typed battle command"
	)
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "complete_campaign"
			and result.get("payload", {}).get("ending") == "victory",
		"safe script reaches explicit campaign completion through PersistencePort"
	)
	result = interpreter.resume_command({"completed": true})
	_expect(
		result.get("status") == "completed",
		"safe script returns to the Classic action point"
	)
	var script_trace: Array = interpreter.scenario_script_runtime.trace
	var found_teleport_trace := false
	for entry: Variant in script_trace:
		if entry is Dictionary \
				and entry.get("sourceNode") == "quest-teleport" \
				and entry.get("capability") == "core.map.teleport":
			found_teleport_trace = true
	_expect(
		found_teleport_trace,
		"safe script trace preserves source node and capability identity"
	)
	var idle_runtime := RuntimeScript.new()
	add_child(idle_runtime)
	idle_runtime.use_shared_campaign(bundle, state)
	var state_key := "campaign\u001f\u001fstory_phase"
	idle_runtime.interpreter.scenario_script_runtime.persistent_values[state_key] = 7
	var idle_snapshot: Dictionary = idle_runtime.make_continuation_snapshot()
	_expect(
		idle_snapshot.get("status") == "ok"
			and idle_snapshot.get("snapshot", {}).get("state") == "idle",
		"idle continuation captures scenario behavior state"
	)
	idle_runtime.interpreter.scenario_script_runtime.persistent_values[state_key] = 0
	var idle_restore: Dictionary = idle_runtime.restore_continuation(
		idle_snapshot.get("snapshot", {})
	)
	_expect(
		idle_restore.get("status") == "ok"
			and idle_runtime.interpreter.scenario_script_runtime.persistent_values.get(
				state_key
			) == 7,
		"idle continuation restores persistent scenario behavior state"
	)
	idle_runtime.queue_free()

	var migration_program := {
		"kind": "function",
		"name": "migrate_story_phase",
		"parameters": [],
		"returnType": "void",
		"body": [
			{
				"kind": "operation",
				"capability": "core.state.write",
				"arguments": {
					"scope": {"kind": "literal", "value": "campaign"},
					"name": {"kind": "literal", "value": "story_phase"},
					"value": {"kind": "literal", "value": 2},
				},
				"sourceNode": "migration-write",
			},
			{"kind": "return", "value": null, "sourceNode": "migration-return"},
		],
	}
	var migration_helper := {
		"id": "scenario.test.migrate-story-phase",
		"name": "Migrate story phase",
		"description": "Moves fixture state to schema two.",
		"kind": "helper",
		"role": "helper",
		"hook": "",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "void",
		"requestedCapabilities": ["core.state.write"],
		"stateSchema": {},
		"stateSchemaHash": ScenarioScriptRuntimeScript._sha256_json({}),
		"sourceMap": {},
		"contentHash": ScenarioScriptRuntimeScript._sha256_json(migration_program),
		"program": migration_program,
	}
	var migration_document: Dictionary = bundle.documents["remakeScripts"].duplicate(true)
	migration_document["behaviors"].append(migration_helper)
	migration_document["migrations"] = [{
		"id": "scenario.test.migration-1-2",
		"fromContentVersion": "1.0.0",
		"toContentVersion": "2.0.0",
		"behaviorId": migration_helper["id"],
	}]
	var migration_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		migration_runtime.configure(migration_document, state, bundle),
		"versioned scenario migration runtime configures"
	)
	var old_snapshot: Dictionary = migration_runtime.snapshot()
	old_snapshot["persistentValues"][state_key] = 1
	var migrated: Dictionary = migration_runtime.migrate_snapshot(
		old_snapshot,
		"1.0.0",
		"2.0.0"
	)
	_expect(
		migrated.get("status") == "ok"
			and migrated.get("snapshot", {}).get("persistentValues", {}).get(
				state_key
			) == 2,
		"exact Safe migration chain updates persistent scenario state"
	)


func _test_nested_safe_behavior_execution() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "nested behavior fixture bundle loads")
	if not bundle.last_error.is_empty():
		return
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "nested behavior capability catalog loads")
	var outer_program := {
		"kind": "function",
		"name": "start_scripted_battle",
		"parameters": [],
		"returnType": "action-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.encounter.start-battle",
				"arguments": {
					"battleId": {"kind": "literal", "value": 1},
				},
				"sourceNode": "outer-battle",
			},
			{
				"kind": "return",
				"value": {
					"kind": "literal",
					"value": {"kind": "continue"},
				},
				"sourceNode": "outer-return",
			},
		],
	}
	var nested_program := {
		"kind": "function",
		"name": "spell_inside_scripted_battle",
		"parameters": [],
		"returnType": "effect-outcome",
		"body": [
			{
				"kind": "operation",
				"capability": "core.presentation.text",
				"arguments": {
					"text": {
						"kind": "literal",
						"value": "Nested spell behavior",
					},
				},
				"sourceNode": "nested-text",
			},
			{
				"kind": "return",
				"value": {
					"kind": "literal",
					"value": {"kind": "applied"},
				},
				"sourceNode": "nested-return",
			},
		],
	}
	var scripts := [
		_safe_behavior_fixture(
			"scenario.test.outer-battle",
			"action",
			"run",
			"action-outcome",
			["core.encounter.start-battle"],
			outer_program
		),
		_safe_behavior_fixture(
			"scenario.test.nested-spell",
			"spell",
			"effect",
			"effect-outcome",
			["core.presentation.text"],
			nested_program
		),
	]
	var document := {
		"schemaVersion": 2,
		"apiVersion": 2,
		"capabilityCatalogHash": catalog.catalog_hash(),
		"behaviors": scripts,
		"bindings": [],
		"stateDefinitions": [],
		"migrations": [],
	}
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var script_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		script_runtime.configure(document, state, bundle),
		"nested behavior runtime configures"
	)
	var outer_step: ScenarioStepResult = script_runtime.invoke(
		"scenario.test.outer-battle"
	)
	_expect(
		outer_step.kind == ScenarioStepResult.YIELD
			and outer_step.data.get("commandId") == "start_battle",
		"outer Safe behavior suspends on its battle command"
	)
	var nested_step: ScenarioStepResult = script_runtime.invoke_nested(
		"scenario.test.nested-spell",
		{},
		{"role": "spell", "hook": "effect"}
	)
	_expect(
		nested_step.kind == ScenarioStepResult.YIELD
			and nested_step.data.get("commandId") == "show_text",
		"spell behavior executes while its owning action waits for battle"
	)
	var nested_snapshot: Dictionary = script_runtime.snapshot()
	_expect(
		ScenarioScriptRuntimeScript.validate_snapshot(nested_snapshot).get(
			"valid",
			false
		)
			and nested_snapshot.get("suspendedInvocations", []).size() == 1,
		"nested Safe behavior and suspended action are saveable together"
	)
	var restored_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		restored_runtime.configure(document, state, bundle)
			and restored_runtime.restore(nested_snapshot).get("status") == "ok",
		"nested Safe behavior snapshot restores"
	)
	nested_step = restored_runtime.resume({})
	_expect(
		nested_step.kind == ScenarioStepResult.CONTINUE
			and nested_step.data.get("value", {}).get("kind") == "applied",
		"restored nested spell behavior returns its typed outcome"
	)
	var restored_outer: Dictionary = restored_runtime.complete_nested_invocation()
	_expect(
		restored_outer.get("status") == "ok"
			and bool(restored_outer.get("restored", false)),
		"completing nested spell behavior restores the outer action frame"
	)
	outer_step = restored_runtime.resume({})
	_expect(
		outer_step.kind == ScenarioStepResult.CONTINUE
			and outer_step.data.get("value", {}).get("kind") == "continue",
		"outer action resumes after nested battle behavior"
	)


func _safe_behavior_fixture(
	id: String,
	role: String,
	hook: String,
	return_type: String,
	capabilities: Array,
	program: Dictionary
) -> Dictionary:
	return {
		"id": id,
		"name": id,
		"description": "Nested Safe behavior fixture",
		"kind": "entry",
		"role": role,
		"hook": hook,
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": return_type,
		"requestedCapabilities": capabilities,
		"stateSchema": {},
		"stateSchemaHash": ScenarioScriptRuntimeScript._sha256_json({}),
		"sourceMap": {},
		"contentHash": ScenarioScriptRuntimeScript._sha256_json(program),
		"program": program,
	}


func _test_spell_effect_lifecycle() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "spell-effect fixture bundle loads")
	if not bundle.last_error.is_empty():
		return
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "spell-effect capability catalog loads")
	var document := ScenarioScriptRuntimeScript.empty_document()
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var script_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		script_runtime.configure(document, state, bundle),
		"spell-effect runtime configures"
	)
	var registered := script_runtime.register_spell_effect(
		["4501"],
		{
			"spell": {"ids": ["4501"], "name": "Test Ward"},
			"targets": [{"id": "combat:1"}],
			"cast": {"mode": "combat"},
		},
		{
			"kind": "applied",
			"duration": 2,
			"interval": "round",
			"effectKey": "test-ward",
			"stacking": "refresh",
		}
	)
	_expect(
		registered.get("status") == "ok"
			and bool(registered.get("registered", false)),
		"applied spell outcome registers serializable effect state"
	)
	var saved := script_runtime.snapshot()
	_expect(
		ScenarioScriptRuntimeScript.validate_snapshot(saved).get("valid", false)
			and saved.get("activeSpellEffects", []).size() == 1,
		"active spell effects are included in the Safe runtime snapshot"
	)
	var restored := ScenarioScriptRuntimeScript.new()
	_expect(
		restored.configure(document, state, bundle)
			and restored.restore(saved).get("status") == "ok",
		"active spell effects restore with campaign script state"
	)
	var first_round := restored.advance_spell_effects("round", {"round": 2})
	_expect(
		first_round.get("status") == "ok"
			and first_round.get("deliveries", []).size() == 1
			and first_round.get("deliveries", [])[0].get("hook") == "tick"
			and first_round.get("activeCount") == 1,
		"round spell effect dispatches a tick and remains active"
	)
	var second_round := restored.advance_spell_effects("round", {"round": 3})
	_expect(
		second_round.get("status") == "ok"
			and second_round.get("deliveries", []).size() == 2
			and second_round.get("deliveries", [])[0].get("hook") == "tick"
			and second_round.get("deliveries", [])[1].get("hook") == "expire"
			and second_round.get("activeCount") == 0,
		"final spell-effect tick dispatches expiration and removes state"
	)
	restored.register_spell_effect(
		["4501"],
		{
			"spell": {"ids": ["4501"], "name": "Timed Ward"},
			"targets": [{"id": "party:0"}],
			"cast": {"mode": "field"},
		},
		{
			"kind": "applied",
			"duration": 1,
			"interval": "minute",
			"effectKey": "timed-ward",
		}
	)
	var partial_time := restored.advance_spell_effects(
		"time",
		{"elapsedSeconds": 30}
	)
	var completed_time := restored.advance_spell_effects(
		"time",
		{"elapsedSeconds": 30}
	)
	_expect(
		partial_time.get("deliveries", []).is_empty()
			and completed_time.get("deliveries", []).size() == 2,
		"scenario-time spell effects retain elapsed time across events"
	)
	var identity_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		identity_runtime.configure(document, state, bundle),
		"spell-effect identity fixture runtime configures"
	)
	var original_identity := identity_runtime.register_spell_effect(
		["4501"],
		{
			"spell": {"ids": ["4501"], "name": "Stable Ward"},
			"targets": [{"id": "party:0", "health": 10}],
			"cast": {"mode": "field"},
		},
		{"kind": "applied", "duration": 1, "interval": "minute"}
	)
	var refreshed_identity := identity_runtime.register_spell_effect(
		["4501"],
		{
			"spell": {"ids": ["4501"], "name": "Stable Ward"},
			"targets": [{"id": "party:0", "health": 7}],
			"cast": {"mode": "field"},
		},
		{"kind": "applied", "duration": 3, "interval": "minute"}
	)
	_expect(
		original_identity.get("effectId") == refreshed_identity.get("effectId")
			and bool(refreshed_identity.get("refreshed", false))
			and identity_runtime.active_spell_effects.size() == 1,
		"spell-effect identity ignores mutable target snapshots"
	)


func _test_campaign_completion_state() -> void:
	var bundle := BundleScript.new()
	_expect(bundle.load_from_directory(V3_FIXTURE), "completion fixture bundle loads")
	if not bundle.last_error.is_empty():
		return
	var document := ScenarioScriptRuntimeScript.empty_document()
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var runtime := ScenarioScriptRuntimeScript.new()
	_expect(runtime.configure(document, state, bundle), "completion runtime configures")
	var completed := runtime.mark_campaign_complete({
		"ending": "victory",
		"source": "Data DD:0:99",
	})
	var repeated := runtime.mark_campaign_complete({"ending": "other"})
	_expect(
		completed.get("status") == "ok"
			and bool(completed.get("completed", false))
			and not bool(completed.get("alreadyCompleted", true))
			and bool(repeated.get("alreadyCompleted", false))
			and repeated.get("completion", {}).get("ending") == "victory",
		"campaign completion is explicit, one-time, and idempotent"
	)
	var saved := runtime.snapshot()
	var restored := ScenarioScriptRuntimeScript.new()
	_expect(
		ScenarioScriptRuntimeScript.validate_snapshot(saved).get("valid", false)
			and restored.configure(document, state, bundle)
			and restored.restore(saved).get("status") == "ok"
			and restored.campaign_completion.get("ending") == "victory",
		"campaign completion persists in Safe runtime snapshots"
	)


func _test_rule_modifier_pipeline() -> void:
	var pipeline := RuleModifierPipelineScript.new()
	pipeline.configure(RuleBehaviorRunner.new(), null, {})
	var result: Dictionary = await pipeline.resolve("damage", 10.0, {
		"minimum": 0.0,
		"maximum": 25.0,
	})
	_expect(
		result.get("status") == "ok"
			and is_equal_approx(float(result.get("value", 0.0)), 25.0),
		"scenario rule modifiers apply in order and clamp after resolution"
	)


func _test_behavior_role_capability_validation() -> void:
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "behavior role validation catalog loads")
	var program := {
		"kind": "function",
		"name": "decide",
		"parameters": [],
		"returnType": "monster-decision",
		"body": [{
			"kind": "return",
			"value": {"kind": "literal", "value": {"kind": "wait"}},
		}],
	}
	var behavior := {
		"id": "scenario.test.non-yielding-ai",
		"name": "Non-yielding AI",
		"description": "Rejects port-yielding queries from monster AI.",
		"kind": "entry",
		"role": "monster-ai",
		"hook": "decide",
		"tier": "safe",
		"apiVersion": 2,
		"behaviorVersion": 1,
		"stateSchemaVersion": 1,
		"parameters": [],
		"returnType": "monster-decision",
		"requestedCapabilities": ["core.combat.snapshot"],
		"stateSchema": {},
		"stateSchemaHash": ScenarioScriptRuntimeScript._sha256_json({}),
		"sourceMap": {},
		"contentHash": ScenarioScriptRuntimeScript._sha256_json(program),
		"program": program,
	}
	var document := {
		"schemaVersion": 2,
		"apiVersion": 2,
		"capabilityCatalogHash": catalog.catalog_hash(),
		"limits": {
			"maxArrayLength": 256,
			"maxAstNodes": 4096,
			"maxCallDepth": 32,
			"executionBudget": 65536,
		},
		"capabilities": ["core.combat.snapshot"],
		"behaviors": [behavior],
		"bindings": [],
		"stateDefinitions": [],
		"migrations": [],
	}
	var validation := ScenarioScriptRuntimeScript.validate_document(document)
	_expect(
		not bool(validation.get("valid", true))
			and str(validation.get("message", "")).contains("cannot use yielding capability"),
		"non-yielding behavior roles reject yielding capabilities at readiness"
	)
	var item_program := {
		"kind": "function",
		"name": "equip",
		"parameters": [],
		"returnType": "item-outcome",
		"body": [{
			"kind": "return",
			"value": {"kind": "literal", "value": {"kind": "used"}},
		}],
	}
	var item_behavior: Dictionary = behavior.duplicate(true)
	item_behavior.merge({
		"id": "scenario.test.pure-item-hook",
		"name": "Pure item hook",
		"description": "Equipment hooks are connected but cannot mutate state.",
		"role": "item",
		"hook": "equip",
		"returnType": "item-outcome",
		"requestedCapabilities": [],
		"contentHash": ScenarioScriptRuntimeScript._sha256_json(item_program),
		"program": item_program,
	}, true)
	var item_document: Dictionary = document.duplicate(true)
	item_document["capabilities"] = []
	item_document["behaviors"] = [item_behavior]
	var item_validation := ScenarioScriptRuntimeScript.validate_document(
		item_document
	)
	_expect(
		bool(item_validation.get("valid", false)),
		"pure equipment behavior hooks pass readiness"
	)
	item_behavior["requestedCapabilities"] = ["core.state.write"]
	item_document["capabilities"] = ["core.state.write"]
	item_validation = ScenarioScriptRuntimeScript.validate_document(item_document)
	_expect(
		not bool(item_validation.get("valid", true))
			and str(item_validation.get("message", "")).contains(
				"cannot yield or mutate state"
			),
		"pure equipment behavior hooks reject mutating capabilities"
	)


func _test_typed_role_outcomes() -> void:
	var record_runtime := ScenarioScriptRuntimeScript.new()
	record_runtime.frames = [{"locals": {"outcome": 2}}]
	var dynamic_record := record_runtime._evaluate({
		"kind": "record",
		"fields": {
			"kind": {"kind": "literal", "value": "branch"},
			"outcome": {"kind": "variable", "scope": "local", "name": "outcome"},
		},
	})
	_expect(
		dynamic_record.get("status") == "ok"
			and dynamic_record.get("value", {}).get("kind") == "branch"
			and dynamic_record.get("value", {}).get("outcome") == 2,
		"Safe role outcomes evaluate dynamic typed record fields"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "wait"},
			"monster-decision"
		),
		"monster AI accepts a wait decision"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "move", "dx": -1, "dy": 1},
			"monster-decision"
		),
		"monster AI accepts a bounded movement decision shape"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{
				"kind": "cast",
				"spellId": "Disease",
				"power": 4,
				"targetId": "combat:0",
			},
			"monster-decision"
		),
		"monster AI accepts an explicit spell decision"
	)
	_expect(
		not ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "cast", "spellId": "Disease"},
			"monster-decision"
		),
		"monster AI rejects a spell decision without power and target"
	)
	_expect(
		not ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "use-item", "targetId": "combat:0"},
			"monster-decision"
		),
		"monster AI rejects item use without a stable item-instance ID"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "modified", "add": 2.0, "multiply": 1.5},
			"item-outcome"
		),
		"item hooks accept bounded numeric modifier outcomes"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{
				"kind": "applied",
				"duration": 3,
				"interval": "round",
				"stacking": "refresh",
			},
			"effect-outcome"
		),
		"spell effects accept bounded lifecycle schedules"
	)
	_expect(
		not ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "modified", "unexpected": 2.0},
			"item-outcome"
		),
		"item hooks reject undeclared modifier fields"
	)
	var handler := ScenarioScriptHandlerScript.new()
	var halt_result: ScenarioStepResult = handler._apply_action_outcome(
		ScenarioStepResultScript.continued({
			"value": {"kind": "halt", "reason": "fixture"},
		})
	)
	_expect(
		halt_result.kind == ScenarioStepResultScript.HALT
			and halt_result.data.get("reason") == "fixture",
		"action behavior halt outcomes become central VM halt results"
	)
	var call_result: ScenarioStepResult = handler._apply_action_outcome(
		ScenarioStepResultScript.continued({
			"value": {
				"kind": "call",
				"triggerId": "Data DD:0:9",
				"actionIndex": 3,
			},
		})
	)
	_expect(
		call_result.kind == ScenarioStepResultScript.CALL
			and call_result.data.get("triggerId") == "Data DD:0:9"
			and call_result.data.get("actionIndex") == 3,
		"action behavior call outcomes become central VM GOSUB results"
	)
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "typed response fixture loads the API catalog")
	var response_runtime := ScenarioScriptRuntimeScript.new()
	response_runtime.capability_catalog = catalog
	var paid_result := response_runtime._operation_response_value(
		"core.inventory.take-wealth",
		{"paid": true, "removed": [500, 0, 0]}
	)
	_expect(
		paid_result.get("status") == "ok"
			and paid_result.get("value") == true,
		"Safe operation responses extract their catalog-declared scalar field"
	)
	var invalid_paid_result := response_runtime._operation_response_value(
		"core.inventory.take-wealth",
		{"paid": "yes"}
	)
	_expect(
		invalid_paid_result.get("status") == "error",
		"Safe operation responses reject values that violate the catalog type"
	)
	var valid_arguments := response_runtime._validate_operation_arguments(
		"core.map.teleport",
		{"levelType": "land", "levelIndex": 0, "x": 2, "y": 2}
	)
	_expect(
		valid_arguments.get("status") == "ok",
		"Scenario API arguments accept their complete typed contract"
	)
	var missing_argument := response_runtime._validate_operation_arguments(
		"core.map.teleport",
		{"levelType": "land", "levelIndex": 0, "x": 2}
	)
	_expect(
		missing_argument.get("status") == "error",
		"Scenario API arguments reject missing required fields"
	)
	var unknown_argument := response_runtime._validate_operation_arguments(
		"core.map.teleport",
		{
			"levelType": "land",
			"levelIndex": 0,
			"x": 2,
			"y": 2,
			"sceneTree": "forbidden",
		}
	)
	_expect(
		unknown_argument.get("status") == "error",
		"Scenario API arguments reject undeclared fields"
	)
	var invalid_argument_type := response_runtime._validate_operation_arguments(
		"core.inventory.take-wealth",
		{"gold": "five hundred"}
	)
	_expect(
		invalid_argument_type.get("status") == "error",
		"Scenario API arguments reject values with the wrong type"
	)


func _test_old_save_rejection() -> void:
	var result := CampaignSessionScript.validate_save_payload({"schemaVersion": 2})
	_expect(result.get("status") == "error", "old POC save is rejected")
	_expect(
		str(result.get("message", "")).contains("start a new playthrough"),
		"old-save rejection is actionable"
	)


func _test_native_spell_behavior_hooks() -> void:
	var runner := SpellBehaviorRunner.new()
	var port := CharacterPort.new()
	port.configure({
		"scenarioPortRuntime": SpellBehaviorServices.new(),
		"behaviorRunner": runner,
		"runtimeBindings": {},
	})
	var spell := SpellBehaviorFixture.new()
	_expect(
		port.has_spell_behavior(spell),
		"native spell resources discover attached scenario behavior"
	)
	var validation: Dictionary = await port.run_spell_behavior_hook(
		spell,
		"validate",
		null,
		[],
		3,
		{"mode": "field"}
	)
	_expect(
		validation.get("status") == "ok"
			and bool(validation.get("valid", false)),
		"native spell validation executes through the Character port"
	)
	var effect: Dictionary = await port.run_spell_behavior_hook(
		spell,
		"effect",
		null,
		[],
		3,
		{"mode": "combat"}
	)
	_expect(
		effect.get("status") == "ok"
			and bool(effect.get("handled", false)),
		"native spell effects can replace the stock effect through a typed hook"
	)
	_expect(
		runner.hooks == ["validate", "effect"],
		"native spell behavior preserves deterministic hook order"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	failures += 1
	push_error(message)


class IncompleteScenarioGodotServices:
	extends RefCounted

	func scenario_service_contract_version() -> int:
		return 1


class RuleBehaviorRunner:
	extends RefCounted

	func run_behavior_attachments_pure(
		_role: String,
		_hook: String,
		_target_kind: String,
		_target_ids: Array,
		_request: Dictionary
	) -> Dictionary:
		return {
			"status": "ok",
			"handled": true,
			"results": [
				{"status": "ok", "value": {"add": 5}},
				{"status": "ok", "value": {"multiply": 2, "maximum": 30}},
			],
		}


class SpellBehaviorFixture:
	extends RefCounted

	var classic_spell_ids := [4501]
	var name := "Scenario Fixture Spell"


class SpellBehaviorServices:
	extends RefCounted

	func scenario_spell_behavior_context(
		_spell: Object,
		_caster: Object,
		_targets: Array,
		power: int,
		cast_context: Dictionary
	) -> Dictionary:
		return {
			"status": "ok",
			"targetIds": ["4501"],
			"request": {
				"spell": {
					"ids": ["4501"],
					"name": "Scenario Fixture Spell",
					"power": power,
				},
				"cast": cast_context.duplicate(true),
			},
		}


class SpellBehaviorRunner:
	extends RefCounted

	var hooks: Array[String] = []

	func has_behavior_attachments(
		role: String,
		hook: String,
		target_kind: String,
		target_ids: Array,
		_slot := -1
	) -> bool:
		return role == "spell" \
			and hook in ["validate", "effect"] \
			and target_kind == "spell" \
			and "4501" in target_ids

	func run_behavior_attachments(
		_role: String,
		hook: String,
		_target_kind: String,
		_target_ids: Array,
		_request: Dictionary
	) -> Dictionary:
		hooks.append(hook)
		return {
			"status": "ok",
			"handled": true,
			"results": [{
				"status": "ok",
				"value": {"kind": "applied"},
			}],
		}
