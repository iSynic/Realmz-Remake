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
const SNAPSHOT_SCHEMA_VERSION := 4
const MAX_INTERNAL_STEPS := 256
const MAX_CALL_STACK_DEPTH := 20
const MAX_RESULT_TRANSITIONS := MAX_INTERNAL_STEPS

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
var _classic_encounter_phase: Dictionary = {}
var _result_transition_count := 0
var _semantic_active_response_ref: Variant = null
var _semantic_active_result_ref: Variant = null

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
	var script_result := configure_scenario_scripts(
		campaign_bundle.documents.get("remakeScripts", {}),
		state,
		campaign_bundle
	)
	if str(script_result.get("status", "")) != "ok":
		last_result = script_result
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
			var attachment_result := _apply_classic_attachment_outcome(
				action_identity,
				semantic_result.get("value")
			)
			if str(attachment_result.get("status", "")) == "error":
				return attachment_result
			if str(attachment_result.get("status", "")) == "redirect":
				var redirect_result := _redirect_executing_classic_result()
				if str(redirect_result.get("status", "")) == "continue":
					continue
				return redirect_result
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
	if saved_pending.command_id == "start_encounter" \
			and str(_classic_encounter_phase.get("stage", "")) == "presenting":
		return _classic_result(
			_resume_classic_encounter_presentation(saved_pending, response)
		)
	var handler := instruction_registry.handler_by_id(saved_pending.handler_id)
	if handler == null:
		return _classic_error(
			"Pending scenario handler '%s' is unavailable" % saved_pending.handler_id
		)
	if str(saved_pending.action_identity.get("kind", "")) == "semantic":
		var step := handler.resume(saved_pending, response, self)
		var semantic_result := _classic_semantic_step(
			step,
			saved_pending.handler_id,
			saved_pending.action_identity
		)
		var attachment_result := _apply_classic_attachment_outcome(
			saved_pending.action_identity,
			semantic_result.get("value")
		)
		if str(attachment_result.get("status", "")) == "error":
			return _classic_result(attachment_result)
		if str(attachment_result.get("status", "")) == "redirect":
			var redirect_result := _redirect_executing_classic_result()
			if str(redirect_result.get("status", "")) == "continue":
				return _classic_result(_run_classic_loop())
			return _classic_result(redirect_result)
		if str(semantic_result.get("status", "")) == "continue":
			return _classic_result(_run_classic_loop())
		return _classic_result(semantic_result)
	return _classic_result(
		_resume_classic_pending_step(saved_pending, response, handler)
	)


func _resume_classic_pending_step(
	saved_pending: ScenarioPendingCommand,
	response: Dictionary,
	handler: ScenarioInstructionHandler = null
) -> Dictionary:
	if handler == null:
		handler = instruction_registry.handler_by_id(saved_pending.handler_id)
	if handler == null:
		return _classic_error(
			"Pending scenario handler '%s' is unavailable" % saved_pending.handler_id
		)
	var step := handler.resume(saved_pending, response, self)
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
		return _run_classic_loop()
	if str(classic_result.get("status", "")) == "completed" \
			and not _classic_pending_after_anchor.is_empty():
		_activate_pending_after_attachments()
		_queue_classic_record_transition_attachments(pending_anchor)
		if not _classic_attachment_queue.is_empty():
			_classic_deferred_result = classic_result.duplicate(true)
			return _run_classic_loop()
	if str(classic_result.get("status", "")) == "yield":
		# A resumed Classic command can re-enter the VM and yield a later
		# instruction. Its anchor is now the active continuation and must not be
		# cleared by the outer resume frame.
		return classic_result
	_classic_pending_after_anchor.clear()
	return classic_result


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
		var pending_command_snapshot: Variant = null
		if pending_command != null:
			pending_command_snapshot = pending_command.to_dictionary()
		result["snapshot"]["scenarioPendingCommand"] = pending_command_snapshot
		result["snapshot"]["classicAttachmentState"] = {
			"queue": _classic_attachment_queue.duplicate(true),
			"deferredInstruction": _classic_deferred_instruction.duplicate(true),
			"deferredResult": _classic_deferred_result.duplicate(true),
			"executingAnchor": _classic_executing_anchor.duplicate(true),
			"pendingAfterAnchor": _classic_pending_after_anchor.duplicate(true),
			"encounterPhase": _classic_encounter_phase.duplicate(true),
			"resultTransitionCount": _result_transition_count,
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
		_classic_encounter_phase = attachment_state.get(
			"encounterPhase",
			{}
		).duplicate(true)
		_result_transition_count = int(attachment_state.get(
			"resultTransitionCount",
			0
		))
		if scenario_script_runtime != null:
			var script_restore := scenario_script_runtime.restore(
				saved.get("scenarioScriptRuntime", {})
			)
			if str(script_restore.get("status", "")) != "ok":
				return script_restore
	_sync_classic_observability()
	return result


func configure_scenario_scripts(
	script_document_value: Variant,
	state: Object,
	campaign_bundle: Object
) -> Dictionary:
	var script_document: Dictionary = (
		script_document_value if script_document_value is Dictionary else {}
	)
	if script_document.is_empty():
		script_document = ScenarioScriptRuntimeScript.empty_document()
	scenario_script_runtime = ScenarioScriptRuntimeScript.new()
	if not scenario_script_runtime.configure(
		script_document,
		state,
		campaign_bundle
	):
		return {
			"status": "error",
			"message": scenario_script_runtime.last_error,
		}
	return {"status": "ok"}


func execute_scenario_script(
	script_id: String,
	arguments: Variant,
	invocation_context := {}
) -> ScenarioStepResult:
	if scenario_script_runtime == null:
		return ScenarioStepResult.failed("Scenario script runtime is unavailable")
	return scenario_script_runtime.invoke(script_id, arguments, invocation_context)


func record_semantic_encounter_completion(encounter: Dictionary) -> void:
	if scenario_script_runtime == null:
		return
	var state := scenario_script_runtime.runtime_state
	if state != null and state.has_method("mark_encounter_completed"):
		state.call("mark_encounter_completed", encounter)


func record_semantic_response_reference(response_reference: Dictionary) -> void:
	_semantic_active_response_ref = response_reference.duplicate(true)
	_semantic_active_result_ref = null


func record_semantic_result_reference(result_reference: Dictionary) -> bool:
	_semantic_active_result_ref = result_reference.duplicate(true)
	_result_transition_count += 1
	return _result_transition_count <= MAX_RESULT_TRANSITIONS


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
	anchor := {"kind": "domain"}
) -> Array:
	if scenario_script_runtime == null:
		return []
	return scenario_script_runtime.matching_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		anchor
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
	if not _classic_encounter_phase.is_empty() \
			and pending_command == null \
			and str(_classic_encounter_phase.get("stage", "")) \
				!= "executing-classic-result":
		var encounter_phase_result := _advance_classic_encounter_phase()
		if str(encounter_phase_result.get("status", "")) == "continue":
			return _take_next_classic_plan_instruction()
		return encounter_phase_result
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
		"encounterOrigins": _classic_executor.encounter_origins.duplicate(true),
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
		"encounterOrigins": _classic_executor.encounter_origins.duplicate(true),
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
	_queue_classic_encounter_completion_attachments(anchor)
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


