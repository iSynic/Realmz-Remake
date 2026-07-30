class_name ScenarioInterpreter
extends RefCounted

const ClassicOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_opcode_runtime.gd"
)
const CoreHandlerCatalogScript = preload(
	"res://scripts/scenario_runtime/handlers/core_handler_catalog.gd"
)
const ClassicContinuationRouterScript = preload(
	"res://scripts/scenario_runtime/classic_continuation_router.gd"
)
const ClassicExecutionStateScript = preload(
	"res://scripts/scenario_runtime/classic_execution_state.gd"
)
const ScenarioScriptRuntimeScript = preload(
	"res://scripts/scenario_runtime/scenario_script_runtime.gd"
)
const SNAPSHOT_SCHEMA_VERSION := 2
const MAX_INTERNAL_STEPS := 256
const MAX_CALL_STACK_DEPTH := 20

var instruction_registry: ScenarioInstructionRegistry
var triggers: Dictionary = {}
var current_trigger_id := ""
var current_action_index := 0
var call_stack: Array = []
var encounter_origins: Array = []
var pending_command: ScenarioPendingCommand
var execution_context: Dictionary = {}
var trace: Array = []
var halted := true
var last_result: Dictionary = {}
var _classic_executor: Object
var _classic_continuation_router: ClassicContinuationRouter
var _classic_mode := false
var classic_execution_state: RefCounted
var scenario_script_runtime: ScenarioScriptRuntime
var _classic_attachment_queue: Array = []
var _classic_deferred_instruction: Dictionary = {}
var _classic_deferred_result: Dictionary = {}
var _classic_executing_anchor: Dictionary = {}
var _classic_pending_after_anchor: Dictionary = {}

var runtime_state: ClassicRuntimeState:
	get:
		return _classic_executor.runtime_state if _classic_executor != null else null
var active_action_point_header: Dictionary:
	get:
		return (
			_classic_executor.active_action_point_header
			if _classic_executor != null else {}
		)
var gosub_active: bool:
	get:
		return bool(_classic_executor.gosub_active) if _classic_executor != null else false
var remove_action_point: bool:
	get:
		return (
			bool(_classic_executor.remove_action_point)
			if _classic_executor != null else false
		)
var pending_choice: Dictionary:
	get:
		return _classic_pending("pending_choice")
var pending_encounter: Dictionary:
	get:
		return _classic_pending("pending_encounter")
var pending_battle: Dictionary:
	get:
		return _classic_pending("pending_battle")
var pending_selective_battle: Dictionary:
	get:
		return _classic_pending("pending_selective_battle")
var pending_random_branch: Dictionary:
	get:
		return _classic_pending("pending_random_branch")
var last_error: String:
	get:
		return str(_classic_executor.last_error) if _classic_executor != null else ""


static func normalize_opcode(raw_code: int) -> int:
	return ClassicOpcodeRuntimeScript.normalize_opcode(raw_code)


static func handles_opcode(code: int) -> bool:
	return ClassicOpcodeRuntimeScript.handles_opcode(code)


func configure(registry_or_bundle: Variant, triggers_or_state: Variant) -> void:
	if registry_or_bundle is ClassicCampaignBundle \
			and triggers_or_state is ClassicRuntimeState:
		_configure_classic_compatibility(registry_or_bundle, triggers_or_state)
		return
	_classic_mode = false
	_classic_executor = null
	classic_execution_state = null
	instruction_registry = registry_or_bundle
	triggers = (
		triggers_or_state.duplicate(true)
		if triggers_or_state is Dictionary
		else {}
	)
	reset()


func _configure_classic_compatibility(
	campaign_bundle: ClassicCampaignBundle,
	state: ClassicRuntimeState
) -> void:
	_classic_mode = true
	instruction_registry = ScenarioInstructionRegistry.new()
	if not CoreHandlerCatalogScript.register_all(instruction_registry):
		last_result = {
			"status": "error",
			"message": instruction_registry.last_error,
		}
		halted = true
		return
	if campaign_bundle.extension_registry != null and not (
		campaign_bundle.extension_registry.register_instruction_handlers(
			instruction_registry,
			campaign_bundle.required_extension_ids()
		)
	):
		last_result = {
			"status": "error",
			"message": campaign_bundle.extension_registry.last_error,
		}
		halted = true
		return
	if campaign_bundle.extension_registry != null and not (
		campaign_bundle.extension_registry.activate_providers(
			campaign_bundle.required_extension_ids(),
			campaign_bundle.documents.get("runtime", {}).get(
				"requiredExtensions",
				[]
			)
		)
	):
		last_result = {
			"status": "error",
			"message": campaign_bundle.extension_registry.last_error,
		}
		halted = true
		return
	classic_execution_state = ClassicExecutionStateScript.new()
	_classic_executor = ClassicOpcodeRuntimeScript.new()
	_classic_executor.bind_execution_state(classic_execution_state)
	_classic_executor.configure(campaign_bundle, state)
	scenario_script_runtime = ScenarioScriptRuntimeScript.new()
	var script_document: Dictionary = campaign_bundle.documents.get(
		"remakeScripts",
		{}
	)
	if script_document.is_empty():
		script_document = ScenarioScriptRuntimeScript.empty_document()
	if not scenario_script_runtime.configure(
		script_document,
		state,
		campaign_bundle
	):
		last_result = {
			"status": "error",
			"message": scenario_script_runtime.last_error,
		}
		halted = true
		return
	_classic_continuation_router = ClassicContinuationRouterScript.new()
	_classic_continuation_router.configure(_classic_executor)
	_classic_executor.set_scenario_run_delegate(
		Callable(self, "_resume_classic_run_loop")
	)
	_reset_classic_attachment_plan()
	_sync_classic_observability()


func set_percent_roll_provider(provider: Callable) -> void:
	if _classic_executor != null:
		_classic_executor.set_percent_roll_provider(provider)


