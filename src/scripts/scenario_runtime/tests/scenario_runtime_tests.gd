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
const PreviewHostScript = preload(
	"res://scripts/scenario_runtime/preview/scenario_preview_host.gd"
)
const SandboxClientScript = preload(
	"res://scripts/scenario_runtime/scenario_sandbox_client.gd"
)
const EnginePluginRegistryScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_registry.gd"
)
const EnginePluginStoreScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_store.gd"
)

const V3_FIXTURE := \
	"res://scripts/classic_runtime/tests/fixtures/war_in_the_sword_lands_gosub"
const V1_FIXTURE := \
	"res://scripts/scenario_runtime/tests/fixtures/v1_rejected"
const PROVIDENCE_SCRIPTING_ACCEPTANCE_FIXTURE := \
	"res://scripts/scenario_runtime/tests/fixtures/providence-scripting-acceptance"
const CITY_OF_BYWATER_CAMPAIGN := \
	"res://Campaigns/City of Bywater (Classic)"

var failures := 0


class PartyItemCarrier:
	extends RefCounted
	var item_inventory: Array[ItemInstance] = []

	func inventory_instances() -> Array[ItemInstance]:
		return item_inventory.duplicate()


func _ready() -> void:
	_test_v3_bundle_contract()
	_test_definition_snapshot_services()
	_test_extension_registry()
	await _test_engine_plugin_registry()
	_test_engine_plugin_store()
	_test_engine_plugin_settings_ui()
	_test_preview_wire_json()
	_test_sandbox_helper_discovery()
	await _test_gameplay_rules()
	_test_handler_registry()
	_test_command_ports()
	_test_scenario_vm()
	_test_classic_execution_state_ownership()
	_test_classic_dispatcher_noops()
	await _test_builtin_extension_execution()
	await _test_providence_scripting_acceptance_bundle()
	_test_classic_enhanced_gosub_attachments()
	await _test_city_of_bywater_enhanced_ap()
	_test_safe_script_quest_slice()
	_test_guided_source_node_assignment()
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


func _test_preview_wire_json() -> void:
	var state_key := "campaign\u001f\u001fstory_phase"
	var encoded := PreviewHostScript._json_wire_text({
		"persistentValues": {state_key: 7},
	})
	_expect(
		not encoded.contains(String.chr(31)),
		"preview wire JSON escapes control characters"
	)
	var decoded: Variant = JSON.parse_string(encoded)
	_expect(
		decoded is Dictionary
			and decoded.get("persistentValues", {}).get(state_key) == 7,
		"preview wire JSON preserves internal state keys"
	)


func _test_sandbox_helper_discovery() -> void:
	var packaged := SandboxClientScript.helper_candidates(
		"C:/Realmz/Realmz.exe",
		"F:/realmz-remake/src",
		false
	)
	_expect(
		packaged == PackedStringArray([
			"C:/Realmz/scenario-sandbox-host.exe",
		]),
		"packaged sandbox helper stays beside the game executable"
	)
	var checkout := SandboxClientScript.helper_candidates(
		"C:/Godot/Godot.exe",
		"F:/realmz-remake/src/",
		true
	)
	_expect(
		checkout == PackedStringArray([
			"C:/Godot/scenario-sandbox-host.exe",
			"F:/realmz-remake/tools/scenario-sandbox-host/target/debug/"
				+ "scenario-sandbox-host.exe",
			"F:/realmz-remake/tools/scenario-sandbox-host/target/release/"
				+ "scenario-sandbox-host.exe",
		]),
		"debug previews discover checkout-built sandbox helpers"
	)


func _test_guided_source_node_assignment() -> void:
	var statements: Array = [
		{"kind": "operation", "sourceNode": "n1"},
		{
			"kind": "if",
			"then": [{"kind": "assign"}],
			"else": [{"kind": "return"}],
		},
	]
	ScenarioScriptRuntimeScript._assign_debug_source_nodes(statements, "/body")
	_expect(
		str(statements[0].get("sourceNode", "")) == "n1",
		"Safe source keeps its authored source-node identity"
	)
	_expect(
		str(statements[1].get("sourceNode", "")) == "guided/body/1"
			and str(statements[1]["then"][0].get("sourceNode", "")) \
				== "guided/body/1/then/0"
			and str(statements[1]["else"][0].get("sourceNode", "")) \
				== "guided/body/1/else/0",
		"Guided outline blocks receive deterministic debugger identities"
	)


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