func _queue_classic_encounter_completion_attachments(
	anchor: Dictionary
) -> void:
	var previous_origins: Variant = anchor.get("encounterOrigins", [])
	if not (previous_origins is Array):
		return
	var current_origins: Array = _classic_executor.encounter_origins
	if previous_origins.size() <= current_origins.size():
		return
	for index: int in range(
		previous_origins.size() - 1,
		current_origins.size() - 1,
		-1
	):
		var origin_value: Variant = previous_origins[index]
		if not (origin_value is Dictionary):
			continue
		var origin: Dictionary = origin_value
		var outcome := int(origin.get("selectedOutcome", 0))
		var encounter_kind := str(origin.get("encounterKind", ""))
		var encounter_id := str(origin.get("encounterId", ""))
		var target_kind := (
			"complexEncounter"
			if encounter_kind == "complex"
			else "simpleEncounter"
		)
		var completion_request := {
			"encounterKind": encounter_kind,
			"encounterId": int(origin.get("encounterId", -1)),
			"outcome": outcome,
			"resultSlot": outcome - 1,
			"optionSlot": int(origin.get("selectedOptionSlot", -1)),
		}
		if outcome > 0:
			_classic_attachment_queue.append_array(
				_behavior_attachment_instructions(
					"encounter",
					"result",
					target_kind,
					[encounter_id],
					{
						"kind": "encounter-result",
						"result": {"kind": "classic", "index": outcome - 1},
						"phase": "body-complete",
					},
					completion_request
				)
			)
		if str(_classic_encounter_phase.get("stage", "")) \
				== "executing-classic-result" \
				and str(_classic_encounter_phase.get("encounterKind", "")) \
					== encounter_kind \
				and int(_classic_encounter_phase.get("encounterId", -1)) \
					== int(origin.get("encounterId", -1)):
			_classic_encounter_phase["stage"] = "completion"
		_classic_attachment_queue.append_array(
			_behavior_attachment_instructions(
				"encounter",
				"complete",
				target_kind,
				[encounter_id],
				{"kind": "record", "phase": "complete"},
				completion_request
			)
		)


func _begin_classic_encounter_phase(yield_result: Dictionary) -> Dictionary:
	if pending_command == null:
		return _classic_error(
			"Classic encounter presentation has no pending continuation"
		)
	var request: Dictionary = yield_result.get(
		"payload",
		{}
	).duplicate(true)
	var encounter_kind := str(request.get("encounterKind", ""))
	var encounter_id := str(request.get("encounterId", ""))
	if encounter_kind not in ["simple", "complex"] or encounter_id.is_empty():
		return _classic_error(
			"Classic encounter presentation has an invalid identity"
		)
	_classic_encounter_phase = {
		"stage": "entry",
		"pendingCommand": pending_command.to_dictionary(),
		"yieldResult": yield_result.duplicate(true),
		"request": request,
		"response": {},
		"availabilityResults": {},
		"encounterKind": encounter_kind,
		"encounterId": encounter_id,
		"targetKind": (
			"complexEncounter"
			if encounter_kind == "complex"
			else "simpleEncounter"
		),
	}
	pending_command = null
	_queue_classic_encounter_phase_attachments("enter", -1)
	_queue_classic_encounter_availability_attachments()
	return _classic_result(_run_classic_loop())


func _resume_classic_encounter_presentation(
	saved_pending: ScenarioPendingCommand,
	response: Dictionary
) -> Dictionary:
	var stored_pending := ScenarioPendingCommand.from_dictionary(
		_classic_encounter_phase.get("pendingCommand")
	)
	if stored_pending == null \
			or stored_pending.command_id != saved_pending.command_id \
			or stored_pending.handler_id != saved_pending.handler_id \
			or stored_pending.action_identity != saved_pending.action_identity:
		return _classic_error(
			"Classic encounter continuation identity changed during presentation"
		)
	if not response.has("outcome"):
		return _classic_error("Encounter response is missing 'outcome'")
	_classic_encounter_phase["response"] = response.duplicate(true)
	var option_slot := int(response.get("optionSlot", -1))
	var response_ref := _classic_response_reference(response)
	if option_slot >= 0 or not response_ref.is_empty():
		_classic_encounter_phase["stage"] = "option"
		_queue_classic_encounter_phase_attachments(
			"option",
			option_slot
		)
	else:
		_prepare_classic_encounter_result_phase()
	return _run_classic_loop()