func reset_execution() -> void:
	if _classic_executor != null:
		_classic_executor.reset_execution()
		_reset_classic_attachment_plan()
		_sync_classic_observability()
		return
	reset()


func begin_trigger(trigger_id: String, start_slot := 0, context := {}) -> bool:
	if _classic_executor == null:
		var started := start(trigger_id, start_slot, context)
		return str(started.get("status", "")) == "ok"
	var result: bool = _classic_executor.begin_trigger(trigger_id, start_slot, context)
	_reset_classic_attachment_plan()
	if result:
		_queue_classic_attachments(
			"before-ap",
			{"triggerId": trigger_id, "slot": null, "callDepth": 0}
		)
	_sync_classic_observability()
	return result


func run_until_yield() -> Dictionary:
	if _classic_executor == null:
		return _error("Classic compatibility execution is not configured")
	if pending_command != null \
			and pending_command.handler_id.begins_with("core.") \
			and str(
				pending_command.action_identity.get("kind", "")
			) == "classic":
		var continuation_id := str(pending_command.continuation.get(
				"_continuationId",
				""
			))
		if continuation_id.is_empty() \
				or continuation_id == "dungeon-move":
			return resume_command({})
	return _classic_result(_run_classic_loop())


func _run_classic_loop() -> Dictionary:
	if instruction_registry == null:
		return _classic_error("Scenario instruction registry is unavailable")
	if pending_command != null:
		return _classic_error(
			"Scenario VM is waiting for command '%s'" % pending_command.command_id
		)
	for _step: int in range(MAX_INTERNAL_STEPS):
		var prepared: Dictionary = _take_next_classic_plan_instruction()
		if str(prepared.get("status", "")) != "instruction":
			return prepared
		var instruction_value: Variant = prepared.get("instruction")
		if not (instruction_value is Dictionary):
			return _classic_error(
				"Classic opcode runtime returned an invalid instruction"
			)
		var instruction := _normalized_instruction(instruction_value)
		var handler := instruction_registry.resolve(instruction)
		if handler == null:
			if _classic_executor.is_prepared_instruction_dispatcher_noop(
				instruction_value
			):
				continue
			return _classic_executor.unsupported_instruction_result(
				instruction_value
			)
		var action_identity := _classic_action_identity(instruction)
		if str(instruction.get("kind", "classic")) == "semantic":
			action_identity = _classic_semantic_action_identity(
				instruction,
				action_identity
			)
		var step_result: ScenarioStepResult
		if str(instruction.get("kind", "classic")) == "semantic":
			step_result = handler.execute(instruction, self)
			var semantic_result := _classic_semantic_step(
				step_result,
				handler.handler_id(),
				action_identity
			)
			if str(semantic_result.get("status", "")) == "continue":
				continue
			return semantic_result
		step_result = handler.execute(instruction, self)
		if step_result == null or not step_result.is_valid():
			return _classic_error(
				"Classic scenario handler '%s' returned an invalid result"
				% handler.handler_id()
			)
		var classic_result: Variant = step_result.data.get("classicResult")
		if not (classic_result is Dictionary):
			return _classic_error(
				"Classic scenario handler '%s' did not return opcode state"
				% handler.handler_id()
			)
		var classic_status := str(classic_result.get("status", ""))
		if classic_status == "continue":
			_queue_classic_attachments("after-slot", _classic_executing_anchor)
			_queue_classic_record_transition_attachments(
				_classic_executing_anchor
			)
			_classic_executing_anchor.clear()
			continue
		if classic_status == "yield":
			_classic_pending_after_anchor = \
				_classic_executing_anchor.duplicate(true)
		elif classic_status == "completed":
			_classic_pending_after_anchor.clear()
			_queue_classic_attachments("after-slot", _classic_executing_anchor)
			_queue_classic_record_transition_attachments(
				_classic_executing_anchor
			)
			_classic_executing_anchor.clear()
			if not _classic_attachment_queue.is_empty():
				_classic_deferred_result = classic_result.duplicate(true)
				continue
		else:
			_classic_pending_after_anchor.clear()
		_classic_executing_anchor.clear()
		classic_result["_scenarioHandlerId"] = handler.handler_id()
		classic_result["_scenarioActionIdentity"] = action_identity
		return classic_result
	return _classic_error(
		"Scenario VM exceeded %d internal Classic steps" % MAX_INTERNAL_STEPS
	)


func _resume_classic_run_loop() -> Dictionary:
	_activate_pending_after_attachments()
	return _run_classic_loop()


func execute_classic_instruction(
	handler_id: String,
	instruction: Dictionary
) -> ScenarioStepResult:
	if _classic_executor == null:
		return ScenarioStepResult.failed(
			"Classic opcode runtime is not configured"
		)
	var registered_handler := instruction_registry.resolve(instruction)
	if registered_handler == null or registered_handler.handler_id() != handler_id:
		return ScenarioStepResult.failed(
			"Classic opcode ownership changed during execution"
		)
	if not registered_handler.has_method("execute_on_runtime"):
		return ScenarioStepResult.failed(
			"Classic handler '%s' has no runtime implementation" % handler_id
		)
	var result: Variant = registered_handler.call(
		"execute_on_runtime",
		instruction,
		_classic_executor
	)
	if not (result is Dictionary):
		return ScenarioStepResult.failed(
			"Classic opcode runtime returned an invalid result"
		)
	return ScenarioStepResult.continued({"classicResult": result})


func resume_choice(accepted: bool) -> Dictionary:
	return resume_command({"accepted": accepted})


func resume_encounter(outcome: int, encounter_state := {}) -> Dictionary:
	var response: Dictionary = (
		encounter_state.duplicate(true) if encounter_state is Dictionary else {}
	)
	response["outcome"] = outcome
	return resume_command(response)