func _test_providence_scripting_acceptance_bundle() -> void:
	var bundle := BundleScript.new()
	_expect(
		bundle.load_from_directory(PROVIDENCE_SCRIPTING_ACCEPTANCE_FIXTURE),
		"Providence scripting acceptance bundle loads in Remake"
	)
	if not bundle.last_error.is_empty():
		push_error(bundle.last_error)
		return
	var scripts: Dictionary = bundle.documents.get("remakeScripts", {})
	_expect(
		scripts.get("schemaVersion") == 2
			and scripts.get("apiVersion") == 2
			and scripts.get("behaviors", []).size() == 11
			and scripts.get("bindings", []).size() == 9
			and scripts.get("stateDefinitions", []).size() == 3
			and scripts.get("migrations", []).size() == 1,
		"Remake consumes the complete Providence-authored scripting contract"
	)
	var exported_actions: Array = bundle.documents.get(
		"scripts",
		{}
	).get("triggers", [])[0].get("actions", [])
	var exported_bindings: Array = scripts.get("bindings", [])
	_expect(
		exported_actions.size() >= 2
			and exported_actions[0].get("kind") == "classic"
			and exported_actions[0].get("code") == 1
			and exported_actions[1].get("kind") == "classic"
			and exported_actions[1].get("code") == 47,
		"Providence preserves Classic source slots in an enhanced package"
	)
	_expect(
		not exported_bindings.is_empty()
			and exported_bindings[0].get("hook") == "after-slot"
			and exported_bindings[0].get("slot") == 0,
		"Providence exports the guided Behavior as a separate after-slot attachment"
	)
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(bundle)
	var interpreter := InterpreterScript.new()
	interpreter.configure(bundle, state)
	_expect(
		interpreter.scenario_script_runtime != null
			and interpreter.scenario_script_runtime.last_error.is_empty(),
		"Providence-authored behaviors configure in the central interpreter"
	)
	var host := HostScript.new()
	add_child(host)
	host.configure(RefCounted.new())
	host.use_campaign(bundle)
	for role_case: Dictionary in [
		{
			"behaviorId": "scenario.providence.encounter-result",
			"role": "encounter",
			"hook": "result",
			"targetKind": "simpleEncounter",
			"recordId": "0",
			"slot": 0,
			"expectedKind": "continue",
		},
		{
			"behaviorId": "scenario.providence.spell-effect",
			"role": "spell",
			"hook": "effect",
			"targetKind": "spell",
			"recordId": "16",
			"slot": -1,
			"expectedKind": "applied",
		},
		{
			"behaviorId": "scenario.providence.item-use",
			"role": "item",
			"hook": "use-field",
			"targetKind": "item",
			"recordId": "101",
			"slot": -1,
			"expectedKind": "used",
		},
		{
			"behaviorId": "scenario.providence.monster-ai",
			"role": "monster-ai",
			"hook": "decide",
			"targetKind": "monster",
			"recordId": "1",
			"slot": -1,
			"expectedKind": "wait",
		},
		{
			"behaviorId": "scenario.providence.campaign-start",
			"role": "lifecycle",
			"hook": "campaign-start",
			"targetKind": "lifecycle",
			"recordId": "campaign",
			"slot": -1,
			"expectedKind": "",
		},
	]:
		var role_result: Dictionary = await host.run_behavior_binding(
			role_case["behaviorId"],
			role_case["role"],
			role_case["hook"],
			role_case["targetKind"],
			role_case["recordId"],
			role_case["slot"],
			{"source": "preview-role-test", "slot": role_case["slot"]}
		)
		_expect(
			role_result.get("status") == "ok"
				and (
					str(role_case["expectedKind"]).is_empty()
					or role_result.get("value", {}).get("kind")
						== role_case["expectedKind"]
				),
			"Providence-authored %s binding runs through its typed role: %s"
				% [role_case["role"], role_result]
		)
	var rule_result: Dictionary = host.resolve_rule_modifiers(
		"attack-chance",
		50.0,
		{"minimum": 0.0, "maximum": 100.0}
	)
	_expect(
		rule_result.get("status") == "ok"
			and is_equal_approx(float(rule_result.get("value", 0.0)), 55.0),
		"Providence-authored rule binding runs through the modifier pipeline"
	)
	for entry_kind: String in [
		"encounter",
		"spell",
		"item",
		"monster",
		"lifecycle",
		"rule",
	]:
		_expect(
			not PreviewHostScript._role_for_entry_kind(entry_kind).is_empty(),
			"preview entry '%s' resolves a typed behavior role" % entry_kind
		)
	host.queue_free()
	_expect(
		interpreter.begin_trigger("land:0:ap:0"),
		"Providence-authored AP binding starts through the Classic trigger"
	)
	var result := interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text",
		"Providence-authored AP preserves and executes its Classic first slot: %s"
			% str(result)
	)
	var classic_text_snapshot := interpreter.make_execution_snapshot()
	_expect(
		classic_text_snapshot.get("status") == "ok",
		"Classic text before an after-slot Behavior is a save boundary"
	)
	var classic_restore_state := ClassicRuntimeStateScript.new()
	classic_restore_state.configure_from_bundle(bundle)
	var classic_restored_interpreter := InterpreterScript.new()
	classic_restored_interpreter.configure(bundle, classic_restore_state)
	var classic_restore_result := (
		classic_restored_interpreter.restore_execution_snapshot(
			classic_text_snapshot.get("snapshot", {})
		)
	)
	_expect(
		classic_restore_result.get("status") == "ok",
		"Remake restores a Classic yield with its pending after-slot attachment"
	)
	interpreter = classic_restored_interpreter
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "query_party_wealth",
		"Successful Classic resume enters the attached Safe Behavior: %s"
			% str(result)
	)
	_expect(
		not interpreter.trace.is_empty()
			and interpreter.trace[0].get("event") == "behavior-attachment"
			and interpreter.trace[0].get("attachmentId")
				== "binding.providence.acceptance.action",
		"The pending attachment is injected only after Classic slot 0 resumes: %s"
			% str(interpreter.trace)
	)
	result = interpreter.resume_command({
		"gold": 500,
		"gems": 0,
		"jewelry": 0,
		"pooledGold": 500,
	})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "query_time",
		"Providence-authored AP resumes into the campaign clock query"
	)
	result = interpreter.resume_command({
		"day": 3,
		"hour": 12,
		"minute": 0,
		"second": 0,
		"totalSeconds": 216000,
	})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "query_party_members",
		"Providence-authored AP resumes into immutable party snapshots"
	)
	result = interpreter.resume_command({
		"value": [{
			"id": "party:0",
			"name": "Acceptance Hero",
			"level": 1,
			"raceId": 1,
			"raceName": "Human",
			"casteId": 1,
			"casteName": "Warrior",
			"gender": 0,
			"health": 10,
			"maximumHealth": 10,
			"spellPoints": 0,
			"maximumSpellPoints": 0,
			"strength": 10,
			"intellect": 10,
			"wisdom": 10,
			"dexterity": 10,
			"vitality": 10,
			"luck": 10,
			"movement": 12,
			"conditions": [],
			"itemIds": [],
			"alive": true,
		}],
	})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "take_party_wealth"
			and result.get("payload", {}).get("gold") == 500,
		"Providence-authored collection query reaches its payment branch"
	)
	result = interpreter.resume_command({"paid": true})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text"
			and result.get("payload", {}).get("text")
				== "The captain accepts your payment.",
		"Providence-authored AP writes state and yields presentation"
	)
	var saved := interpreter.make_execution_snapshot()
	_expect(
		saved.get("status") == "ok",
		"Providence-authored pending behavior produces a save snapshot"
	)
	var restored_state := ClassicRuntimeStateScript.new()
	restored_state.configure_from_bundle(bundle)
	var restored_interpreter := InterpreterScript.new()
	restored_interpreter.configure(bundle, restored_state)
	var restore_result := restored_interpreter.restore_execution_snapshot(
		saved.get("snapshot", {})
	)
	_expect(
		restore_result.get("status") == "ok",
		"Remake restores the Providence-authored behavior snapshot"
	)
	result = restored_interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "choice"
			and result.get("payload", {}).get("options")
				== ["Accept", "Decline"],
		"Restored Providence-authored AP reaches its authored choice: %s"
			% str(result)
	)
	saved = restored_interpreter.make_execution_snapshot()
	_expect(
		saved.get("status") == "ok",
		"Providence-authored pending choice remains a save boundary"
	)
	restored_state = ClassicRuntimeStateScript.new()
	restored_state.configure_from_bundle(bundle)
	restored_interpreter = InterpreterScript.new()
	restored_interpreter.configure(bundle, restored_state)
	restore_result = restored_interpreter.restore_execution_snapshot(
		saved.get("snapshot", {})
	)
	_expect(
		restore_result.get("status") == "ok",
		"Remake restores the Providence-authored pending choice"
	)
	result = restored_interpreter.resume_command({"choice": 0})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "teleport"
			and result.get("payload", {}).get("levelType") == "land"
			and result.get("payload", {}).get("levelIndex") == 0
			and result.get("payload", {}).get("x") == 11
			and result.get("payload", {}).get("y") == 12,
		"Providence-authored choice resumes into a typed teleport: %s"
			% str(result)
	)
	saved = restored_interpreter.make_execution_snapshot()
	_expect(
		saved.get("status") == "ok",
		"Providence-authored pending teleport remains a save boundary"
	)
	restored_state = ClassicRuntimeStateScript.new()
	restored_state.configure_from_bundle(bundle)
	restored_interpreter = InterpreterScript.new()
	restored_interpreter.configure(bundle, restored_state)
	restore_result = restored_interpreter.restore_execution_snapshot(
		saved.get("snapshot", {})
	)
	_expect(
		restore_result.get("status") == "ok",
		"Remake restores the Providence-authored pending teleport"
	)
	result = restored_interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "start_battle"
			and result.get("payload", {}).get("battleId") == 0,
		"Providence-authored teleport resumes into its authored battle: %s"
			% str(result)
	)
	saved = restored_interpreter.make_execution_snapshot()
	_expect(
		saved.get("status") == "ok",
		"Providence-authored pending battle remains a save boundary"
	)
	restored_state = ClassicRuntimeStateScript.new()
	restored_state.configure_from_bundle(bundle)
	restored_interpreter = InterpreterScript.new()
	restored_interpreter.configure(bundle, restored_state)
	restore_result = restored_interpreter.restore_execution_snapshot(
		saved.get("snapshot", {})
	)
	_expect(
		restore_result.get("status") == "ok",
		"Remake restores the Providence-authored pending battle"
	)
	result = restored_interpreter.resume_command({"won": true})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text"
			and result.get("payload", {}).get("text")
				== "The contract is complete. The captain records your success.",
		"Providence-authored battle resumes into completion presentation: %s"
			% str(result)
	)
	result = restored_interpreter.resume_command({})
	_expect(
		result.get("status") in ["yield", "completed"]
			and (
				result.get("status") == "completed"
				or result.get("command") != "show_text"
			),
		"Providence-authored scenario-scale AP returns to the central interpreter: %s"
			% str(result)
	)
	_expect(
		restored_interpreter.scenario_script_runtime.persistent_values.get(
			"campaign\u001f\u001fpaid_the_captain"
		) == true,
		"Providence-authored typed campaign state survives save restoration"
	)
	_expect(
		restored_interpreter.scenario_script_runtime.persistent_values.get(
			"campaign\u001f\u001fquest_stage"
		) == 2,
		"Providence-authored multi-stage quest state survives every yield"
	)
	_expect(
		restored_state.get_quest_value(1) == 1,
		"Classic execution resumes at the original slot after the Behavior returns"
	)
	_expect(
		not restored_interpreter.trace.is_empty()
			and restored_interpreter.trace[0].get("triggerId")
				== "land:0:ap:0"
			and restored_interpreter.trace[0].get("slot") == 1,
		"The first Classic instruction after the Behavior is original slot 1: %s"
			% str(restored_interpreter.trace)
	)
	var xap_state := ClassicRuntimeStateScript.new()
	xap_state.configure_from_bundle(bundle)
	var xap_interpreter := InterpreterScript.new()
	xap_interpreter.configure(bundle, xap_state)
	_expect(
		xap_interpreter.begin_trigger("Data ED3:macro:2"),
		"Providence-authored Extra Action Point starts through the interpreter"
	)
	var xap_result := xap_interpreter.run_until_yield()
	_expect(
		xap_result.get("status") == "yield"
			and xap_result.get("command") == "show_text"
			and xap_result.get("payload", {}).get("text")
				== "Before the preserved Extra Action Point.",
		"Before-XAP Behavior runs before the first preserved Classic action: %s"
			% str(xap_result)
	)
	var xap_saved := xap_interpreter.make_execution_snapshot()
	_expect(
		xap_saved.get("status") == "ok",
		"Pending before-XAP Behavior is a save boundary"
	)
	xap_state = ClassicRuntimeStateScript.new()
	xap_state.configure_from_bundle(bundle)
	xap_interpreter = InterpreterScript.new()
	xap_interpreter.configure(bundle, xap_state)
	_expect(
		xap_interpreter.restore_execution_snapshot(
			xap_saved.get("snapshot", {})
		).get("status") == "ok",
		"Before-XAP Behavior restores through the interpreter snapshot"
	)
	xap_result = xap_interpreter.resume_command({})
	_expect(
		xap_result.get("status") == "yield"
			and xap_result.get("command") == "show_text"
			and xap_result.get("payload", {}).get("messageId") == 0,
		"Before-XAP Behavior resumes into the preserved Classic XAP slot: %s"
			% str(xap_result)
	)
	xap_result = xap_interpreter.resume_command({})
	_expect(
		xap_result.get("status") == "yield"
			and xap_result.get("command") == "show_text"
			and xap_result.get("payload", {}).get("text")
				== "After the preserved Extra Action Point.",
		"After-XAP Behavior runs only after the preserved XAP completes: %s"
			% str(xap_result)
	)
	xap_saved = xap_interpreter.make_execution_snapshot()
	_expect(
		xap_saved.get("status") == "ok",
		"Pending after-XAP Behavior is a save boundary"
	)
	xap_state = ClassicRuntimeStateScript.new()
	xap_state.configure_from_bundle(bundle)
	xap_interpreter = InterpreterScript.new()
	xap_interpreter.configure(bundle, xap_state)
	_expect(
		xap_interpreter.restore_execution_snapshot(
			xap_saved.get("snapshot", {})
		).get("status") == "ok",
		"After-XAP Behavior restores through the interpreter snapshot"
	)
	xap_result = xap_interpreter.resume_command({})
	_expect(
		xap_result.get("status") == "completed",
		"After-XAP Behavior resumes into the deferred Classic completion: %s"
			% str(xap_result)
	)
	var trace_xap_state := ClassicRuntimeStateScript.new()
	trace_xap_state.configure_from_bundle(bundle)
	var trace_xap_interpreter := InterpreterScript.new()
	trace_xap_interpreter.configure(bundle, trace_xap_state)
	_expect(
		trace_xap_interpreter.begin_trigger("Data ED3:macro:2"),
		"Extra Action Point starts for attachment trace verification"
	)
	var trace_xap_result := trace_xap_interpreter.run_until_yield()
	while trace_xap_result.get("status") == "yield":
		trace_xap_result = trace_xap_interpreter.resume_command({})
	_expect(
		trace_xap_result.get("status") == "completed",
		"Extra Action Point trace replay reaches Classic completion"
	)
	var xap_attachment_hooks: Array = []
	for trace_value: Variant in trace_xap_interpreter.trace:
		if trace_value is Dictionary \
				and trace_value.get("event") == "behavior-attachment":
			xap_attachment_hooks.append(trace_value.get("hook"))
	_expect(
		xap_attachment_hooks == ["before-ap", "after-ap"],
		"Extra Action Point record attachments fire exactly once in order: %s"
			% str(xap_attachment_hooks)
	)