func _advance_classic_encounter_phase() -> Dictionary:
	for _iteration: int in range(8):
		match str(_classic_encounter_phase.get("stage", "")):
			"entry":
				var entry_response: Variant = _classic_encounter_phase.get(
					"response",
					{}
				)
				if entry_response is Dictionary \
						and entry_response.has("outcome"):
					_prepare_classic_encounter_result_phase()
				else:
					var availability_result := _apply_classic_availability_filter()
					if str(availability_result.get("status", "")) == "error":
						return availability_result
					var restored_pending := ScenarioPendingCommand.from_dictionary(
						_classic_encounter_phase.get("pendingCommand")
					)
					if restored_pending == null:
						return _classic_error(
							"Classic encounter entry lost its continuation"
						)
					pending_command = restored_pending
					_classic_encounter_phase["stage"] = "presenting"
					return _classic_encounter_phase.get(
						"yieldResult",
						{}
					).duplicate(true)
			"option":
				_prepare_classic_encounter_result_phase()
			"result":
				var result_response: Dictionary = _classic_encounter_phase.get(
					"response",
					{}
				).duplicate(true)
				var result_behavior: Variant = result_response.get(
					"behaviorOutcome",
					{}
				)
				if result_behavior is Dictionary:
					match str(result_behavior.get("kind", "continue")):
						"repeat":
							result_response["enhancedTerminal"] = {"kind": "repeat"}
						"close":
							result_response["enhancedTerminal"] = {"kind": "continue"}
					result_response.erase("behaviorOutcome")
					_classic_encounter_phase["response"] = result_response
				if result_response.has("enhancedTerminal"):
					_classic_encounter_phase["stage"] = "enhanced-terminal"
				else:
					_classic_encounter_phase["stage"] = "resume"
			"enhanced-result":
				_classic_encounter_phase["stage"] = "enhanced-terminal"
			"enhanced-terminal":
				var terminal_result := _finish_classic_enhanced_result()
				if str(terminal_result.get("status", "")) == "continue":
					continue
				return terminal_result
			"resume":
				var resume_pending := ScenarioPendingCommand.from_dictionary(
					_classic_encounter_phase.get("pendingCommand")
				)
				if resume_pending == null:
					return _classic_error(
						"Classic encounter result lost its continuation"
					)
				var resume_response: Dictionary = _classic_encounter_phase.get(
					"response",
					{}
				).duplicate(true)
				if int(resume_response.get("outcome", 0)) > 0:
					_classic_encounter_phase["stage"] = "executing-classic-result"
				else:
					_classic_encounter_phase.clear()
				return _resume_classic_pending_step(
					resume_pending,
					resume_response
				)
			"completion":
				_classic_encounter_phase.clear()
				return {"status": "continue"}
			"presenting":
				return _classic_error(
					"Classic encounter presentation resumed without a response"
				)
			"invalid-enhanced-result":
				return _classic_error(
					"Classic encounter response references a missing Enhanced Result"
				)
			_:
				return _classic_error(
					"Classic encounter phase is invalid"
				)
		if not _classic_attachment_queue.is_empty():
			return {"status": "continue"}
	return _classic_error(
		"Classic encounter phase exceeded its transition limit"
	)


func _prepare_classic_encounter_result_phase() -> void:
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	if not response.has("behaviorOutcome"):
		var routed_result := _classic_overlay_result_for_response(
			_classic_response_reference(response)
		)
		if not routed_result.is_empty():
			if str(routed_result.get("kind", "")) == "classic":
				response["outcome"] = int(routed_result.get("index", -1)) + 1
			elif str(routed_result.get("kind", "")) == "enhanced":
				response["enhancedResultId"] = str(routed_result.get("id", ""))
	var behavior_outcome: Variant = response.get("behaviorOutcome", {})
	if behavior_outcome is Dictionary:
		match str(behavior_outcome.get("kind", "continue")):
			"repeat":
				response["enhancedTerminal"] = {"kind": "repeat"}
			"close":
				response["enhancedTerminal"] = {"kind": "continue"}
	_classic_encounter_phase["response"] = response
	if response.has("enhancedTerminal"):
		_classic_encounter_phase["stage"] = "enhanced-terminal"
		return
	var enhanced_result_id := str(response.get("enhancedResultId", ""))
	if not enhanced_result_id.is_empty():
		var enhanced_result := _classic_enhanced_result(enhanced_result_id)
		if enhanced_result.is_empty():
			_classic_encounter_phase["stage"] = "invalid-enhanced-result"
			return
		_classic_encounter_phase["enhancedResult"] = enhanced_result
		_classic_encounter_phase["stage"] = "enhanced-result"
		_queue_classic_enhanced_result_attachments(enhanced_result_id)
		return
	var outcome := int(response.get("outcome", 0))
	if outcome > 0:
		_classic_encounter_phase["stage"] = "result"
		_queue_classic_encounter_phase_attachments(
			"result",
			absi(outcome) - 1
		)
	else:
		_classic_encounter_phase["stage"] = "resume"


func _classic_overlay_result_for_response(response_ref: Dictionary) -> Dictionary:
	if response_ref.is_empty():
		return {}
	if not _classic_response_is_available(response_ref):
		return {}
	var overlay := _classic_encounter_overlay()
	for route_value: Variant in overlay.get("responseRoutes", []):
		if not (route_value is Dictionary):
			continue
		var route: Dictionary = route_value
		var candidate: Variant = route.get("response", {})
		if candidate is Dictionary \
				and _classic_response_key(candidate) == _classic_response_key(response_ref):
			var result: Variant = route.get("result", {})
			return result.duplicate(true) if result is Dictionary else {}
	return {}