func resume_battle(coward: bool) -> Dictionary:
	return resume_command({"coward": coward})


func resume_selective_battle(survivor_count: int) -> Dictionary:
	return resume_command({"survivorCount": survivor_count})


func resume_forced_battle_end() -> Dictionary:
	return resume_command({})


func resume_forced_battle_at_slot(resume_slot: int) -> Dictionary:
	return resume_command({"forcedResumeSlot": resume_slot})


func resume_teleport() -> Dictionary:
	return resume_command({})


func resume_item_check(possessed: bool) -> Dictionary:
	return resume_command({"possessed": possessed})


func resume_wealth_payment(paid: bool) -> Dictionary:
	return resume_command({"paid": paid})


func resume_party_condition_check(active: bool) -> Dictionary:
	return resume_command({"active": active})


func resume_character_ability_check(passed: bool) -> Dictionary:
	return resume_command({"passed": passed})


func resume_misc_branch(matched: bool) -> Dictionary:
	return resume_command({"matched": matched})


func resume_ally_check(present: bool) -> Dictionary:
	return resume_command({"present": present})


func resume_combat_monster_check(present: bool) -> Dictionary:
	return resume_command({"present": present})


func resume_combat_revival(party_revived: bool) -> Dictionary:
	return resume_command({"partyRevived": 1 if party_revived else 0})


func resume_battle_round_macro() -> Dictionary:
	return resume_command({})


func resume_random_branch() -> Dictionary:
	return resume_command({})


func resume_back_up_party() -> Dictionary:
	return resume_command({})


func resume_time_mutation(response: Dictionary) -> Dictionary:
	return resume_command(response)


func resume_exploration_status(response: Dictionary) -> Dictionary:
	return resume_command(response)


func resume_command(response: Dictionary) -> Dictionary:
	if _classic_executor == null:
		return _error("Classic compatibility execution is not configured")
	if pending_command == null:
		return _classic_error("No scenario command is waiting for a response")
	var saved_pending := pending_command
	pending_command = null
	var handler := instruction_registry.handler_by_id(saved_pending.handler_id)
	if handler == null:
		return _classic_error(
			"Pending scenario handler '%s' is unavailable" % saved_pending.handler_id
		)
	var step := handler.resume(saved_pending, response, self)
	if str(saved_pending.action_identity.get("kind", "")) == "semantic":
		var semantic_result := _classic_semantic_step(
			step,
			saved_pending.handler_id,
			saved_pending.action_identity
		)
		if str(semantic_result.get("status", "")) == "continue":
			return _classic_result(_run_classic_loop())
		return _classic_result(semantic_result)
	if step == null or not step.is_valid():
		return _classic_error(
			"Classic scenario handler '%s' returned an invalid resume result"
			% saved_pending.handler_id
		)
	var classic_result: Variant = step.data.get("classicResult")
	if not (classic_result is Dictionary):
		return _classic_error(
			"Classic scenario handler '%s' did not return continuation state"
			% saved_pending.handler_id
		)
	var pending_anchor := _classic_pending_after_anchor.duplicate(true)
	if str(classic_result.get("status", "")) == "continue":
		_activate_pending_after_attachments()
		_queue_classic_record_transition_attachments(pending_anchor)
		return _classic_result(_run_classic_loop())
	if str(classic_result.get("status", "")) == "completed" \
			and not _classic_pending_after_anchor.is_empty():
		_activate_pending_after_attachments()
		_queue_classic_record_transition_attachments(pending_anchor)
		if not _classic_attachment_queue.is_empty():
			_classic_deferred_result = classic_result.duplicate(true)
			return _classic_result(_run_classic_loop())
	_classic_pending_after_anchor.clear()
	return _classic_result(classic_result)


func resume_classic_instruction(
	handler_id: String,
	pending_value: Dictionary,
	response: Dictionary
) -> ScenarioStepResult:
	if _classic_continuation_router == null:
		return ScenarioStepResult.failed("Classic continuation registry is unavailable")
	var pending := ScenarioPendingCommand.from_dictionary(pending_value)
	if pending == null:
		return ScenarioStepResult.failed("Classic continuation record is invalid")
	if pending.handler_id != handler_id:
		return ScenarioStepResult.failed(
			"Classic continuation handler identity changed during resume"
		)
	var result: Dictionary = _classic_continuation_router.resume(pending, response)
	return ScenarioStepResult.continued({"classicResult": result})


func make_execution_snapshot() -> Dictionary:
	if _classic_executor == null:
		return {"status": "ok", "snapshot": snapshot()}
	var result: Dictionary = classic_execution_state.make_snapshot()
	if str(result.get("status", "")) == "ok":
		result["snapshot"]["scenarioPendingCommand"] = (
			pending_command.to_dictionary() if pending_command != null else null
		)
		result["snapshot"]["classicAttachmentState"] = {
			"queue": _classic_attachment_queue.duplicate(true),
			"deferredInstruction": _classic_deferred_instruction.duplicate(true),
			"deferredResult": _classic_deferred_result.duplicate(true),
			"executingAnchor": _classic_executing_anchor.duplicate(true),
			"pendingAfterAnchor": _classic_pending_after_anchor.duplicate(true),
		}
		result["snapshot"]["scenarioScriptRuntime"] = (
			scenario_script_runtime.snapshot()
			if scenario_script_runtime != null
			else {
				"schemaVersion": 1,
				"persistentValues": {},
				"fullScriptStates": {},
				"activeFullScriptId": "",
				"frames": [],
				"pendingOperation": {},
				"rngState": 1,
			}
		)
	return result