func _test_classic_enhanced_gosub_attachments() -> void:
	var war_bundle := BundleScript.new()
	_expect(
		war_bundle.load_from_directory(V3_FIXTURE),
		"War GOSUB fixture loads for Enhanced XAP attachments"
	)
	var behavior_bundle := BundleScript.new()
	_expect(
		behavior_bundle.load_from_directory(
			PROVIDENCE_SCRIPTING_ACCEPTANCE_FIXTURE
		),
		"Providence behavior fixture loads for Enhanced GOSUB attachments"
	)
	if not war_bundle.last_error.is_empty() \
			or not behavior_bundle.last_error.is_empty():
		return
	var source_document: Dictionary = behavior_bundle.documents.get(
		"remakeScripts",
		{}
	)
	var script_document := source_document.duplicate(true)
	var behavior_ids := [
		"scenario.providence.before-extra-action",
		"scenario.providence.after-extra-action",
	]
	var behaviors: Array = []
	for behavior_value: Variant in script_document.get("behaviors", []):
		if behavior_value is Dictionary \
				and str(behavior_value.get("id", "")) in behavior_ids:
			behaviors.append(behavior_value)
	var bindings: Array = []
	for binding_value: Variant in script_document.get("bindings", []):
		if not (binding_value is Dictionary):
			continue
		var behavior_id := str(binding_value.get("behaviorId", ""))
		if behavior_id not in behavior_ids:
			continue
		var binding: Dictionary = binding_value
		binding["recordId"] = "Data ED3:macro:1027"
		bindings.append(binding)
	script_document["behaviors"] = behaviors
	script_document["bindings"] = bindings
	script_document["stateDefinitions"] = []
	script_document["migrations"] = []
	war_bundle.documents["remakeScripts"] = script_document
	var state := ClassicRuntimeStateScript.new()
	state.configure_from_bundle(war_bundle)
	state.set_quest_flag(29)
	state.set_quest_flag(64)
	var interpreter := InterpreterScript.new()
	interpreter.configure(war_bundle, state)
	_expect(
		interpreter.begin_trigger("Data DD:9:48", 3),
		"War GOSUB chain starts with Enhanced XAP attachments"
	)
	var result := interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text",
		"War GOSUB chain reaches its source random text"
	)
	result = interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("payload", {}).get("text")
				== "Before the preserved Extra Action Point.",
		"Before-XAP Behavior runs on GOSUB entry before XAP 1027: %s"
			% str(result)
	)
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("payload", {}).get("messageId") == 1110,
		"GOSUB entry resumes into XAP 1027's first Classic action: %s"
			% str(result)
	)
	result = interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("payload", {}).get("messageId") == 1246,
		"Nested GOSUB remains source-faithful beneath the attached XAP"
	)
	result = interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("payload", {}).get("text")
				== "After the preserved Extra Action Point.",
		"After-XAP Behavior runs after opcode 111 returns from XAP 1027: %s"
			% str(result)
	)
	result = interpreter.resume_command({})
	_expect(
		result.get("status") == "completed"
			and result.get("reason") == "keep-codes",
		"After-XAP Behavior resumes the suspended War caller to completion: %s"
			% str(result)
	)
	var attachment_hooks: Array = []
	for trace_value: Variant in interpreter.trace:
		if trace_value is Dictionary \
				and trace_value.get("event") == "behavior-attachment":
			attachment_hooks.append(trace_value.get("hook"))
	_expect(
		attachment_hooks == ["before-ap", "after-ap"],
		"GOSUB entry and return fire each XAP attachment exactly once: %s"
			% str(attachment_hooks)
	)