func _classic_encounter_overlay() -> Dictionary:
	if scenario_script_runtime == null or scenario_script_runtime.bundle == null:
		return {}
	var logic: Variant = scenario_script_runtime.bundle.documents.get(
		"remakeLogic",
		{}
	)
	if not (logic is Dictionary):
		return {}
	var encounter_kind := str(_classic_encounter_phase.get("encounterKind", ""))
	var encounter_id := int(_classic_encounter_phase.get("encounterId", -1))
	for overlay_value: Variant in logic.get("encounterOverlays", []):
		if not (overlay_value is Dictionary):
			continue
		var overlay: Dictionary = overlay_value
		if str(overlay.get("encounterKind", "")) == encounter_kind \
				and int(overlay.get("encounterId", -1)) == encounter_id:
			return overlay.duplicate(true)
	return {}


func _classic_enhanced_result(result_id: String) -> Dictionary:
	for result_value: Variant in _classic_encounter_overlay().get(
		"namedResults",
		[]
	):
		if result_value is Dictionary \
				and str(result_value.get("id", "")) == result_id:
			return result_value.duplicate(true)
	return {}


func _queue_classic_enhanced_result_attachments(result_id: String) -> void:
	var request: Dictionary = _classic_encounter_phase.get(
		"request",
		{}
	).duplicate(true)
	request["response"] = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	request["enhancedResultId"] = result_id
	_classic_attachment_queue.append_array(
		_behavior_attachment_instructions(
			"encounter",
			"result",
			str(_classic_encounter_phase.get("targetKind", "")),
			[str(_classic_encounter_phase.get("encounterId", ""))],
			{
				"kind": "encounter-result",
				"result": {"kind": "enhanced", "id": result_id},
				"phase": "body",
			},
			request
		)
	)


func _finish_classic_enhanced_result() -> Dictionary:
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	var terminal: Variant = response.get("enhancedTerminal")
	if not (terminal is Dictionary):
		terminal = _classic_encounter_phase.get(
			"enhancedResult",
			{}
		).get("terminal", {"kind": "continue"})
	if not (terminal is Dictionary):
		return _classic_error("Enhanced Result has an invalid terminal outcome")
	match str(terminal.get("kind", "")):
		"classic-result":
			var transition_error := _consume_result_transition()
			if not transition_error.is_empty():
				return transition_error
			var result_index := int(terminal.get("index", -1))
			if result_index < 0 or result_index > 3:
				return _classic_error("Enhanced Result Classic target is invalid")
			response["outcome"] = result_index + 1
			response.erase("enhancedTerminal")
			_classic_encounter_phase["response"] = response
			_classic_encounter_phase["stage"] = "resume"
			return {"status": "continue"}
		"repeat":
			var transition_error := _consume_result_transition()
			if not transition_error.is_empty():
				return transition_error
			var encounter_kind := str(_classic_encounter_phase.get("encounterKind", ""))
			var encounter_id := int(_classic_encounter_phase.get("encounterId", -1))
			_classic_executor.pending_encounter = {}
			_classic_encounter_phase.clear()
			return _classic_executor._yield_encounter(encounter_kind, encounter_id, 0)
		"continue":
			var transition_error := _consume_result_transition()
			if not transition_error.is_empty():
				return transition_error
			return _complete_classic_enhanced_result_to_origin()
	return _classic_error("Enhanced Result has an unsupported terminal outcome")


func _complete_classic_enhanced_result_to_origin() -> Dictionary:
	var pending_anchor := _classic_pending_after_anchor.duplicate(true)
	var completion_request := {
		"encounterKind": str(_classic_encounter_phase.get("encounterKind", "")),
		"encounterId": int(_classic_encounter_phase.get("encounterId", -1)),
		"response": _classic_encounter_phase.get("response", {}).duplicate(true),
		"enhancedResult": _classic_encounter_phase.get("enhancedResult", {}).duplicate(true),
	}
	var target_kind := str(_classic_encounter_phase.get("targetKind", ""))
	var encounter_id := str(_classic_encounter_phase.get("encounterId", ""))
	_classic_executor.pending_encounter = {}
	var break_result: Dictionary = _classic_executor._break_encounter()
	if str(break_result.get("status", "")) == "error":
		return break_result
	_classic_encounter_phase["stage"] = "completion"
	_classic_attachment_queue.append_array(
		_behavior_attachment_instructions(
			"encounter",
			"complete",
			target_kind,
			[encounter_id],
			{"kind": "record", "phase": "complete"},
			completion_request
		)
	)
	_activate_pending_after_attachments()
	_queue_classic_record_transition_attachments(pending_anchor)
	return {"status": "continue"}


func _queue_classic_encounter_phase_attachments(
	hook: String,
	slot: int
) -> void:
	var request: Dictionary = _classic_encounter_phase.get(
		"request",
		{}
	).duplicate(true)
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	if hook != "enter":
		request["response"] = response
		request["outcome"] = int(response.get("outcome", 0))
		request["slot"] = slot
		if response.has("optionSlot"):
			request["optionSlot"] = int(response.get("optionSlot", -1))
	var contract_hook := hook
	var typed_anchor := {"kind": "record", "phase": "start"}
	if hook == "option":
		contract_hook = "response"
		for response_ref_value: Variant in _classic_selected_response_refs(response):
			if not (response_ref_value is Dictionary):
				continue
			var response_ref: Dictionary = response_ref_value
			if not _classic_response_is_available(response_ref):
				continue
			var response_request := request.duplicate(true)
			response_request["responseRef"] = response_ref.duplicate(true)
			_classic_attachment_queue.append_array(
				_behavior_attachment_instructions(
					"encounter",
					contract_hook,
					str(_classic_encounter_phase.get("targetKind", "")),
					[str(_classic_encounter_phase.get("encounterId", ""))],
					{
						"kind": "encounter-response",
						"response": response_ref.duplicate(true),
						"phase": "selected",
					},
					response_request
				)
			)
		return
	elif hook == "result":
		typed_anchor = {
			"kind": "encounter-result",
			"result": {"kind": "classic", "index": slot},
			"phase": "body-start",
		}
	_classic_attachment_queue.append_array(
		_behavior_attachment_instructions(
			"encounter",
			contract_hook,
			str(_classic_encounter_phase.get("targetKind", "")),
			[str(_classic_encounter_phase.get("encounterId", ""))],
			typed_anchor,
			request
		)
	)