func restore_execution_snapshot(saved: Variant) -> Dictionary:
	if _classic_executor == null:
		return restore(saved)
	var result: Dictionary = classic_execution_state.restore_snapshot(saved)
	if str(result.get("status", "")) == "ok":
		pending_command = ScenarioPendingCommand.from_dictionary(
			saved.get("scenarioPendingCommand")
		) if saved.get("scenarioPendingCommand") is Dictionary else null
		var attachment_state: Dictionary = saved.get(
			"classicAttachmentState",
			{}
		)
		_classic_attachment_queue = attachment_state.get(
			"queue",
			[]
		).duplicate(true)
		_classic_deferred_instruction = attachment_state.get(
			"deferredInstruction",
			{}
		).duplicate(true)
		_classic_deferred_result = attachment_state.get(
			"deferredResult",
			{}
		).duplicate(true)
		_classic_executing_anchor = attachment_state.get(
			"executingAnchor",
			{}
		).duplicate(true)
		_classic_pending_after_anchor = attachment_state.get(
			"pendingAfterAnchor",
			{}
		).duplicate(true)
		if scenario_script_runtime != null:
			var script_restore := scenario_script_runtime.restore(
				saved.get("scenarioScriptRuntime", {})
			)
			if str(script_restore.get("status", "")) != "ok":
				return script_restore
	_sync_classic_observability()
	return result


func execute_scenario_script(
	script_id: String,
	arguments: Variant,
	invocation_context := {}
) -> ScenarioStepResult:
	if scenario_script_runtime == null:
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return scenario_script_runtime.invoke(script_id, arguments, invocation_context)


func execute_nested_scenario_script(
	script_id: String,
	arguments: Variant,
	invocation_context := {}
) -> ScenarioStepResult:
	if scenario_script_runtime == null:
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return scenario_script_runtime.invoke_nested(
		script_id,
		arguments,
		invocation_context
	)


func complete_nested_scenario_script() -> Dictionary:
	if scenario_script_runtime == null:
		return {
			"status": "error",
			"message": "Scenario script runtime is unavailable",
		}
	return scenario_script_runtime.complete_nested_invocation()


func resolve_scenario_behavior_arguments(
	bindings: Variant,
	invocation_context := {}
) -> Dictionary:
	if scenario_script_runtime == null:
		return {
			"status": "error",
			"message": "Scenario script runtime is unavailable",
		}
	return scenario_script_runtime.resolve_argument_bindings(
		bindings,
		invocation_context
	)


func matching_scenario_behavior_bindings(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	slot := -1
) -> Array:
	if scenario_script_runtime == null:
		return []
	return scenario_script_runtime.matching_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		slot
	)


func current_trigger_identity() -> Dictionary:
	if _classic_executor != null:
		var anchor := _classic_executing_anchor.duplicate(true)
		if anchor.is_empty():
			anchor = _classic_pending_after_anchor.duplicate(true)
		if anchor.is_empty():
			anchor = {
				"triggerId": str(_classic_executor.current_trigger.get("id", "")),
				"actionIndex": maxi(
					0,
					int(_classic_executor.current_action_index) - 1
				),
				"slot": -1,
			}
		return {
			"triggerId": str(anchor.get("triggerId", "")),
			"actionIndex": int(anchor.get("actionIndex", 0)),
			"slot": int(anchor.get("slot", -1)),
			"encounterOrigin": (
				_classic_executor.encounter_origins[-1].duplicate(true)
				if not _classic_executor.encounter_origins.is_empty()
				else {}
			),
			"executionContext": _classic_executor.execution_context.duplicate(true),
		}
	return {
		"triggerId": current_trigger_id,
		"actionIndex": current_action_index,
		"encounterOrigin": (
			encounter_origins[-1].duplicate(true)
			if not encounter_origins.is_empty()
			else {}
		),
		"executionContext": execution_context.duplicate(true),
	}


func resume_scenario_script(response: Dictionary) -> ScenarioStepResult:
	if scenario_script_runtime == null:
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return scenario_script_runtime.resume(response)


static func validate_execution_snapshot(saved: Variant) -> Dictionary:
	var classic_validation := ClassicExecutionStateScript.validate_snapshot(saved)
	if str(classic_validation.get("status", "")) != "ok":
		return classic_validation
	if not (saved is Dictionary) or not saved.has("scenarioScriptRuntime"):
		return {
			"status": "error",
			"message": "Scenario execution snapshot has no script runtime state",
		}
	var attachment_validation := _validate_classic_attachment_snapshot(
		saved.get("classicAttachmentState")
	)
	if not bool(attachment_validation.get("valid", false)):
		return {
			"status": "error",
			"message": attachment_validation.get(
				"message",
				"Scenario execution snapshot has invalid attachment state"
			),
		}
	var script_validation := ScenarioScriptRuntimeScript.validate_snapshot(
		saved["scenarioScriptRuntime"]
	)
	if not bool(script_validation.get("valid", false)):
		return {
			"status": "error",
			"message": script_validation.get(
				"message",
				"Scenario execution snapshot has invalid script runtime state"
			),
		}
	return {"status": "ok"}