func _test_city_of_bywater_enhanced_ap() -> void:
	var city_bundle := BundleScript.new()
	_expect(
		city_bundle.load_from_directory(CITY_OF_BYWATER_CAMPAIGN),
		"City of Bywater loads for the Classic Enhanced AP proof"
	)
	var behavior_bundle := BundleScript.new()
	_expect(
		behavior_bundle.load_from_directory(
			PROVIDENCE_SCRIPTING_ACCEPTANCE_FIXTURE
		),
		"Providence behavior fixture loads for the City of Bywater proof"
	)
	if not city_bundle.last_error.is_empty() \
			or not behavior_bundle.last_error.is_empty():
		return
	var behavior_document: Dictionary = behavior_bundle.documents.get(
		"remakeScripts",
		{}
	).duplicate(true)
	for binding_value: Variant in behavior_document.get("bindings", []):
		if binding_value is Dictionary \
				and binding_value.get("id") \
					== "binding.providence.acceptance.action":
			binding_value["recordId"] = "Data DD:0:0"
	city_bundle.documents["remakeScripts"] = behavior_document
	var city_state := ClassicRuntimeStateScript.new()
	city_state.configure_from_bundle(city_bundle)
	var city_interpreter := InterpreterScript.new()
	city_interpreter.configure(city_bundle, city_state)
	_expect(
		city_interpreter.begin_trigger("Data DD:0:0"),
		"City of Bywater AP 0 starts through the central interpreter"
	)
	var result := city_interpreter.run_until_yield()
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text"
			and result.get("payload", {}).get("messageId") == 50,
		"City of Bywater executes its original Classic text slot first: %s"
			% str(result)
	)
	result = city_interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "query_party_wealth",
		"City of Bywater enters the attached Behavior after Classic text: %s"
			% str(result)
	)
	result = city_interpreter.resume_command({
		"gold": 500,
		"gems": 0,
		"jewelry": 0,
		"pooledGold": 500,
	})
	result = city_interpreter.resume_command({
		"day": 3,
		"hour": 12,
		"minute": 0,
		"second": 0,
		"totalSeconds": 216000,
	})
	result = city_interpreter.resume_command({
		"value": [{
			"id": "party:0",
			"name": "Bywater Hero",
			"level": 1,
			"raceId": 1,
			"raceName": "Human",
			"casteId": 1,
			"casteName": "Warrior",
			"gender": 0,
			"health": 10,
			"maximumHealth": 10,
			"spellPoints": 0,
			"maximumSpellPoints": 0,
			"strength": 10,
			"intellect": 10,
			"wisdom": 10,
			"dexterity": 10,
			"vitality": 10,
			"luck": 10,
			"movement": 12,
			"conditions": [],
			"itemIds": [],
			"alive": true,
		}],
	})
	result = city_interpreter.resume_command({"paid": true})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text",
		"City of Bywater enhanced Behavior reaches its guided presentation"
	)
	result = city_interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "choice",
		"City of Bywater enhanced Behavior reaches its guided choice"
	)
	result = city_interpreter.resume_command({"choice": 1})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "show_text",
		"City of Bywater enhanced Behavior follows the declined branch"
	)
	result = city_interpreter.resume_command({})
	_expect(
		result.get("status") == "yield"
			and result.get("command") == "start_encounter"
			and result.get("payload", {}).get("encounterKind") == "simple"
			and result.get("payload", {}).get("encounterId") == 0,
		"City of Bywater resumes into original Classic encounter slot 2: %s"
			% str(result)
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


func _test_engine_plugin_registry() -> void:
	var plugin_fixture_root := (
		"res://scripts/scenario_runtime/tests/fixtures/engine-plugin"
	)
	var plugin_script_path := (
		plugin_fixture_root + "/example.weather/plugin.gd"
	)
	var plugin_source := FileAccess.get_file_as_bytes(plugin_script_path)
	var plugin_files := [{
		"path": "plugin.gd",
		"size": plugin_source.size(),
		"sha256": EnginePluginRegistryScript.content_hash_for_file(
			plugin_script_path
		),
	}]
	var descriptor := {
		"id": "example.weather",
		"apiVersion": 1,
		"approved": false,
		"approvedHash": "",
		"entryPoint": "plugin.gd",
		"files": plugin_files,
		"contentHash": EnginePluginRegistryScript.content_hash_for_files(
			plugin_files
		),
		"providers": [{
			"id": "example.weather.forecast-provider",
			"method": "forecast",
		}],
		"operations": [{
			"id": "example.weather.forecast",
			"label": "Forecast Weather",
			"category": "Example",
			"owningPort": "engine.plugins",
			"minimumTier": "safe",
			"roles": ["action", "helper"],
			"yields": true,
			"mutates": false,
			"commandId": "example.weather.forecast-command",
			"providerId": "example.weather.forecast-provider",
			"parameters": {"value": "int"},
			"result": "int",
			"summary": "Returns a fixture forecast.",
			"reference": "Used to prove installed plug-in registration.",
			"example": "var forecast = await weather_forecast(1)",
		}],
	}
	descriptor["approvedHash"] = EnginePluginRegistryScript.approval_hash(
		descriptor
	)
	descriptor["approved"] = true
	var registry := EnginePluginRegistryScript.new()
	registry.install_root = plugin_fixture_root
	_expect(
		registry.load_catalog_document({
			"schemaVersion": 1,
			"plugins": [descriptor],
		}),
		"engine plug-in catalog accepts exact-hash approved descriptors"
	)
	_expect(
		registry.validate_requirements([{
			"id": "example.weather",
			"apiVersion": 1,
		}]).get("valid", false),
		"engine plug-in requirements resolve installed approved APIs"
	)
	var operation_rows: Array = registry.operation_descriptors([{
		"id": "example.weather",
		"apiVersion": 1,
	}])
	_expect(
		operation_rows.size() == 1
			and operation_rows[0].get("id") == "example.weather.forecast",
		"engine plug-ins expose only required namespaced capabilities"
	)
	_expect(
		registry.activate_required([{
			"id": "example.weather",
			"apiVersion": 1,
		}]),
		"approved engine plug-ins load only from their installed entry point: %s"
			% registry.last_error
	)
	var plugin_port := ScenarioEnginePluginPort.new()
	plugin_port.bind_registry(registry)
	var plugin_router := ScenarioCommandRouter.new()
	_expect(
		plugin_router.register_port(plugin_port),
		"active engine plug-in commands register through one bridge port"
	)
	plugin_router.configure({"enginePluginRegistry": registry})
	var provider_result: Dictionary = await plugin_router.route(
		"example.weather.forecast-command",
		{"value": 4}
	)
	_expect(
		provider_result.get("status") == "ok"
			and int(provider_result.get("value", 0)) == 5,
		"engine plug-in providers execute through validated command routing"
	)
	var changed_descriptor: Dictionary = descriptor.duplicate(true)
	changed_descriptor["apiVersion"] = 2
	var changed_registry := EnginePluginRegistryScript.new()
	_expect(
		not changed_registry.load_catalog_document({
			"schemaVersion": 1,
			"plugins": [changed_descriptor],
		})
			and changed_registry.last_error.contains("changed after approval"),
		"engine plug-in metadata changes invalidate approval"
	)
	var core_descriptor: Dictionary = descriptor.duplicate(true)
	core_descriptor["approved"] = false
	core_descriptor["operations"][0]["id"] = "core.override"
	core_descriptor["approvedHash"] = (
		EnginePluginRegistryScript.approval_hash(core_descriptor)
	)
	var core_registry := EnginePluginRegistryScript.new()
	_expect(
		not core_registry.load_catalog_document({
			"schemaVersion": 1,
			"plugins": [core_descriptor],
		}),
		"engine plug-ins cannot register reserved core capabilities"
	)


func _test_engine_plugin_store() -> void:
	var fixture_manifest := (
		"res://scripts/scenario_runtime/tests/fixtures/engine-plugin/"
		+ "example.weather/plugin.json"
	)
	var test_root := "user://scenario_plugin_store_test_%d" \
		% Time.get_ticks_usec()
	var store := EnginePluginStoreScript.new()
	store.install_root = test_root
	store.catalog_path = test_root.path_join("installed.json")
	var inspection: Dictionary = store.inspect_manifest(fixture_manifest)
	_expect(
		inspection.get("status") == "ok",
		"engine plug-in packages inspect without executing source: %s"
			% inspection.get("message", "")
	)
	var installation: Dictionary = store.install_from_manifest(fixture_manifest)
	_expect(
		installation.get("status") == "ok",
		"engine plug-in packages install from an exact file manifest: %s"
			% installation.get("message", "")
	)
	var installed_descriptor: Dictionary = store.descriptor("example.weather")
	_expect(
		not bool(installed_descriptor.get("approved", true)),
		"newly installed engine plug-ins are not implicitly approved"
	)
	_expect(
		store.approve("example.weather"),
		"exact installed engine plug-in packages can be approved: %s"
			% store.last_error
	)
	installed_descriptor = store.descriptor("example.weather")
	_expect(
		bool(installed_descriptor.get("approved", false)),
		"engine plug-in approval persists in the user-local catalog"
	)
	var update_result: Dictionary = store.install_from_manifest(
		fixture_manifest,
		true
	)
	_expect(
		update_result.get("status") == "ok"
			and bool(update_result.get("updated", false))
			and not bool(
				store.descriptor("example.weather").get("approved", true)
			),
		"engine plug-in updates revoke approval"
	)
	_expect(
		store.approve("example.weather"),
		"updated engine plug-ins can be explicitly reapproved"
	)
	var installed_script := test_root.path_join("example.weather/plugin.gd")
	var tampered := FileAccess.open(installed_script, FileAccess.WRITE)
	if tampered != null:
		tampered.store_string("extends RefCounted\n")
		tampered.flush()
		tampered = null
	_expect(
		not store.approve("example.weather")
			and store.last_error.contains("changed"),
		"engine plug-in file changes invalidate approval"
	)
	var repair_result: Dictionary = store.install_from_manifest(
		fixture_manifest,
		true
	)
	_expect(
		repair_result.get("status") == "ok",
		"reinstalling an exact package repairs changed plug-in files: %s"
			% repair_result.get("message", "")
	)
	_expect(
		store.approve("example.weather")
			and store.revoke("example.weather")
			and not bool(
				store.descriptor("example.weather").get("approved", true)
			),
		"engine plug-in approval can be revoked"
	)
	_expect(
		store.remove("example.weather")
			and store.plugin_descriptors().is_empty(),
		"engine plug-ins can be removed from the user-local store"
	)
	var catalog_global := ProjectSettings.globalize_path(store.catalog_path)
	if FileAccess.file_exists(store.catalog_path):
		DirAccess.remove_absolute(catalog_global)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(test_root))