func _queue_classic_encounter_availability_attachments() -> void:
	var request: Dictionary = _classic_encounter_phase.get(
		"request",
		{}
	).duplicate(true)
	for response_ref_value: Variant in _classic_encounter_response_refs(request):
		if not (response_ref_value is Dictionary):
			continue
		var response_ref: Dictionary = response_ref_value
		_classic_attachment_queue.append_array(
			_behavior_attachment_instructions(
				"encounter",
				"availability",
				str(_classic_encounter_phase.get("targetKind", "")),
				[str(_classic_encounter_phase.get("encounterId", ""))],
				{
					"kind": "encounter-response",
					"response": response_ref.duplicate(true),
					"phase": "availability",
				},
				{
					"encounterKind": str(_classic_encounter_phase.get("encounterKind", "")),
					"encounterId": int(_classic_encounter_phase.get("encounterId", -1)),
					"responseRef": response_ref.duplicate(true),
				}
			)
		)


func _classic_encounter_response_refs(request: Dictionary) -> Array:
	var result: Array = []
	var encounter: Variant = request.get("encounter", {})
	if not (encounter is Dictionary):
		return result
	var encounter_kind := str(_classic_encounter_phase.get("encounterKind", ""))
	if encounter_kind == "simple":
		for index: int in range(4):
			result.append({"kind": "simple-choice", "index": index})
	else:
		for index: int in range(8):
			result.append({"kind": "action-choice", "index": index})
		result.append({"kind": "typed-reply"})
		for index: int in range(10):
			result.append({"kind": "spell", "index": index})
		for index: int in range(5):
			result.append({"kind": "item", "index": index})
		if bool(encounter.get("thief", false)):
			for outcome: String in ["attempt", "success", "failure"]:
				result.append({"kind": "rogue", "outcome": outcome})
	if bool(encounter.get("canBackOut", false)):
		result.append({"kind": "back-out"})
	return result


func _apply_classic_availability_filter() -> Dictionary:
	var availability: Variant = _classic_encounter_phase.get(
		"availabilityResults",
		{}
	)
	if not (availability is Dictionary) or availability.is_empty():
		return {"status": "ok"}
	var request: Dictionary = _classic_encounter_phase.get(
		"request",
		{}
	).duplicate(true)
	var encounter: Variant = request.get("encounter", {})
	if not (encounter is Dictionary):
		return _classic_error("Classic encounter availability has no record")
	var filtered: Dictionary = encounter.duplicate(true)
	for key_value: Variant in availability:
		if bool(availability[key_value]):
			continue
		_disable_classic_encounter_response(filtered, str(key_value))
	request["encounter"] = filtered
	_classic_encounter_phase["request"] = request
	var yield_result: Dictionary = _classic_encounter_phase.get(
		"yieldResult",
		{}
	).duplicate(true)
	yield_result["payload"] = request.duplicate(true)
	_classic_encounter_phase["yieldResult"] = yield_result
	var pending_value: Variant = _classic_encounter_phase.get("pendingCommand", {})
	if pending_value is Dictionary:
		var pending_record: Dictionary = pending_value.duplicate(true)
		var continuation: Dictionary = pending_record.get(
			"continuation",
			{}
		).duplicate(true)
		continuation.merge(request, true)
		pending_record["continuation"] = continuation
		_classic_encounter_phase["pendingCommand"] = pending_record
	return {"status": "ok"}


func _disable_classic_encounter_response(encounter: Dictionary, key: String) -> void:
	var parts := key.split(":", false)
	var kind := str(parts[0]) if not parts.is_empty() else ""
	var index := int(parts[1]) if parts.size() > 1 and str(parts[1]).is_valid_int() else -1
	match kind:
		"simple-choice":
			_disable_array_slot(encounter, "choiceResults", index, 0)
		"action-choice":
			_disable_array_slot(encounter, "texts", index, "")
		"typed-reply":
			encounter["wordResult"] = 0
		"spell":
			_disable_array_slot(encounter, "spellIds", index, 0)
			_disable_array_slot(encounter, "spellResults", index, 0)
		"item":
			_disable_array_slot(encounter, "itemIds", index, 0)
			_disable_array_slot(encounter, "itemResults", index, 0)
		"rogue":
			if parts.size() > 1 and str(parts[1]) == "attempt":
				encounter["thief"] = false
		"back-out":
			encounter["canBackOut"] = false


func _disable_array_slot(
	record: Dictionary,
	field_name: String,
	index: int,
	replacement: Variant
) -> void:
	var value: Variant = record.get(field_name, [])
	if not (value is Array) or index < 0 or index >= value.size():
		return
	var next: Array = value.duplicate(true)
	next[index] = replacement
	record[field_name] = next


func _classic_response_reference(response: Dictionary) -> Dictionary:
	var authored: Variant = response.get("responseRef")
	if authored is Dictionary:
		return authored.duplicate(true)
	var option_slot := int(response.get("optionSlot", -1))
	if option_slot >= 0:
		return {
			"kind": (
				"action-choice"
				if str(_classic_encounter_phase.get("encounterKind", "")) == "complex"
				else "simple-choice"
			),
			"index": option_slot,
		}
	if int(response.get("outcome", 0)) == 0:
		return {"kind": "back-out"}
	return {}