func _take_next_classic_plan_instruction() -> Dictionary:
	if not _classic_attachment_queue.is_empty():
		var injected: Dictionary = _classic_attachment_queue.pop_front()
		var attachment: Dictionary = injected.get(
			"parameters",
			{}
		).get("attachment", {})
		var attachment_slot: Variant = attachment.get("slot")
		_classic_executor.trace.append({
			"event": "behavior-attachment",
			"triggerId": str(attachment.get("recordId", "")),
			"slot": int(attachment_slot) if attachment_slot != null else -1,
			"hook": str(attachment.get("hook", "")),
			"attachmentId": str(attachment.get("id", "")),
			"behaviorId": str(injected.get(
				"parameters",
				{}
			).get("behaviorId", "")),
		})
		return {
			"status": "instruction",
			"instruction": injected,
		}
	if not _classic_deferred_instruction.is_empty():
		var deferred := _classic_deferred_instruction.duplicate(true)
		_classic_deferred_instruction.clear()
		_classic_executing_anchor = deferred.get(
			"anchor",
			{}
		).duplicate(true)
		var trace_entry: Variant = deferred.get("traceEntry")
		if trace_entry is Dictionary:
			_classic_executor.trace.append(trace_entry.duplicate(true))
		return {
			"status": "instruction",
			"instruction": deferred.get("instruction", {}).duplicate(true),
		}
	if not _classic_deferred_result.is_empty():
		var deferred_result := _classic_deferred_result.duplicate(true)
		_classic_deferred_result.clear()
		return deferred_result
	var ending_anchor := {
		"triggerId": str(_classic_executor.current_trigger.get("id", "")),
		"slot": null,
		"callDepth": _classic_executor.call_stack.size(),
	}
	var prepared: Dictionary = _classic_executor.take_next_instruction()
	if str(prepared.get("status", "")) != "instruction":
		if str(prepared.get("status", "")) == "completed" \
				and not str(ending_anchor.get("triggerId", "")).is_empty():
			_queue_classic_record_transition_attachments(ending_anchor)
			if not _classic_attachment_queue.is_empty():
				_classic_deferred_result = prepared.duplicate(true)
				return _take_next_classic_plan_instruction()
		return prepared
	var instruction_value: Variant = prepared.get("instruction")
	if not (instruction_value is Dictionary):
		return prepared
	var instruction: Dictionary = instruction_value
	var anchor := _classic_instruction_anchor(instruction)
	var before := _classic_attachment_instructions("before-slot", anchor)
	if not before.is_empty():
		var trace_entry: Dictionary = {}
		if not _classic_executor.trace.is_empty() \
				and _classic_executor.trace[-1] is Dictionary:
			trace_entry = _classic_executor.trace.pop_back()
		_classic_deferred_instruction = {
			"instruction": instruction.duplicate(true),
			"anchor": anchor,
			"traceEntry": trace_entry,
		}
		_classic_attachment_queue.append_array(before)
		return _take_next_classic_plan_instruction()
	_classic_executing_anchor = anchor
	return prepared


func _classic_instruction_anchor(instruction: Dictionary) -> Dictionary:
	return {
		"triggerId": str(_classic_executor.current_trigger.get("id", "")),
		"actionIndex": maxi(
			0,
			int(_classic_executor.current_action_index) - 1
		),
		"slot": int(instruction.get("slot", -1)),
		"callDepth": _classic_executor.call_stack.size(),
	}


func _queue_classic_attachments(hook: String, anchor: Dictionary) -> void:
	if anchor.is_empty():
		return
	_classic_attachment_queue.append_array(
		_classic_attachment_instructions(hook, anchor)
	)


func _queue_classic_record_transition_attachments(
	anchor: Dictionary
) -> void:
	if anchor.is_empty() or _classic_executor == null:
		return
	var previous_trigger_id := str(anchor.get("triggerId", ""))
	var current_trigger_id_value := str(
		_classic_executor.current_trigger.get("id", "")
	)
	var previous_depth := int(anchor.get(
		"callDepth",
		_classic_executor.call_stack.size()
	))
	var current_depth: int = int(_classic_executor.call_stack.size())
	if previous_trigger_id == current_trigger_id_value \
			and previous_depth == current_depth:
		return
	if current_depth > previous_depth:
		if not current_trigger_id_value.is_empty():
			_queue_classic_attachments(
				"before-ap",
				{
					"triggerId": current_trigger_id_value,
					"slot": null,
					"callDepth": current_depth,
				}
			)
		return
	if not previous_trigger_id.is_empty():
		_queue_classic_attachments(
			"after-ap",
			{
				"triggerId": previous_trigger_id,
				"slot": null,
				"callDepth": previous_depth,
			}
		)
	if current_depth == previous_depth \
			and not current_trigger_id_value.is_empty():
		_queue_classic_attachments(
			"before-ap",
			{
				"triggerId": current_trigger_id_value,
				"slot": null,
				"callDepth": current_depth,
			}
		)


func _activate_pending_after_attachments() -> void:
	if _classic_pending_after_anchor.is_empty():
		return
	_queue_classic_attachments(
		"after-slot",
		_classic_pending_after_anchor
	)
	_classic_pending_after_anchor.clear()


func _classic_attachment_instructions(
	hook: String,
	anchor: Dictionary
) -> Array:
	if scenario_script_runtime == null:
		return []
	var trigger_id := str(anchor.get("triggerId", ""))
	var slot_value: Variant = anchor.get("slot")
	var slot := int(slot_value) if slot_value != null else -1
	var is_record_hook := hook in ["before-ap", "after-ap"]
	if trigger_id.is_empty() or (not is_record_hook and slot < 0):
		return []
	var bindings := scenario_script_runtime.matching_bindings(
		"action",
		hook,
		"trigger",
		[trigger_id],
		-1 if is_record_hook else slot
	)
	var instructions: Array = []
	for binding_value: Variant in bindings:
		if not (binding_value is Dictionary):
			continue
		var binding: Dictionary = binding_value
		instructions.append({
			"kind": "semantic",
			"slot": slot,
			"operation": "core.script.call",
			"parameters": {
				"behaviorId": str(binding.get("behaviorId", "")),
				"argumentBindings": binding.get(
					"arguments",
					{}
				).duplicate(true),
				"attachment": {
					"id": str(binding.get("id", "")),
					"role": "action",
					"hook": hook,
					"targetKind": "trigger",
					"recordId": trigger_id,
					"slot": null if is_record_hook else slot,
					"priority": int(binding.get("priority", 0)),
				},
			},
		})
	return instructions