func _test_engine_plugin_settings_ui() -> void:
	var settings_scene: PackedScene = load(
		"res://scenes/UI/HUD/Settings/settings_rect.tscn"
	)
	var settings: Node = settings_scene.instantiate()
	add_child(settings)
	var panel := settings.get_node_or_null(
		"HBoxContainer/ScenarioPluginSettings"
	)
	_expect(
		panel != null
			and panel.get_node_or_null("VBoxContainer/Content/PluginList") != null
			and panel.get_node_or_null(
				"VBoxContainer/Toolbar/InstallPluginButton"
			) != null
			and panel.get_node_or_null(
				"VBoxContainer/Content/Details/Actions/ApprovePluginButton"
			) != null
			and panel.get_node_or_null(
				"VBoxContainer/Content/Details/Actions/RevokePluginButton"
			) != null
			and panel.get_node_or_null(
				"VBoxContainer/Content/Details/Actions/RemovePluginButton"
			) != null,
		"Remake Settings exposes plug-in install and approval management"
	)
	settings.queue_free()


func _test_command_ports() -> void:
	var result := DefaultPortsScript.create(RefCounted.new())
	_expect(result.get("status") == "ok", "six default command ports register")
	if result.get("status") != "ok":
		return
	var router: ScenarioCommandRouter = result["router"]
	for command_id: String in [
		"teleport",
		"query_map_definition",
		"start_battle",
		"query_monster_definition",
		"apply_combat_condition",
		"give_treasure",
		"query_party_items",
		"query_item_definition",
		"pick_characters",
		"query_spell_definition",
		"show_text",
		"query_encounter_definition",
		"query_media_definition",
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


func _test_definition_snapshot_services() -> void:
	var bundle := BundleScript.new()
	_expect(
		bundle.load_from_directory(PROVIDENCE_SCRIPTING_ACCEPTANCE_FIXTURE),
		"definition snapshot fixture bundle loads"
	)
	if not bundle.last_error.is_empty():
		return
	var services := ScenarioGodotServicesScript.new()
	services.configure_classic_bundle(bundle)
	var map_service: Object = services.scenario_port_runtime("core.map")
	var combat_service: Object = services.scenario_port_runtime("core.combat")
	var inventory_service: Object = services.scenario_port_runtime(
		"core.inventory"
	)
	var character_service: Object = services.scenario_port_runtime(
		"core.character"
	)
	var presentation_service: Object = services.scenario_port_runtime(
		"core.presentation"
	)
	var map_definition: Dictionary = map_service._query_map_definition({
		"levelType": "land",
		"levelIndex": 0,
	})
	var monster_definition: Dictionary = (
		combat_service._query_monster_definition({"monsterId": 1})
	)
	var battle_definition: Dictionary = combat_service._query_battle_definition(
		{"battleId": 0}
	)
	var item_definition: Dictionary = inventory_service._query_item_definition(
		{"itemId": 901}
	)
	var original_party: Array = GameGlobal.player_characters
	var item_carrier := PartyItemCarrier.new()
	item_carrier.item_inventory.append(ItemInstance.new(
		"instance:acceptance-token",
		"scenario:acceptance:item:901",
		7,
		true,
		false
	))
	GameGlobal.player_characters = [item_carrier]
	var item_instances: Dictionary = inventory_service._query_party_items()
	GameGlobal.player_characters = original_party
	var spell_definition: Dictionary = (
		character_service._query_spell_definition({"spellId": 16})
	)
	var encounter_definition: Dictionary = (
		presentation_service._query_encounter_definition({
			"encounterKind": "simple",
			"encounterId": 0,
		})
	)
	var media_definition: Dictionary = (
		presentation_service._query_media_definition({
			"mediaKind": "picture",
			"resourceId": 306,
		})
	)
	_expect(
		map_definition.get("id") == "land:0"
			and int(map_definition.get("width", 0)) == 90,
		"map definitions are exposed as bounded immutable snapshots"
	)
	_expect(
		monster_definition.get("name") == "Providence Sentinel"
			and int(monster_definition.get("maximumHealth", 0)) == 31,
		"monster definitions preserve authored identity and combat metadata"
	)
	_expect(
		battle_definition.get("monsterIds", []) == [1],
		"battle definitions expose bounded referenced monster identities"
	)
	_expect(
		item_definition.get("id") == "901"
			and int(item_definition.get("itemType", 0)) == 25,
		"item definitions remain separate from live item instances: %s"
			% str(item_definition)
	)
	var item_snapshots: Array = item_instances.get("items", [])
	_expect(
		item_snapshots.size() == 1
			and item_snapshots[0].get("id") == "instance:acceptance-token"
			and item_snapshots[0].get("definitionId") \
				== "scenario:acceptance:item:901"
			and int(item_snapshots[0].get("charges", 0)) == 7
			and bool(item_snapshots[0].get("equipped", false))
			and not bool(item_snapshots[0].get("identified", true)),
		"item-instance queries preserve exact identity and mutable state: %s"
			% str(item_snapshots)
	)
	_expect(
		spell_definition.get("name") == "Providence Ward"
			and int(spell_definition.get("cost", 0)) == 4,
		"spell definitions are data snapshots rather than GDScript resources: %s"
			% str(spell_definition)
	)
	_expect(
		encounter_definition.get("encounterKind") == "simple"
			and int(encounter_definition.get("optionCount", 0)) == 1,
		"encounter definitions expose bounded authoring metadata"
	)
	_expect(
		media_definition.get("mediaKind") == "picture"
			and str(media_definition.get("runtimePath", "")).ends_with(
				".png"
			),
		"media definitions expose package-relative runtime metadata"
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
		"returnType": "spell-effect-outcome",
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
			"spell-effect-outcome",
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

	var debug_runtime := ScenarioScriptRuntimeScript.new()
	_expect(
		debug_runtime.configure(document, state, bundle),
		"nested debugger behavior runtime configures"
	)
	outer_step = debug_runtime.invoke("scenario.test.outer-battle")
	_expect(
		outer_step.kind == ScenarioStepResult.YIELD
			and outer_step.data.get("commandId") == "start_battle",
		"nested debugger fixture suspends its outer action"
	)
	_expect(
		debug_runtime.configure_debugger([], true).get("status") == "ok",
		"nested debugger enables pause on behavior start"
	)
	nested_step = debug_runtime.invoke_nested(
		"scenario.test.nested-spell",
		{},
		{"role": "spell", "hook": "effect"}
	)
	var debug_snapshot: Dictionary = debug_runtime.debugger_snapshot()
	_expect(
		nested_step.kind == ScenarioStepResult.YIELD
			and nested_step.data.get("commandId") == "scenario_debug_pause"
			and bool(debug_snapshot.get("paused", false))
			and debug_snapshot.get("callStack", []).size() == 2
			and str(debug_snapshot.get("pause", {}).get("sourceNode", "")) \
				== "nested-text",
		"nested Safe behavior pauses at its first statement while the outer action remains suspended"
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
			"spell-effect-outcome"
		),
		"spell effects accept bounded lifecycle schedules"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "blocked", "reason": "No valid target."},
			"spell-validation-outcome"
		),
		"spell validation accepts an explicit blocked result"
	)
	_expect(
		not ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "applied"},
			"spell-validation-outcome"
		),
		"spell validation rejects effect-phase outcomes"
	)
	_expect(
		ScenarioScriptRuntimeScript._value_matches_script_type(
			{"kind": "cancelled", "reason": "The caster was interrupted."},
			"spell-cast-outcome"
		),
		"spell casting accepts an explicit cancellation"
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
	runner.cancel_cast = true
	var cancelled: Dictionary = await port.run_spell_behavior(
		spell,
		null,
		[],
		3,
		{"mode": "combat"}
	)
	_expect(
		cancelled.get("status") == "ok"
			and bool(cancelled.get("cancelled", false))
			and not bool(cancelled.get("valid", true)),
		"a cancelled casting phase stops before the spell effect"
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
	var cancel_cast := false

	func has_behavior_attachments(
		role: String,
		hook: String,
		target_kind: String,
		target_ids: Array,
		_slot := -1
	) -> bool:
		return role == "spell" \
			and (
				hook in ["validate", "effect"]
				or (hook == "cast" and cancel_cast)
			) \
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
		var outcome := {"kind": "applied"}
		if hook == "validate":
			outcome = {"kind": "allowed"}
		elif hook == "cast":
			outcome = {"kind": "cancelled", "reason": "Fixture interruption"}
		return {
			"status": "ok",
			"handled": true,
			"results": [{
				"status": "ok",
				"value": outcome,
			}],
		}