func _classic_selected_response_refs(response: Dictionary) -> Array:
	var response_ref := _classic_response_reference(response)
	if response_ref.is_empty():
		return []
	var refs: Array = []
	if str(response_ref.get("kind", "")) == "rogue" \
			and str(response_ref.get("outcome", "")) in ["success", "failure"]:
		refs.append({"kind": "rogue", "outcome": "attempt"})
	refs.append(response_ref)
	return refs


func _classic_response_is_available(response_ref: Dictionary) -> bool:
	var availability: Variant = _classic_encounter_phase.get(
		"availabilityResults",
		{}
	)
	return not (availability is Dictionary) \
		or bool(availability.get(_classic_response_key(response_ref), true))


func _apply_classic_attachment_outcome(
	action_identity: Dictionary,
	value: Variant
) -> Dictionary:
	if str(action_identity.get("attachmentRole", "")) != "encounter" \
			or _classic_encounter_phase.is_empty():
		return {"status": "ok"}
	var anchor: Variant = action_identity.get("attachmentAnchor", {})
	if anchor is Dictionary \
			and str(anchor.get("kind", "")) == "encounter-response" \
			and str(anchor.get("phase", "")) == "availability":
		if not (value is bool):
			return _classic_error("Encounter availability behavior must return bool")
		var response_ref: Variant = anchor.get("response", {})
		if not (response_ref is Dictionary):
			return _classic_error("Encounter availability behavior lost its response")
		var availability: Dictionary = _classic_encounter_phase.get(
			"availabilityResults",
			{}
		).duplicate(true)
		availability[_classic_response_key(response_ref)] = bool(value)
		_classic_encounter_phase["availabilityResults"] = availability
		return {"status": "ok"}
	if not (value is Dictionary):
		return {"status": "ok"}
	var outcome: Dictionary = value
	var kind := str(outcome.get("kind", "continue"))
	if kind not in ["close", "resolve", "branch", "repeat"]:
		return {"status": "ok"}
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	if kind == "close" or kind == "repeat":
		response["status"] = "ok"
		if kind == "close":
			response["outcome"] = 0
	elif outcome.has("outcome"):
		var selected_outcome := int(outcome.get("outcome", 0))
		if selected_outcome < 0 or selected_outcome > 4:
			return _classic_error(
				"Encounter behavior outcome must be between 0 and 4"
			)
		response["status"] = "ok"
		response["outcome"] = selected_outcome
	else:
		return _classic_error(
			"Encounter behavior '%s' outcome requires a result number" % kind
		)
	response["behaviorOutcome"] = outcome.duplicate(true)
	_classic_encounter_phase["response"] = response
	return {
		"status": "redirect",
	}


func _redirect_executing_classic_result() -> Dictionary:
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	var behavior: Variant = response.get("behaviorOutcome", {})
	if not (behavior is Dictionary):
		return {"status": "continue"}
	var kind := str(behavior.get("kind", "continue"))
	var transition_error := _consume_result_transition()
	if not transition_error.is_empty():
		return transition_error
	if str(_classic_encounter_phase.get("stage", "")) != "executing-classic-result":
		_classic_attachment_queue.clear()
		_prepare_classic_encounter_result_phase()
		return {"status": "continue"}
	response.erase("behaviorOutcome")
	_classic_encounter_phase["response"] = response
	match kind:
		"repeat":
			var encounter_kind := str(_classic_encounter_phase.get("encounterKind", ""))
			var encounter_id := int(_classic_encounter_phase.get("encounterId", -1))
			_classic_encounter_phase.clear()
			return _classic_executor._yield_encounter(encounter_kind, encounter_id, 0)
		"close":
			return _complete_classic_enhanced_result_to_origin()
		"resolve", "branch":
			var outcome := int(response.get("outcome", 0))
			if outcome < 1 or outcome > 4:
				return _classic_error("Encounter result redirect requires Classic Result 1 through 4")
			if not _classic_executor.encounter_origins.is_empty():
				var origin: Dictionary = _classic_executor.encounter_origins[-1]
				origin["selectedOutcome"] = outcome
				_classic_executor.encounter_origins[-1] = origin
			return _classic_executor._branch_to_loaded_encounter_result(
				str(_classic_encounter_phase.get("encounterKind", "")),
				outcome - 1,
				0
			)
	return {"status": "continue"}


func _consume_result_transition() -> Dictionary:
	_result_transition_count += 1
	if _result_transition_count <= MAX_RESULT_TRANSITIONS:
		return {}
	return _classic_error(
		"Classic encounter exceeded %d result transitions"
		% MAX_RESULT_TRANSITIONS
	)


func _classic_response_key(response_ref: Dictionary) -> String:
	var kind := str(response_ref.get("kind", ""))
	if response_ref.has("index"):
		return "%s:%d" % [kind, int(response_ref.get("index", -1))]
	if kind == "rogue":
		return "%s:%s" % [kind, str(response_ref.get("outcome", ""))]
	return kind


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
	var target_kind := "trigger"
	var target_ids: Array = [trigger_id]
	var role := "action"
	var contract_hook := "run"
	var typed_anchor := {
		"kind": "record",
		"phase": "start" if hook == "before-ap" else "complete",
	} if is_record_hook else {
		"kind": "classic-action",
		"slot": slot,
		"phase": "before" if hook == "before-slot" else "after",
	}
	var encounter_result := _classic_encounter_result_anchor(anchor, hook)
	if not encounter_result.is_empty():
		target_kind = str(encounter_result.get("targetKind", ""))
		target_ids = [str(encounter_result.get("encounterId", ""))]
		role = "encounter"
		contract_hook = "result"
		typed_anchor = encounter_result.get("anchor", {}).duplicate(true)
	return _behavior_attachment_instructions(
		role,
		contract_hook,
		target_kind,
		target_ids,
		typed_anchor
	)