func _classic_semantic_action_identity(
	instruction: Dictionary,
	fallback: Dictionary
) -> Dictionary:
	var identity := fallback.duplicate(true)
	identity["kind"] = "semantic"
	identity["operation"] = str(instruction.get("operation", ""))
	identity.erase("rawCode")
	identity.erase("code")
	identity.erase("id")
	var attachment: Variant = instruction.get(
		"parameters",
		{}
	).get("attachment")
	if attachment is Dictionary:
		identity["triggerId"] = str(attachment.get(
			"recordId",
			identity.get("triggerId", "")
		))
		var attachment_slot: Variant = attachment.get("slot")
		identity["slot"] = (
			int(attachment_slot)
			if attachment_slot != null
			else -1
		)
		identity["attachmentId"] = str(attachment.get("id", ""))
		identity["anchorHook"] = str(attachment.get("hook", ""))
	return identity


func _reset_classic_attachment_plan() -> void:
	_classic_attachment_queue.clear()
	_classic_deferred_instruction.clear()
	_classic_deferred_result.clear()
	_classic_executing_anchor.clear()
	_classic_pending_after_anchor.clear()


static func _validate_classic_attachment_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {
			"valid": false,
			"message": "Scenario execution snapshot has no Classic attachment state",
		}
	for field_name: String in [
		"deferredInstruction",
		"deferredResult",
		"executingAnchor",
		"pendingAfterAnchor",
	]:
		if not (value.get(field_name) is Dictionary):
			return {
				"valid": false,
				"message": "Classic attachment snapshot has invalid %s"
					% field_name,
			}
	if not (value.get("queue") is Array):
		return {
			"valid": false,
			"message": "Classic attachment snapshot has an invalid queue",
		}
	return {"valid": true}


func _classic_result(value: Variant) -> Dictionary:
	_sync_classic_observability()
	if value is Dictionary:
		if str(value.get("status", "")) == "yield":
			_capture_classic_pending(value)
		elif str(value.get("status", "")) != "error":
			pending_command = null
		return value
	return {
		"status": "error",
		"message": "Classic opcode compatibility executor returned an invalid result",
	}


func _capture_classic_pending(result: Dictionary) -> void:
	var command_id := str(result.get("command", ""))
	var action_identity: Dictionary = result.get(
		"_scenarioActionIdentity",
		_classic_action_identity()
	)
	var handler_id := str(result.get("_scenarioHandlerId", "core.control-flow"))
	if instruction_registry != null and action_identity.has("code"):
		var handler := instruction_registry.resolve({
			"kind": "classic",
			"code": int(action_identity["code"]),
		})
		if handler != null:
			handler_id = handler.handler_id()
	var continuation: Dictionary = result.get("payload", {}).duplicate(true)
	var stored_continuation: Variant = result.get("_scenarioContinuation")
	if stored_continuation is Dictionary \
			and stored_continuation.get("data") is Dictionary \
			and stored_continuation.get("continuationId") is String:
		continuation.merge(stored_continuation["data"], true)
		continuation["_continuationId"] = str(
			stored_continuation["continuationId"]
		)
	pending_command = ScenarioPendingCommand.new(
		handler_id,
		command_id,
		action_identity,
		continuation
	)


func _execute_classic_semantic_action(action: Dictionary) -> Dictionary:
	if instruction_registry == null:
		return _classic_error("Scenario instruction registry is unavailable")
	var handler := instruction_registry.resolve(action)
	if handler == null:
		return _classic_error(
			"No scenario handler owns semantic operation '%s'" % action.get("operation", "")
		)
	var step_result := handler.execute(action, self)
	return _classic_semantic_step(
		step_result,
		handler.handler_id(),
		{
			"triggerId": str(_classic_executor.current_trigger.get("id", "")),
			"actionIndex": max(0, int(_classic_executor.current_action_index) - 1),
			"slot": int(action.get("slot", -1)),
			"kind": "semantic",
			"operation": str(action.get("operation", "")),
		}
	)


func _classic_semantic_step(
	step_result: ScenarioStepResult,
	handler_id: String,
	action_identity: Dictionary
) -> Dictionary:
	if step_result == null or not step_result.is_valid():
		return _classic_error(
			"Semantic scenario handler '%s' returned an invalid result" % handler_id
		)
	match step_result.kind:
		ScenarioStepResult.CONTINUE:
			return {"status": "continue"}
		ScenarioStepResult.YIELD:
			return {
				"status": "yield",
				"command": str(step_result.data.get("commandId", "")),
				"payload": step_result.data.get("request", {}).duplicate(true),
				"_scenarioHandlerId": handler_id,
				"_scenarioActionIdentity": action_identity.duplicate(true),
				"_scenarioContinuation": step_result.data.get(
					"continuation",
					{}
				).duplicate(true),
			}
		ScenarioStepResult.HALT:
			return {
				"status": "completed",
				"reason": "semantic-halt",
				"result": step_result.data.duplicate(true),
			}
		ScenarioStepResult.ERROR:
			return _classic_error(str(step_result.data.get(
				"message",
				"Semantic scenario handler failed"
			)))
	return _classic_error(
		"Semantic scenario handler '%s' returned unsupported control result '%s'" % [
			handler_id,
			step_result.kind,
		]
	)


func _classic_action_identity(instruction := {}) -> Dictionary:
	if _classic_executor == null:
		return {}
	var anchor := _classic_executing_anchor.duplicate(true)
	if anchor.is_empty():
		anchor = _classic_pending_after_anchor.duplicate(true)
	var executor_trace: Array = _classic_executor.trace
	var latest: Dictionary = (
		executor_trace[-1] if not executor_trace.is_empty() else {}
	)
	return {
		"triggerId": str(anchor.get(
			"triggerId",
			latest.get("triggerId", "")
		)),
		"actionIndex": int(anchor.get(
			"actionIndex",
			max(0, int(_classic_executor.current_action_index) - 1)
		)),
		"slot": int(anchor.get(
			"slot",
			instruction.get("slot", latest.get("slot", -1))
		)),
		"kind": "classic",
		"code": int(instruction.get("code", latest.get("code", 0))),
	}


