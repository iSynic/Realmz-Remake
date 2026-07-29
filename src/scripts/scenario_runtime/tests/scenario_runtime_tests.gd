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
const ScenarioGodotServicesScript = preload(
	"res://scripts/scenario_runtime/godot/scenario_godot_services.gd"
)
const HostScript = preload(
	"res://scripts/classic_runtime/classic_runtime_host.gd"
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
		"spells": {"echo": "scenario.runtime-fixture.echo-spell"},
		"items": {"echo": "scenario.runtime-fixture.echo-item"},
		"encounters": {"echo": "scenario.runtime-fixture.echo-encounter"},
		"monsterAi": {"echo": "scenario.runtime-fixture.echo-ai"},
		"lifecycle": {"load": "scenario.runtime-fixture.lifecycle"},
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
			{"kind": "return", "sourceNode": "quest-return"},
		],
	}
	var state_schema: Dictionary = {}
	var catalog := CapabilityCatalogScript.new()
	_expect(catalog.load_builtin(), "safe script capability catalog loads")
	var script := {
		"id": "scenario.test.offer-quest",
		"name": "Offer quest",
		"documentation": "Scenario runtime quest vertical slice.",
		"tier": "safe",
		"apiVersion": 1,
		"parameters": [],
		"returnType": "void",
		"requestedCapabilities": [
			"core.encounter.start-battle",
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
		"apiVersion": 1,
		"capabilityCatalogHash": catalog.catalog_hash(),
		"scripts": [script],
		"attachments": [],
		"persistentVariables": [],
	}
	var trigger_id := str(bundle.documents["scripts"]["triggers"][0]["id"])
	bundle.triggers_by_id[trigger_id]["actions"] = [{
		"kind": "semantic",
		"slot": 0,
		"operation": "core.script.call",
		"parameters": {
			"scriptId": script["id"],
			"arguments": {},
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


func _test_old_save_rejection() -> void:
	var result := CampaignSessionScript.validate_save_payload({"schemaVersion": 2})
	_expect(result.get("status") == "error", "old POC save is rejected")
	_expect(
		str(result.get("message", "")).contains("start a new playthrough"),
		"old-save rejection is actionable"
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