func _classic_encounter_result_anchor(
	execution_anchor: Dictionary,
	placement_hook: String
) -> Dictionary:
	if placement_hook not in ["before-slot", "after-slot"]:
		return {}
	var origins: Variant = execution_anchor.get("encounterOrigins", [])
	if not (origins is Array) or origins.is_empty():
		return {}
	var origin_value: Variant = origins[-1]
	if not (origin_value is Dictionary):
		return {}
	var origin: Dictionary = origin_value
	var outcome := int(origin.get("selectedOutcome", 0))
	var encounter_kind := str(origin.get("encounterKind", ""))
	var encounter_id := int(origin.get("encounterId", -1))
	var trigger_id := str(execution_anchor.get("triggerId", ""))
	var expected_id := "%s encounter:%d:outcome:%d" % [
		encounter_kind,
		encounter_id,
		outcome,
	]
	if outcome < 1 or encounter_kind not in ["simple", "complex"] \
			or encounter_id < 0 or trigger_id != expected_id:
		return {}
	return {
		"targetKind": (
			"complexEncounter" if encounter_kind == "complex"
			else "simpleEncounter"
		),
		"encounterId": encounter_id,
		"anchor": {
			"kind": "encounter-result-action",
			"resultIndex": outcome - 1,
			"slot": int(execution_anchor.get("slot", -1)),
			"phase": "before" if placement_hook == "before-slot" else "after",
		},
	}


func _behavior_attachment_instructions(
	role: String,
	hook: String,
	target_kind: String,
	target_ids: Array,
	anchor: Dictionary,
	request := {}
) -> Array:
	var bindings := scenario_script_runtime.matching_bindings(
		role,
		hook,
		target_kind,
		target_ids,
		anchor
	)
	var slot := _behavior_anchor_slot(anchor)
	var attachment_slot: Variant = null
	if slot >= 0:
		attachment_slot = slot
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
					"role": role,
					"hook": hook,
					"targetKind": target_kind,
					"recordId": str(binding.get("recordId", "")),
					"slot": attachment_slot,
					"anchor": anchor.duplicate(true),
					"order": int(binding.get("order", 0)),
					"priority": int(binding.get("priority", 0)),
					"request": (
						request.duplicate(true)
						if request is Dictionary else {}
					),
				},
			},
		})
	return instructions


func _behavior_anchor_slot(anchor: Dictionary) -> int:
	match str(anchor.get("kind", "")):
		"classic-action", "encounter-result-action":
			return int(anchor.get("slot", -1))
		"encounter-response":
			var response: Variant = anchor.get("response", {})
			if response is Dictionary and response.has("index"):
				return int(response.get("index", -1))
		"encounter-result":
			var result: Variant = anchor.get("result", {})
			if result is Dictionary and str(result.get("kind", "")) == "classic":
				return int(result.get("index", -1))
	return -1


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
		identity["attachmentRole"] = str(attachment.get("role", "action"))
		identity["attachmentTargetKind"] = str(
			attachment.get("targetKind", "")
		)
		identity["attachmentAnchor"] = (
			attachment.get("anchor", {}).duplicate(true)
			if attachment.get("anchor") is Dictionary else {}
		)
	return identity


func _reset_classic_attachment_plan() -> void:
	_classic_attachment_queue.clear()
	_classic_deferred_instruction.clear()
	_classic_deferred_result.clear()
	_classic_executing_anchor.clear()
	_classic_pending_after_anchor.clear()
	_classic_encounter_phase.clear()
	_result_transition_count = 0


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
		"encounterPhase",
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
	var transition_count: Variant = value.get("resultTransitionCount")
	if not _is_nonnegative_integer_number(transition_count):
		return {
			"valid": false,
			"message": "Classic attachment snapshot has an invalid result transition count",
		}
	var encounter_validation := _validate_classic_encounter_phase_snapshot(
		value.get("encounterPhase")
	)
	if not bool(encounter_validation.get("valid", false)):
		return encounter_validation
	return {"valid": true}


static func _is_nonnegative_integer_number(value: Variant) -> bool:
	if not (value is int or value is float):
		return false
	var number := float(value)
	return number >= 0.0 and number == floorf(number)


func mixed_execution_state() -> Dictionary:
	var response: Dictionary = _classic_encounter_phase.get(
		"response",
		{}
	).duplicate(true)
	var active_response: Variant = null
	if not _classic_encounter_phase.is_empty():
		active_response = _classic_response_reference(response)
	var active_result: Variant = null
	var enhanced_result_id := str(response.get("enhancedResultId", ""))
	if not enhanced_result_id.is_empty():
		active_result = {"kind": "enhanced", "id": enhanced_result_id}
	var outcome := int(response.get("outcome", 0))
	if active_result == null and outcome > 0:
		active_result = {"kind": "classic", "index": absi(outcome) - 1}
	if active_response == null and _semantic_active_response_ref is Dictionary:
		active_response = _semantic_active_response_ref.duplicate(true)
	if active_result == null and _semantic_active_result_ref is Dictionary:
		active_result = _semantic_active_result_ref.duplicate(true)
	var attachment_order: Array = []
	for instruction_value: Variant in _classic_attachment_queue:
		if not (instruction_value is Dictionary):
			continue
		var attachment: Variant = instruction_value.get(
			"parameters",
			{}
		).get("attachment", {})
		if attachment is Dictionary:
			attachment_order.append({
				"id": str(attachment.get("id", "")),
				"order": int(attachment.get("order", 0)),
			})
	return {
		"activeResponseRef": (
			active_response.duplicate(true)
			if active_response is Dictionary else null
		),
		"activeResultRef": active_result,
		"mixedSequenceCursor": {
			"executingAnchor": _classic_executing_anchor.duplicate(true),
			"pendingAfterAnchor": _classic_pending_after_anchor.duplicate(true),
			"encounterStage": str(_classic_encounter_phase.get("stage", "")),
			"remainingAttachments": _classic_attachment_queue.size(),
		},
		"resultTransitionCount": _result_transition_count,
		"attachmentOrder": attachment_order,
	}