func _classic_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}


func _classic_pending(property_name: String) -> Dictionary:
	if _classic_executor == null:
		return {}
	var value: Variant = _classic_executor.get(property_name)
	return value if value is Dictionary else {}


func _sync_classic_observability() -> void:
	if _classic_executor == null:
		return
	call_stack = _classic_executor.call_stack.duplicate(true)
	encounter_origins = _classic_executor.encounter_origins.duplicate(true)
	trace = _classic_executor.trace.duplicate(true)


func reset() -> void:
	current_trigger_id = ""
	current_action_index = 0
	call_stack.clear()
	encounter_origins.clear()
	pending_command = null
	execution_context.clear()
	trace.clear()
	halted = true
	last_result = {}
	_reset_classic_attachment_plan()


func start(trigger_id: String, action_index := 0, context := {}) -> Dictionary:
	if instruction_registry == null:
		return _error("Scenario interpreter has no instruction registry")
	if not triggers.has(trigger_id):
		return _error("Scenario trigger '%s' is unavailable" % trigger_id)
	if action_index < 0:
		return _error("Scenario action index cannot be negative")
	current_trigger_id = trigger_id
	current_action_index = action_index
	call_stack.clear()
	encounter_origins.clear()
	pending_command = null
	execution_context = context.duplicate(true) if context is Dictionary else {}
	trace.clear()
	halted = false
	return {"status": "ok"}


func run(context: Object) -> Dictionary:
	if halted:
		return last_result if not last_result.is_empty() else _error("Scenario interpreter is stopped")
	if pending_command != null:
		return _error("Scenario interpreter is waiting for command '%s'" % pending_command.command_id)
	for _step: int in range(MAX_INTERNAL_STEPS):
		var trigger: Dictionary = triggers.get(current_trigger_id, {})
		var actions: Variant = trigger.get("actions", [])
		if not (actions is Array):
			return _error("Scenario trigger '%s' has invalid actions" % current_trigger_id)
		if current_action_index >= actions.size():
			if call_stack.is_empty():
				return _complete("fallthrough")
			_restore_call_frame()
			continue
		var instruction_value: Variant = actions[current_action_index]
		if not (instruction_value is Dictionary):
			return _error("Scenario instruction at %s[%d] is invalid" % [
				current_trigger_id,
				current_action_index,
			])
		var instruction := _normalized_instruction(instruction_value)
		var handler := instruction_registry.resolve(instruction)
		if handler == null:
			return _error(_unhandled_message(instruction))
		var action_identity := _action_identity(instruction)
		trace.append({
			"event": "execute",
			"handlerId": handler.handler_id(),
			"action": action_identity,
		})
		var step_result := handler.execute(instruction, context)
		if step_result == null or not step_result.is_valid():
			return _error("Scenario handler '%s' returned an invalid result" % handler.handler_id())
		var applied := _apply_step_result(step_result, handler.handler_id(), action_identity)
		if str(applied.get("status", "")) != "continue":
			return applied
	return _error("Scenario interpreter exceeded %d internal steps" % MAX_INTERNAL_STEPS)


func resume(response: Dictionary, context: Object) -> Dictionary:
	if pending_command == null:
		return _error("No scenario command is waiting for a response")
	var handler := instruction_registry.handler_by_id(pending_command.handler_id)
	if handler == null:
		return _error("Pending scenario handler '%s' is unavailable" % pending_command.handler_id)
	var saved_pending := pending_command
	pending_command = null
	trace.append({
		"event": "resume",
		"handlerId": saved_pending.handler_id,
		"commandId": saved_pending.command_id,
		"action": saved_pending.action_identity.duplicate(true),
	})
	var step_result := handler.resume(saved_pending, response, context)
	if step_result == null or not step_result.is_valid():
		return _error("Scenario handler '%s' returned an invalid resume result" % handler.handler_id())
	var applied := _apply_step_result(
		step_result,
		handler.handler_id(),
		saved_pending.action_identity
	)
	if str(applied.get("status", "")) != "continue":
		return applied
	return run(context)


func snapshot() -> Dictionary:
	var pending_value: Variant = null
	if pending_command != null:
		pending_value = pending_command.to_dictionary()
	return {
		"schemaVersion": SNAPSHOT_SCHEMA_VERSION,
		"currentTriggerId": current_trigger_id,
		"currentActionIndex": current_action_index,
		"callStack": call_stack.duplicate(true),
		"encounterOrigins": encounter_origins.duplicate(true),
		"pendingCommand": pending_value,
		"executionContext": execution_context.duplicate(true),
		"trace": trace.duplicate(true),
		"halted": halted,
		"lastResult": last_result.duplicate(true),
	}


func restore(value: Variant) -> Dictionary:
	var validation := validate_snapshot(value)
	if not bool(validation.get("valid", false)):
		return {"status": "error", "message": validation.get("message", "Invalid VM snapshot")}
	var saved: Dictionary = value
	if not triggers.has(str(saved["currentTriggerId"])):
		return _error("Saved scenario trigger '%s' is unavailable" % saved["currentTriggerId"])
	current_trigger_id = saved["currentTriggerId"]
	current_action_index = int(saved["currentActionIndex"])
	call_stack = saved["callStack"].duplicate(true)
	encounter_origins = saved["encounterOrigins"].duplicate(true)
	pending_command = ScenarioPendingCommand.from_dictionary(saved["pendingCommand"]) \
		if saved["pendingCommand"] != null else null
	execution_context = saved["executionContext"].duplicate(true)
	trace = saved["trace"].duplicate(true)
	halted = bool(saved["halted"])
	last_result = saved["lastResult"].duplicate(true)
	return {"status": "ok"}