static func _validate_classic_encounter_phase_snapshot(
	value: Variant
) -> Dictionary:
	if not (value is Dictionary):
		return {
			"valid": false,
			"message": "Classic attachment snapshot has invalid encounterPhase",
		}
	if value.is_empty():
		return {"valid": true}
	if str(value.get("stage", "")) not in [
		"entry",
		"presenting",
		"option",
		"result",
		"enhanced-result",
		"enhanced-terminal",
		"executing-classic-result",
		"completion",
		"invalid-enhanced-result",
		"resume",
	]:
		return {
			"valid": false,
			"message": "Classic encounter snapshot has an invalid stage",
		}
	var pending_validation := ScenarioPendingCommand.validate(
		value.get("pendingCommand")
	)
	if not bool(pending_validation.get("valid", false)):
		return {
			"valid": false,
			"message": "Classic encounter snapshot has an invalid continuation",
		}
	for field_name: String in ["yieldResult", "request", "response"]:
		if not (value.get(field_name) is Dictionary):
			return {
				"valid": false,
				"message": "Classic encounter snapshot has invalid %s"
					% field_name,
			}
	var yield_result: Dictionary = value["yieldResult"]
	if str(yield_result.get("status", "")) != "yield" \
			or str(yield_result.get("command", "")) != "start_encounter":
		return {
			"valid": false,
			"message": "Classic encounter snapshot has an invalid presentation",
		}
	for field_name: String in ["encounterKind", "encounterId", "targetKind"]:
		if not (value.get(field_name) is String) \
				or str(value.get(field_name)).is_empty():
			return {
				"valid": false,
				"message": "Classic encounter snapshot is missing %s"
					% field_name,
			}
	return {"valid": true}


func _classic_result(value: Variant) -> Dictionary:
	_sync_classic_observability()
	if value is Dictionary:
		if str(value.get("status", "")) == "yield":
			_capture_classic_pending(value)
			if str(value.get("command", "")) == "start_encounter" \
					and (
						_classic_encounter_phase.is_empty()
						or str(_classic_encounter_phase.get("stage", "")) \
							== "executing-classic-result"
					):
				_classic_encounter_phase.clear()
				return _begin_classic_encounter_phase(value)
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
			return {
				"status": "continue",
				"value": step_result.data.get("value"),
			}
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
	_semantic_active_response_ref = null
	_semantic_active_result_ref = null
	_result_transition_count = 0
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
	_semantic_active_response_ref = null
	_semantic_active_result_ref = null
	_result_transition_count = 0
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
		saved_pending.action_identity,
		false
	)
	if str(applied.get("status", "")) != "continue":
		return applied
	return run(context)


func snapshot() -> Dictionary:
	var pending_value: Variant = null
	if pending_command != null:
		pending_value = pending_command.to_dictionary()
	var result := {
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
		"semanticActiveResponseRef": (
			_semantic_active_response_ref.duplicate(true)
			if _semantic_active_response_ref is Dictionary else null
		),
		"semanticActiveResultRef": (
			_semantic_active_result_ref.duplicate(true)
			if _semantic_active_result_ref is Dictionary else null
		),
		"resultTransitionCount": _result_transition_count,
	}
	if scenario_script_runtime != null:
		result["scenarioScriptRuntime"] = scenario_script_runtime.snapshot()
	return result


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
	_semantic_active_response_ref = (
		saved.get("semanticActiveResponseRef").duplicate(true)
		if saved.get("semanticActiveResponseRef") is Dictionary else null
	)
	_semantic_active_result_ref = (
		saved.get("semanticActiveResultRef").duplicate(true)
		if saved.get("semanticActiveResultRef") is Dictionary else null
	)
	_result_transition_count = int(saved.get("resultTransitionCount", 0))
	if scenario_script_runtime != null:
		if not saved.has("scenarioScriptRuntime"):
			return _error("Saved scenario has no Safe behavior state")
		var script_restore := scenario_script_runtime.restore(
			saved["scenarioScriptRuntime"]
		)
		if str(script_restore.get("status", "")) != "ok":
			return script_restore
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
	if not _is_nonnegative_integer_number(saved.get("resultTransitionCount", -1)) \
			or int(saved.get("resultTransitionCount", -1)) > MAX_RESULT_TRANSITIONS:
		return _invalid("Scenario VM snapshot has invalid result transition count")
	for field_name: String in [
		"semanticActiveResponseRef",
		"semanticActiveResultRef",
	]:
		var saved_reference: Variant = saved.get(field_name)
		if saved_reference != null and not (saved_reference is Dictionary):
			return _invalid("Scenario VM snapshot has invalid %s" % field_name)
	if saved.get("pendingCommand") != null:
		var pending_validation := ScenarioPendingCommand.validate(saved["pendingCommand"])
		if not bool(pending_validation.get("valid", false)):
			return pending_validation
	if saved.has("scenarioScriptRuntime"):
		var script_validation := ScenarioScriptRuntimeScript.validate_snapshot(
			saved["scenarioScriptRuntime"]
		)
		if not bool(script_validation.get("valid", false)):
			return script_validation
	return {"valid": true}


func _apply_step_result(
	result: ScenarioStepResult,
	handler_id: String,
	action_identity: Dictionary,
	advance_instruction := true
) -> Dictionary:
	match result.kind:
		ScenarioStepResult.CONTINUE:
			if advance_instruction:
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
			if advance_instruction:
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
		var parameters: Variant = instruction.get("parameters", {})
		var attachment: Variant = (
			parameters.get("attachment") if parameters is Dictionary else null
		)
		if attachment is Dictionary:
			identity["attachmentRole"] = str(attachment.get("role", "action"))
			identity["attachmentHook"] = str(attachment.get("hook", "run"))
			identity["attachment"] = attachment.duplicate(true)
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