static func validate_snapshot(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _invalid("Scenario VM snapshot must be a dictionary")
	var saved: Dictionary = value
	if int(saved.get("schemaVersion", 0)) != SNAPSHOT_SCHEMA_VERSION:
		return _invalid(
			"Scenario VM snapshot is from an unsupported runtime; start a new playthrough"
		)
	if not (saved.get("currentTriggerId") is String):
		return _invalid("Scenario VM snapshot has an invalid trigger identity")
	if int(saved.get("currentActionIndex", -1)) < 0:
		return _invalid("Scenario VM snapshot has an invalid instruction position")
	for field_name: String in ["callStack", "encounterOrigins", "trace"]:
		if not (saved.get(field_name) is Array):
			return _invalid("Scenario VM snapshot has invalid %s" % field_name)
	if saved["callStack"].size() > MAX_CALL_STACK_DEPTH:
		return _invalid("Scenario VM snapshot exceeds the call-stack limit")
	for field_name: String in ["executionContext", "lastResult"]:
		if not (saved.get(field_name) is Dictionary):
			return _invalid("Scenario VM snapshot has invalid %s" % field_name)
	if not (saved.get("halted") is bool):
		return _invalid("Scenario VM snapshot has invalid halted state")
	if saved.get("pendingCommand") != null:
		var pending_validation := ScenarioPendingCommand.validate(saved["pendingCommand"])
		if not bool(pending_validation.get("valid", false)):
			return pending_validation
	return {"valid": true}


func _apply_step_result(
	result: ScenarioStepResult,
	handler_id: String,
	action_identity: Dictionary
) -> Dictionary:
	match result.kind:
		ScenarioStepResult.CONTINUE:
			current_action_index += 1
			return {"status": "continue"}
		ScenarioStepResult.YIELD:
			var command_id := str(result.data.get("commandId", ""))
			if command_id.is_empty():
				return _error("Scenario handler '%s' yielded an empty command ID" % handler_id)
			pending_command = ScenarioPendingCommand.new(
				handler_id,
				command_id,
				action_identity,
				result.data.get("continuation", {})
			)
			current_action_index += 1
			last_result = {
				"status": "yield",
				"commandId": command_id,
				"request": result.data.get("request", {}).duplicate(true),
				"pending": pending_command.to_dictionary(),
			}
			return last_result
		ScenarioStepResult.BRANCH:
			current_action_index = int(result.data.get("actionIndex", current_action_index + 1))
			return {"status": "continue"}
		ScenarioStepResult.CALL:
			if call_stack.size() >= MAX_CALL_STACK_DEPTH:
				return _error("Scenario call stack exceeded %d frames" % MAX_CALL_STACK_DEPTH)
			call_stack.append({
				"triggerId": current_trigger_id,
				"actionIndex": current_action_index + 1,
			})
			var call_result := _activate_target(result)
			return {"status": "continue"} if call_result.is_empty() else call_result
		ScenarioStepResult.RETURN:
			if call_stack.is_empty():
				return _complete("return-with-empty-stack")
			_restore_call_frame()
			return {"status": "continue"}
		ScenarioStepResult.REPLACE:
			var replace_result := _activate_target(result)
			return {"status": "continue"} if replace_result.is_empty() else replace_result
		ScenarioStepResult.HALT:
			halted = true
			last_result = {"status": "halt", "result": result.data.duplicate(true)}
			return last_result
		ScenarioStepResult.ERROR:
			return _error(str(result.data.get("message", "Scenario handler failed")))
	return _error("Unknown scenario step result '%s'" % result.kind)


func _activate_target(result: ScenarioStepResult) -> Dictionary:
	var trigger_id := str(result.data.get("triggerId", ""))
	if not triggers.has(trigger_id):
		return _error("Scenario target trigger '%s' is unavailable" % trigger_id)
	current_trigger_id = trigger_id
	current_action_index = int(result.data.get("actionIndex", 0))
	return {}


func _restore_call_frame() -> void:
	var frame: Dictionary = call_stack.pop_back()
	current_trigger_id = str(frame["triggerId"])
	current_action_index = int(frame["actionIndex"])


func _normalized_instruction(value: Dictionary) -> Dictionary:
	var instruction := value.duplicate(true)
	var kind := str(instruction.get("kind", "classic"))
	if kind.is_empty():
		kind = "classic"
	instruction["kind"] = kind
	if kind == "classic":
		var raw_code := int(instruction.get("rawCode", instruction.get("code", 0)))
		instruction["code"] = (
			abs(raw_code) if raw_code < 0 and raw_code not in [-14, -23] else raw_code
		)
		instruction["gosub"] = raw_code < 0 and raw_code not in [-14, -23]
	return instruction


func _action_identity(instruction: Dictionary) -> Dictionary:
	var identity := {
		"triggerId": current_trigger_id,
		"actionIndex": current_action_index,
		"slot": int(instruction.get("slot", current_action_index)),
		"kind": str(instruction.get("kind", "")),
	}
	if identity["kind"] == "classic":
		identity["rawCode"] = int(instruction.get("rawCode", 0))
		identity["code"] = int(instruction.get("code", 0))
		identity["id"] = int(instruction.get("id", 0))
	else:
		identity["operation"] = str(instruction.get("operation", ""))
	return identity


func _unhandled_message(instruction: Dictionary) -> String:
	if str(instruction.get("kind", "")) == "classic":
		return "No scenario handler owns Classic opcode %d" % int(instruction.get("code", -1))
	return "No scenario handler owns semantic operation '%s'" % instruction.get("operation", "")


func _complete(reason: String) -> Dictionary:
	halted = true
	last_result = {"status": "complete", "reason": reason}
	return last_result


func _error(message: String) -> Dictionary:
	halted = true
	last_result = {"status": "error", "message": message}
	return last_result


static func _invalid(message: String) -> Dictionary:
	return {"valid": false, "message": message}
