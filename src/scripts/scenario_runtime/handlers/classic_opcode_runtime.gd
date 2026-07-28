class_name ClassicOpcodeRuntime
extends RefCounted

const MapBridgeScript = preload("res://scripts/classic_runtime/classic_map_bridge.gd")
const CoreHandlerCatalogScript = preload(
	"res://scripts/scenario_runtime/handlers/core_handler_catalog.gd"
)
const CombatOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_combat_opcode_runtime.gd"
)
const InventoryOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_inventory_opcode_runtime.gd"
)
const CharacterOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_character_opcode_runtime.gd"
)
const MapTimeOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_map_time_opcode_runtime.gd"
)
const EncounterOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_encounter_opcode_runtime.gd"
)
const PresentationOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_presentation_opcode_runtime.gd"
)
const MAX_INTERNAL_STEPS := 256
const MAX_CALL_STACK_DEPTH := 20
const EXECUTION_SNAPSHOT_SCHEMA_VERSION := 2
const HANDLED_OPCODES := [
	-23, -14,
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
	10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
	30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
	40, 41, 42, 43, 44, 45, 46, 47, 48, 49,
	50, 51, 52, 53, 54, 55, 56, 57, 58,
	60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 72, 73, 76, 77, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89,
	90, 91, 92, 93, 94, 95, 96, 97, 98,
	99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 111, 112,
	119, 120, 121, 122, 123, 124, 125, 126, 127,
]
var bundle: ClassicCampaignBundle
var runtime_state: ClassicRuntimeState
var current_trigger: Dictionary = {}
var current_action_index := 0
var origin_action_point: Dictionary = {}
var active_action_point_header: Dictionary = {}
var suppress_action_point_destination := false
var remove_action_point := false
var removal_x := 0
var removal_y := 0
var call_stack: Array = []
var gosub_active := false
# Classic mechanics expose these views while older focused fixtures still call
# the typed resume helpers. The only stored continuation is pending_continuation;
# ScenarioInterpreter serializes it into ScenarioPendingCommand.
var pending_continuation: Dictionary = {}
var pending_choice: Dictionary:
	get:
		return _pending_view("choice")
	set(value):
		_set_pending_view("choice", value)
var pending_encounter: Dictionary:
	get:
		return _pending_view("encounter")
	set(value):
		_set_pending_view("encounter", value)
var pending_battle: Dictionary:
	get:
		return _pending_view("battle")
	set(value):
		_set_pending_view("battle", value)
var pending_selective_battle: Dictionary:
	get:
		return _pending_view("selective-battle")
	set(value):
		_set_pending_view("selective-battle", value)
var pending_item_check: Dictionary:
	get:
		return _pending_view("item-check")
	set(value):
		_set_pending_view("item-check", value)
var pending_wealth_payment: Dictionary:
	get:
		return _pending_view("wealth-payment")
	set(value):
		_set_pending_view("wealth-payment", value)
var pending_party_condition_check: Dictionary:
	get:
		return _pending_view("party-condition-check")
	set(value):
		_set_pending_view("party-condition-check", value)
var pending_character_ability_check: Dictionary:
	get:
		return _pending_view("character-ability-check")
	set(value):
		_set_pending_view("character-ability-check", value)
var pending_misc_branch: Dictionary:
	get:
		return _pending_view("misc-branch")
	set(value):
		_set_pending_view("misc-branch", value)
var pending_ally_check: Dictionary:
	get:
		return _pending_view("ally-check")
	set(value):
		_set_pending_view("ally-check", value)
var pending_combat_monster_check: Dictionary:
	get:
		return _pending_view("combat-monster-check")
	set(value):
		_set_pending_view("combat-monster-check", value)
var pending_combat_revival: Dictionary:
	get:
		return _pending_view("combat-revival")
	set(value):
		_set_pending_view("combat-revival", value)
var pending_battle_round_macro: Dictionary:
	get:
		return _pending_view("battle-round-macro")
	set(value):
		_set_pending_view("battle-round-macro", value)
var pending_random_branch: Dictionary:
	get:
		return _pending_view("random-branch")
	set(value):
		_set_pending_view("random-branch", value)
var pending_time_mutation: Dictionary:
	get:
		return _pending_view("time-mutation")
	set(value):
		_set_pending_view("time-mutation", value)
var pending_exploration_status: Dictionary:
	get:
		return _pending_view("exploration-status")
	set(value):
		_set_pending_view("exploration-status", value)
var pending_teleport: Dictionary:
	get:
		return _pending_view("teleport")
	set(value):
		_set_pending_view("teleport", value)
var execution_context: Dictionary = {}
var encounter_origins: Array = []
var loaded_simple_encounter_id := -1
var loaded_complex_encounter_id := -1
var percent_roll_provider: Callable
var semantic_operation_executor: Callable
var scenario_run_delegate: Callable
var compatibility_instruction_registry: ScenarioInstructionRegistry
var trace: Array = []
var last_error := ""
var halted := false
var _combat_opcode_runtime: RefCounted
var _inventory_opcode_runtime: RefCounted
var _character_opcode_runtime: RefCounted
var _map_time_opcode_runtime: RefCounted
var _encounter_opcode_runtime: RefCounted
var _presentation_opcode_runtime: RefCounted


func configure(campaign_bundle: ClassicCampaignBundle, state: ClassicRuntimeState) -> void:
	bundle = campaign_bundle
	runtime_state = state
	if _combat_opcode_runtime == null:
		_combat_opcode_runtime = CombatOpcodeRuntimeScript.new()
		_combat_opcode_runtime.configure(self)
	if _inventory_opcode_runtime == null:
		_inventory_opcode_runtime = InventoryOpcodeRuntimeScript.new()
		_inventory_opcode_runtime.configure(self)
	if _character_opcode_runtime == null:
		_character_opcode_runtime = CharacterOpcodeRuntimeScript.new()
		_character_opcode_runtime.configure(self)
	if _map_time_opcode_runtime == null:
		_map_time_opcode_runtime = MapTimeOpcodeRuntimeScript.new()
		_map_time_opcode_runtime.configure(self)
	if _encounter_opcode_runtime == null:
		_encounter_opcode_runtime = EncounterOpcodeRuntimeScript.new()
		_encounter_opcode_runtime.configure(self)
	if _presentation_opcode_runtime == null:
		_presentation_opcode_runtime = PresentationOpcodeRuntimeScript.new()
		_presentation_opcode_runtime.configure(self)
	if compatibility_instruction_registry == null:
		compatibility_instruction_registry = ScenarioInstructionRegistry.new()
		if not CoreHandlerCatalogScript.register_all(
			compatibility_instruction_registry
		):
			last_error = compatibility_instruction_registry.last_error
			halted = true
			return
	loaded_simple_encounter_id = -1
	loaded_complex_encounter_id = -1
	reset_execution()


func classic_handler_runtime(handler_id: String) -> Object:
	if handler_id == "core.combat":
		return _combat_opcode_runtime
	if handler_id == "core.inventory":
		return _inventory_opcode_runtime
	if handler_id == "core.character":
		return _character_opcode_runtime
	if handler_id == "core.map-time":
		return _map_time_opcode_runtime
	if handler_id == "core.encounters":
		return _encounter_opcode_runtime
	if handler_id == "core.presentation":
		return _presentation_opcode_runtime
	return self


func set_percent_roll_provider(provider: Callable) -> void:
	percent_roll_provider = provider


func set_semantic_operation_executor(executor: Callable) -> void:
	semantic_operation_executor = executor


func set_scenario_run_delegate(delegate: Callable) -> void:
	scenario_run_delegate = delegate


func _pending_view(continuation_id: String) -> Dictionary:
	if str(pending_continuation.get("continuationId", "")) != continuation_id:
		return {}
	var data: Variant = pending_continuation.get("data")
	if not (data is Dictionary) or data.is_empty():
		pending_continuation.clear()
		return {}
	return data


func _set_pending_view(continuation_id: String, value: Dictionary) -> void:
	if value.is_empty():
		if str(pending_continuation.get("continuationId", "")) == continuation_id:
			pending_continuation.clear()
		return
	set_pending_continuation(continuation_id, value)


func set_pending_continuation(
	continuation_id: String,
	data: Dictionary
) -> void:
	pending_continuation = {
		"continuationId": continuation_id,
		"data": data,
	}


static func normalize_opcode(raw_code: int) -> int:
	return abs(raw_code) if raw_code < 0 and raw_code not in [-14, -23] else raw_code


static func handles_opcode(code: int) -> bool:
	return HANDLED_OPCODES.has(code)


func reset_execution() -> void:
	current_trigger = {}
	current_action_index = 0
	origin_action_point.clear()
	active_action_point_header.clear()
	suppress_action_point_destination = false
	remove_action_point = false
	removal_x = 0
	removal_y = 0
	call_stack.clear()
	gosub_active = false
	pending_continuation.clear()
	execution_context.clear()
	encounter_origins.clear()
	trace.clear()
	last_error = ""
	halted = false


func make_execution_snapshot() -> Dictionary:
	if halted:
		return _snapshot_error("A stopped Classic action point cannot be saved")
	var snapshot := {
		"schemaVersion": EXECUTION_SNAPSHOT_SCHEMA_VERSION,
		"currentTrigger": current_trigger.duplicate(true),
		"currentActionIndex": current_action_index,
		"originActionPoint": origin_action_point.duplicate(true),
		"activeActionPointHeader": active_action_point_header.duplicate(true),
		"suppressActionPointDestination": suppress_action_point_destination,
		"removeActionPoint": remove_action_point,
		"removalX": removal_x,
		"removalY": removal_y,
		"callStack": call_stack.duplicate(true),
		"gosubActive": gosub_active,
		"pendingContinuation": pending_continuation.duplicate(true),
		"executionContext": execution_context.duplicate(true),
		"encounterOrigins": encounter_origins.duplicate(true),
		"loadedSimpleEncounterId": loaded_simple_encounter_id,
		"loadedComplexEncounterId": loaded_complex_encounter_id,
	}
	if not _is_snapshot_value(snapshot):
		return _snapshot_error(
			"Classic continuation contains runtime-only values and cannot be saved"
		)
	return {"status": "ok", "snapshot": snapshot}


func restore_execution_snapshot(snapshot: Variant) -> Dictionary:
	var validation := validate_execution_snapshot(snapshot)
	if str(validation.get("status", "")) != "ok":
		return validation
	var saved: Dictionary = snapshot
	reset_execution()
	current_trigger = saved["currentTrigger"].duplicate(true)
	current_action_index = int(saved["currentActionIndex"])
	origin_action_point = saved["originActionPoint"].duplicate(true)
	active_action_point_header = saved["activeActionPointHeader"].duplicate(true)
	suppress_action_point_destination = bool(saved.get(
		"suppressActionPointDestination",
		false
	))
	remove_action_point = bool(saved["removeActionPoint"])
	removal_x = int(saved["removalX"])
	removal_y = int(saved["removalY"])
	call_stack = saved["callStack"].duplicate(true)
	gosub_active = bool(saved["gosubActive"])
	pending_continuation = saved["pendingContinuation"].duplicate(true)
	execution_context = saved["executionContext"].duplicate(true)
	encounter_origins = saved["encounterOrigins"].duplicate(true)
	loaded_simple_encounter_id = int(saved["loadedSimpleEncounterId"])
	loaded_complex_encounter_id = int(saved["loadedComplexEncounterId"])
	return {"status": "ok"}


static func validate_execution_snapshot(snapshot: Variant) -> Dictionary:
	if not (snapshot is Dictionary):
		return _snapshot_error("Classic continuation execution state is not a dictionary")
	if int(snapshot.get("schemaVersion", 0)) != EXECUTION_SNAPSHOT_SCHEMA_VERSION:
		return _snapshot_error("Classic continuation execution schema is not supported")
	for field_name: String in [
		"currentTrigger",
		"originActionPoint",
		"activeActionPointHeader",
		"pendingContinuation",
		"executionContext",
	]:
		if not (snapshot.get(field_name) is Dictionary):
			return _snapshot_error("Classic continuation has invalid %s" % field_name)
	var pending_value: Dictionary = snapshot["pendingContinuation"]
	if not pending_value.is_empty():
		if not (pending_value.get("continuationId") is String) \
				or str(pending_value["continuationId"]).is_empty() \
				or not (pending_value.get("data") is Dictionary):
			return _snapshot_error(
				"Classic continuation has an invalid pending record"
			)
	for field_name: String in ["callStack", "encounterOrigins"]:
		if not (snapshot.get(field_name) is Array):
			return _snapshot_error("Classic continuation has invalid %s" % field_name)
	if int(snapshot.get("currentActionIndex", -1)) < 0:
		return _snapshot_error("Classic continuation has an invalid action index")
	if snapshot["callStack"].size() > MAX_CALL_STACK_DEPTH:
		return _snapshot_error("Classic continuation exceeds the GOSUB stack limit")
	for field_name: String in ["removeActionPoint", "gosubActive"]:
		if not (snapshot.get(field_name) is bool):
			return _snapshot_error("Classic continuation has invalid %s" % field_name)
	if snapshot.has("suppressActionPointDestination") \
			and not (snapshot.get("suppressActionPointDestination") is bool):
		return _snapshot_error(
			"Classic continuation has invalid suppressActionPointDestination"
		)
	for field_name: String in [
		"removalX",
		"removalY",
		"loadedSimpleEncounterId",
		"loadedComplexEncounterId",
	]:
		var field_value: Variant = snapshot.get(field_name)
		if not (field_value is int or field_value is float):
			return _snapshot_error("Classic continuation has invalid %s" % field_name)
	for frame_value: Variant in snapshot["callStack"]:
		if not (frame_value is Dictionary) \
				or not (frame_value.get("trigger") is Dictionary) \
				or not (frame_value.get("actionPointHeader") is Dictionary) \
				or not (frame_value.get("actionIndex") is int or frame_value.get("actionIndex") is float):
			return _snapshot_error("Classic continuation has an invalid GOSUB frame")
	for origin_value: Variant in snapshot["encounterOrigins"]:
		if not (origin_value is Dictionary) \
				or not (origin_value.get("trigger") is Dictionary) \
				or not (origin_value.get("callStack") is Array) \
				or not (origin_value.get("actionPointHeader") is Dictionary):
			return _snapshot_error("Classic continuation has an invalid encounter frame")
	if not _is_snapshot_value(snapshot):
		return _snapshot_error("Classic continuation contains invalid runtime values")
	return {"status": "ok"}


static func _is_snapshot_value(value: Variant) -> bool:
	if value == null or value is bool or value is int or value is float or value is String:
		return true
	if value is Array:
		for child_value: Variant in value:
			if not _is_snapshot_value(child_value):
				return false
		return true
	if value is Dictionary:
		for key: Variant in value:
			if not (key is String) or not _is_snapshot_value(value[key]):
				return false
		return true
	return false


static func _snapshot_error(message: String) -> Dictionary:
	return {"status": "error", "message": message}


func begin_trigger(trigger_id: String, start_slot := 0, context := {}) -> bool:
	reset_execution()
	if bundle == null or runtime_state == null:
		last_error = "ClassicOpcodeRuntime must be configured before execution"
		return false
	if not (context is Dictionary):
		last_error = "Classic action execution context must be a dictionary"
		return false
	execution_context = context.duplicate(true)
	var trigger := runtime_state.get_action_point_override(trigger_id)
	if trigger.is_empty():
		trigger = bundle.get_trigger(trigger_id)
	if trigger.is_empty():
		last_error = "Unknown classic trigger: %s" % trigger_id
		return false
	trigger = runtime_state.get_effective_action_point(trigger)
	if _is_map_action_point(trigger):
		origin_action_point = trigger.duplicate(true)
	active_action_point_header = trigger.duplicate(true)
	active_action_point_header.erase("actions")
	_set_cursor(trigger, start_slot)
	return true


func run_until_yield() -> Dictionary:
	if scenario_run_delegate.is_valid():
		var delegated_result: Variant = scenario_run_delegate.call()
		if delegated_result is Dictionary:
			return delegated_result
		return _halt_with_error(
			"Scenario VM returned an invalid Classic execution result"
		)
	return run_compatibility_loop()


func run_compatibility_loop() -> Dictionary:
	if halted:
		return _error_result(last_error if not last_error.is_empty() else "Interpreter is halted")
	if not pending_choice.is_empty():
		return _error_result("A classic choice must be resumed before execution can continue")
	if not pending_encounter.is_empty():
		return _error_result("A classic encounter must be resumed before execution can continue")
	if not pending_battle.is_empty():
		return _error_result("A classic battle outcome must be resumed before execution can continue")
	if not pending_selective_battle.is_empty():
		return _error_result("A classic selective battle must be resumed before execution can continue")
	if not pending_item_check.is_empty():
		return _error_result("A classic item check must be resumed before execution can continue")
	if not pending_wealth_payment.is_empty():
		return _error_result("A classic wealth payment must be resumed before execution can continue")
	if not pending_party_condition_check.is_empty():
		return _error_result("A classic party-condition check must be resumed before execution can continue")
	if not pending_character_ability_check.is_empty():
		return _error_result(
			"A classic character-ability check must be resumed before execution can continue"
		)
	if not pending_misc_branch.is_empty():
		return _error_result("A classic party identity check must be resumed before execution can continue")
	if not pending_ally_check.is_empty():
		return _error_result("A classic ally check must be resumed before execution can continue")
	if not pending_combat_monster_check.is_empty():
		return _error_result("A classic combat-monster check must be resumed before execution can continue")
	if not pending_combat_revival.is_empty():
		return _error_result("A classic combat revival must be resumed before execution can continue")
	if not pending_battle_round_macro.is_empty():
		return _error_result("A classic battle-round macro must be resumed before execution can continue")
	if not pending_random_branch.is_empty():
		return _error_result("A classic random branch presentation must finish before execution can continue")
	if not pending_time_mutation.is_empty():
		return _error_result("A classic time mutation must finish before execution can continue")
	if not pending_exploration_status.is_empty():
		return _error_result(
			"A classic exploration-status action must finish before execution can continue"
		)
	if not pending_teleport.is_empty():
		return _error_result("A classic teleport must finish before execution can continue")

	for _step: int in MAX_INTERNAL_STEPS:
		if current_trigger.is_empty():
			return _completed_result("action-point-ended")

		var actions: Variant = current_trigger.get("actions", [])
		if not (actions is Array):
			return _halt_with_error("Trigger %s has no action array" % _current_trigger_id())
		if current_action_index >= actions.size():
			return _finish_action_point("action-point-ended", true)

		var action: Variant = actions[current_action_index]
		current_action_index += 1
		if not (action is Dictionary):
			return _halt_with_error("Trigger %s contains a non-object action" % _current_trigger_id())
		_update_gosub_state(action)
		trace.append({
			"triggerId": _current_trigger_id(),
			"slot": int(action.get("slot", -1)),
			"code": int(action.get("code", 0)),
		})
		var result := _execute_action(action)
		if str(result.get("status", "")) == "continue":
			continue
		return result

	return _halt_with_error("Classic action execution exceeded %d internal steps" % MAX_INTERNAL_STEPS)


func take_next_instruction() -> Dictionary:
	if halted:
		return _error_result(
			last_error if not last_error.is_empty() else "Interpreter is halted"
		)
	if current_trigger.is_empty():
		return _completed_result("action-point-ended")
	var actions: Variant = current_trigger.get("actions", [])
	if not (actions is Array):
		return _halt_with_error(
			"Trigger %s has no action array" % _current_trigger_id()
		)
	if current_action_index >= actions.size():
		return _finish_action_point("action-point-ended", true)
	var action: Variant = actions[current_action_index]
	current_action_index += 1
	if not (action is Dictionary):
		return _halt_with_error(
			"Trigger %s contains a non-object action" % _current_trigger_id()
		)
	_update_gosub_state(action)
	trace.append({
		"triggerId": _current_trigger_id(),
		"slot": int(action.get("slot", -1)),
		"code": int(action.get("code", 0)),
	})
	return {
		"status": "instruction",
		"instruction": action,
	}


func execute_prepared_instruction(action: Dictionary) -> Dictionary:
	return _execute_action(action)


func is_prepared_instruction_dispatcher_noop(action: Dictionary) -> bool:
	if bundle == null or current_trigger.is_empty():
		return false
	return bundle.is_dispatcher_noop(current_trigger, action)


func resume_choice(accepted: bool) -> Dictionary:
	return _encounter_opcode_runtime.resume_choice(accepted)


func resume_encounter(outcome: int, encounter_state := {}) -> Dictionary:
	return _encounter_opcode_runtime.resume_encounter(
		outcome,
		encounter_state
	)


func resume_battle(coward: bool) -> Dictionary:
	return _combat_opcode_runtime.resume_battle(coward)


func resume_selective_battle(survivor_count: int) -> Dictionary:
	return _combat_opcode_runtime.resume_selective_battle(survivor_count)


func resume_forced_battle_end() -> Dictionary:
	return _combat_opcode_runtime.resume_forced_battle_end()


func resume_forced_battle_at_slot(resume_slot: int) -> Dictionary:
	return _combat_opcode_runtime.resume_forced_battle_at_slot(resume_slot)


func resume_teleport() -> Dictionary:
	return _map_time_opcode_runtime.resume_teleport()


func resume_item_check(possessed: bool) -> Dictionary:
	return _inventory_opcode_runtime.resume_item_check(possessed)


func resume_wealth_payment(paid: bool) -> Dictionary:
	return _inventory_opcode_runtime.resume_wealth_payment(paid)


func resume_party_condition_check(active: bool) -> Dictionary:
	return _character_opcode_runtime.resume_party_condition_check(active)


func resume_character_ability_check(passed: bool) -> Dictionary:
	return _character_opcode_runtime.resume_character_ability_check(passed)


func resume_misc_branch(matched: bool) -> Dictionary:
	return _character_opcode_runtime.resume_misc_branch(matched)


func resume_ally_check(present: bool) -> Dictionary:
	return _character_opcode_runtime.resume_ally_check(present)


func resume_combat_monster_check(present: bool) -> Dictionary:
	return _combat_opcode_runtime.resume_combat_monster_check(present)


func resume_combat_revival(party_revived: bool) -> Dictionary:
	return _combat_opcode_runtime.resume_combat_revival(party_revived)


func resume_battle_round_macro() -> Dictionary:
	return _combat_opcode_runtime.resume_battle_round_macro()


func resume_random_branch() -> Dictionary:
	if pending_random_branch.is_empty():
		return _error_result("No classic random branch is waiting for presentation")
	var random_branch := pending_random_branch
	pending_random_branch = {}
	return _apply_random_branch(random_branch)


func resume_back_up_party() -> Dictionary:
	return _map_time_opcode_runtime.resume_back_up_party()


func resume_time_mutation(response: Dictionary) -> Dictionary:
	return _map_time_opcode_runtime.resume_time_mutation(response)


func resume_exploration_status(response: Dictionary) -> Dictionary:
	return _map_time_opcode_runtime.resume_exploration_status(response)


func _execute_action(action: Dictionary) -> Dictionary:
	if str(action.get("kind", "classic")) == "semantic":
		if not semantic_operation_executor.is_valid():
			return _halt_with_error(
				"Semantic scenario operation '%s' has no registered executor"
				% action.get("operation", "")
			)
		var semantic_result: Variant = semantic_operation_executor.call(action)
		if semantic_result is Dictionary:
			return semantic_result
		return _halt_with_error(
			"Semantic scenario operation '%s' returned an invalid result"
			% action.get("operation", "")
		)
	if compatibility_instruction_registry == null:
		return _halt_with_error("Classic instruction registry is unavailable")
	var instruction := action.duplicate(true)
	instruction["kind"] = "classic"
	var raw_code := int(
		instruction.get("rawCode", instruction.get("code", 0))
	)
	instruction["code"] = normalize_opcode(raw_code)
	var handler := compatibility_instruction_registry.resolve(instruction)
	if handler != null and handler.has_method("execute_on_runtime"):
		var handler_result: Variant = handler.call(
			"execute_on_runtime",
			instruction,
			self
		)
		if handler_result is Dictionary:
			return handler_result
		return _halt_with_error(
			"Classic handler '%s' returned invalid opcode state"
			% handler.handler_id()
		)
	var code := int(instruction.get("code", 0))
	if bundle.is_dispatcher_noop(current_trigger, action):
		return _continue_result()
	halted = true
	last_error = "Unsupported Classic opcode %d at %s record %d slot %d" % [
		code,
		str(current_trigger.get("source", "unknown source")),
		int(current_trigger.get("recordIndex", -1)),
		int(action.get("slot", -1)),
	]
	return {
		"status": "unsupported",
		"message": last_error,
		"opcode": code,
		"action": action,
		"triggerId": _current_trigger_id(),
	}


func _execute_combat_monster_check(monster_name_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_combat_monster_check(
		monster_name_id
	)


func _execute_combat_revival() -> Dictionary:
	return _combat_opcode_runtime._execute_combat_revival()


func _execute_combatant_mutation(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_combatant_mutation(extra_code_id)


func _execute_combat_fumble(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_combat_fumble(extra_code_id)


func _execute_take_gold(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_take_gold(extra_code_id)


func _execute_give_condition(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_give_condition(extra_code_id)


func _execute_destroy_combat_monsters(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_destroy_combat_monsters(
		extra_code_id
	)


func _execute_deanimate_lower_undead(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_deanimate_lower_undead(
		extra_code_id
	)


func _execute_combat_rout(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_combat_rout(extra_code_id)


func _execute_spawn_combat_monsters(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_spawn_combat_monsters(
		extra_code_id
	)


func _execute_battle_round_macro(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_battle_round_macro(extra_code_id)


func _execute_load_shop(signed_shop_id: int, accept_ranges: Array = []) -> Dictionary:
	return _inventory_opcode_runtime._execute_load_shop(
		signed_shop_id,
		accept_ranges
	)


func _execute_shop_mutation(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_shop_mutation(extra_code_id)


func _execute_restricted_shop(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_restricted_shop(extra_code_id)


func _execute_item_possession_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _inventory_opcode_runtime._execute_item_possession_branch(
		extra_code_id,
		gosub
	)


func _execute_item_charge_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _inventory_opcode_runtime._execute_item_charge_branch(
		extra_code_id,
		gosub
	)


func _execute_item_mutation(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_item_mutation(extra_code_id)


func _execute_item_result_branch(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_item_result_branch(extra_code_id)


func _branch_item_possession_target(values: Array, target: int, gosub: bool) -> Dictionary:
	return _inventory_opcode_runtime._branch_item_possession_target(
		values,
		target,
		gosub
	)


func _item_texts_for_ids(item_ids: Array) -> Array:
	return _inventory_opcode_runtime._item_texts_for_ids(item_ids)


func _execute_battle(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_battle(extra_code_id)


func _execute_selective_battle(extra_code_id: int) -> Dictionary:
	return _combat_opcode_runtime._execute_selective_battle(extra_code_id)


func _execute_encounter(encounter_kind: String, encounter_id: int, start_slot := 0) -> Dictionary:
	return _encounter_opcode_runtime._execute_encounter(
		encounter_kind,
		encounter_id,
		start_slot
	)


func _yield_encounter(encounter_kind: String, encounter_id: int, start_slot: int) -> Dictionary:
	return _encounter_opcode_runtime._yield_encounter(
		encounter_kind,
		encounter_id,
		start_slot
	)


func _encounter_item_texts(encounter: Dictionary) -> Array:
	return _encounter_opcode_runtime._encounter_item_texts(encounter)


func _scenario_items() -> Array:
	return _encounter_opcode_runtime._scenario_items()


func _apply_encounter_state(encounter_context: Dictionary, encounter_state: Dictionary) -> Dictionary:
	return _encounter_opcode_runtime._apply_encounter_state(
		encounter_context,
		encounter_state
	)


func _thief_messages(thief_encounter: Dictionary) -> Array:
	return _encounter_opcode_runtime._thief_messages(thief_encounter)


func _eliminate_current_simple_option(option_index: int) -> Dictionary:
	if encounter_origins.is_empty():
		return _halt_with_error("Simple option mutation has no active encounter")
	var encounter_loop: Dictionary = encounter_origins[-1]
	if str(encounter_loop.get("encounterKind", "")) != "simple":
		return _halt_with_error("Simple option mutation is outside a simple encounter")
	var encounter_id := int(encounter_loop.get("encounterId", -1))
	var mutation_result := _eliminate_simple_encounter_option(encounter_id, option_index)
	if not mutation_result.is_empty():
		return mutation_result
	# Opcode 35 reopens the current encounter immediately without using an attempt.
	return _yield_encounter("simple", encounter_id, 0)


func _eliminate_simple_option_from_extra_code(extra_code_id: int) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.size() < 2:
		return _halt_with_error(
			"Simple option mutation references missing Extra Code row %d" % extra_code_id
		)
	var mutation_result := _eliminate_simple_encounter_option(
		int(values[0]),
		int(values[1])
	)
	return _continue_result() if mutation_result.is_empty() else mutation_result


func _eliminate_simple_encounter_option(encounter_id: int, option_index: int) -> Dictionary:
	if option_index < 1 or option_index > 4:
		return _halt_with_error("Simple encounter option index must be between 1 and 4")
	var encounter := bundle.get_encounter("simple", encounter_id)
	if encounter.is_empty():
		return _halt_with_error("Missing simple encounter record %d" % encounter_id)
	encounter = runtime_state.get_effective_simple_encounter(encounter)
	var choice_results: Variant = encounter.get("choiceResults", [])
	if not (choice_results is Array) or choice_results.size() < option_index:
		return _halt_with_error("Simple encounter %d has no option %d" % [
			encounter_id,
			option_index,
		])
	var updated_results: Array = choice_results.duplicate()
	updated_results[option_index - 1] = 0
	encounter["choiceResults"] = updated_results
	runtime_state.set_simple_encounter_override(encounter_id, encounter)
	return {}


func _eliminate_complex_result(result_index: int) -> Dictionary:
	if encounter_origins.is_empty():
		return _halt_with_error("Complex result mutation has no active encounter")
	var encounter_loop: Dictionary = encounter_origins[-1]
	if str(encounter_loop.get("encounterKind", "")) != "complex":
		return _halt_with_error("Complex result mutation is outside a complex encounter")
	if result_index < 1 or result_index > 4:
		return _halt_with_error("Complex result mutation index must be between 1 and 4")
	var encounter_id := int(encounter_loop.get("encounterId", -1))
	var encounter := runtime_state.get_effective_complex_encounter(
		bundle.get_encounter("complex", encounter_id)
	)
	var source_actions: Variant = encounter.get("actions", [])
	if not (source_actions is Array):
		return _halt_with_error("Complex encounter has no action array to mutate")
	var first_slot := (result_index - 1) * 8
	var actions: Array = []
	for action_value: Variant in source_actions:
		if not (action_value is Dictionary):
			continue
		var slot := int(action_value.get("slot", -1))
		if slot < first_slot or slot >= first_slot + 8:
			actions.append(action_value.duplicate(true))
	actions.append({"id": 0, "rawCode": 24, "slot": first_slot + 7})
	actions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("slot", -1)) < int(b.get("slot", -1))
	)
	encounter["actions"] = actions
	runtime_state.set_complex_encounter_override(encounter_id, encounter)
	return _continue_result()


func _execute_treasure(treasure_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_treasure(treasure_id)


func _execute_currency_clear(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_currency_clear(extra_code_id)


func _execute_random_items(extra_code_id: int) -> Dictionary:
	return _inventory_opcode_runtime._execute_random_items(extra_code_id)


func _execute_spellcasting_flags(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_spellcasting_flags(
		extra_code_id
	)


func _execute_selected_character_mutation(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_selected_character_mutation(
		extra_code_id
	)


func _execute_fatigue_mutation(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_fatigue_mutation(
		extra_code_id
	)


func _execute_character_pick(record_id: int, invert: bool) -> Dictionary:
	return _character_opcode_runtime._execute_character_pick(
		record_id,
		invert
	)


func _execute_character_check_selection(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_character_check_selection(
		extra_code_id
	)


func _execute_character_ability_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _character_opcode_runtime._execute_character_ability_branch(
		extra_code_id,
		gosub
	)


func _execute_identity_character_selection(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_identity_character_selection(
		extra_code_id
	)


func _execute_caste_character_selection(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_caste_character_selection(
		extra_code_id
	)


func _execute_misc_character_selection(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_misc_character_selection(
		extra_code_id
	)


func _execute_selected_health_effect(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_selected_health_effect(
		extra_code_id
	)


func _execute_party_health_effect(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_party_health_effect(
		extra_code_id
	)


func _execute_spell_effect(extra_code_id: int, target_party: bool) -> Dictionary:
	return _character_opcode_runtime._execute_spell_effect(
		extra_code_id,
		target_party
	)


func _execute_health_effect(extra_code_id: int, command: String) -> Dictionary:
	return _character_opcode_runtime._execute_health_effect(
		extra_code_id,
		command
	)


func _execute_player_map(signed_map_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_player_map(signed_map_id)


func _execute_scrolling_text(resource_id: int) -> Dictionary:
	return _presentation_opcode_runtime._execute_scrolling_text(
		resource_id
	)


func _execute_random_rectangle_mutation(extra_code_id: int, dungeon: bool) -> Dictionary:
	return _map_time_opcode_runtime._execute_random_rectangle_mutation(
		extra_code_id,
		dungeon
	)


func _execute_random_rectangle_bounds(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_random_rectangle_bounds(
		extra_code_id
	)


func _execute_action_data_patch(extra_code_id: int) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Action data patch references missing Extra Code row %d" % extra_code_id
		)
	var source_id := int(values[2])
	var source := bundle.get_extra_action_point(source_id)
	if source.is_empty():
		return _halt_with_error("Action data patch references missing Data ED3 row %d" % source_id)
	match int(values[0]):
		-1:
			return _patch_encounter_result("simple", int(values[1]), int(values[4]), source)
		-2:
			return _patch_encounter_result("complex", int(values[1]), int(values[4]), source)
		_:
			return _patch_map_action_point(values, source)


func _execute_timed_encounter_mutation(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_timed_encounter_mutation(
		extra_code_id
	)


func _patch_map_action_point(values: Array, source: Dictionary) -> Dictionary:
	var level_kind := runtime_state.level_type
	var level_selector := int(values[3])
	if level_selector != 0:
		level_kind = "land" if level_selector == 1 else "dungeon"
	var map_level := int(values[0])
	var record_index := int(values[1])
	var target := _effective_map_action_point(level_kind, map_level, record_index)
	if target.is_empty():
		return _halt_with_error("Missing %s map action point %d:%d" % [
			level_kind,
			map_level,
			record_index,
		])
	target["actions"] = source.get("actions", []).duplicate(true)
	runtime_state.set_action_point_override(str(target.get("id", "")), target)
	return _continue_result()


func _patch_encounter_result(
	encounter_kind: String,
	encounter_id: int,
	result_index: int,
	source: Dictionary
) -> Dictionary:
	if result_index < 0 or result_index > 3:
		return _halt_with_error("Classic encounter result index must be between 0 and 3")
	var encounter := bundle.get_encounter(encounter_kind, encounter_id)
	if encounter.is_empty():
		return _halt_with_error("Missing %s encounter record %d" % [
			encounter_kind,
			encounter_id,
		])
	if encounter_kind == "simple":
		encounter = runtime_state.get_effective_simple_encounter(encounter)
	else:
		encounter = runtime_state.get_effective_complex_encounter(encounter)
	var encounter_actions: Variant = encounter.get("actions", [])
	var source_actions: Variant = source.get("actions", [])
	if not (encounter_actions is Array) or not (source_actions is Array):
		return _halt_with_error("Action data patch source or target has no action array")
	encounter["actions"] = _replace_encounter_result_actions(
		encounter_actions,
		source_actions,
		result_index
	)
	if encounter_kind == "simple":
		runtime_state.set_simple_encounter_override(encounter_id, encounter)
	else:
		runtime_state.set_complex_encounter_override(encounter_id, encounter)
	return _continue_result()


func _replace_encounter_result_actions(
	encounter_actions: Array,
	source_actions: Array,
	result_index: int
) -> Array:
	var first_slot := result_index * 8
	var actions: Array = []
	for action_value: Variant in encounter_actions:
		if not (action_value is Dictionary):
			continue
		var slot := int(action_value.get("slot", -1))
		if slot < first_slot or slot >= first_slot + 8:
			actions.append(action_value.duplicate(true))
	for action_value: Variant in source_actions:
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value.duplicate(true)
		action["slot"] = first_slot + int(action.get("slot", 0))
		actions.append(action)
	actions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("slot", -1)) < int(b.get("slot", -1))
	)
	return actions


func _execute_same_as_other_action_point(record_index: int) -> Dictionary:
	var target := _effective_map_action_point(
		runtime_state.level_type,
		runtime_state.level_index,
		record_index
	)
	if target.is_empty():
		return _halt_with_error("Missing same-map action point %d" % record_index)
	var percent := int(active_action_point_header.get(
		"percent",
		current_trigger.get("percent", 0)
	))
	# Classic copies only the other door's CODE/ID slots, then re-enters moveon
	# with the active door's header and percentage still in place.
	var replacement := current_trigger.duplicate(true)
	replacement["actions"] = target.get("actions", []).duplicate(true)
	_set_cursor(replacement, 0)
	if percent < 1 or _roll_percent() > percent:
		_clear_control_flow()
		return _completed_result("same-door-percent-miss")
	return _continue_result()


func _execute_tile_mutation(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_tile_mutation(extra_code_id)


func _execute_trigger_mutation(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_trigger_mutation(extra_code_id)


func _execute_random_text(extra_code_id: int) -> Dictionary:
	return _presentation_opcode_runtime._execute_random_text(
		extra_code_id
	)


func _execute_priest_turning(enabled: bool) -> Dictionary:
	return _combat_opcode_runtime._execute_priest_turning(enabled)


func _execute_battle_outcome(extra_code_id: int, gosub: bool) -> Dictionary:
	return _combat_opcode_runtime._execute_battle_outcome(
		extra_code_id,
		gosub
	)


func _execute_improved_selective_battle(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	return _combat_opcode_runtime._execute_improved_selective_battle(
		extra_code_id,
		gosub
	)


func _execute_choice(extra_code_id: int, gosub: bool) -> Dictionary:
	return _encounter_opcode_runtime._execute_choice(
		extra_code_id,
		gosub
	)


func _execute_teleport(extra_code_id: int, recheck_destination: bool) -> Dictionary:
	return _map_time_opcode_runtime._execute_teleport(
		extra_code_id,
		recheck_destination
	)


func _execute_dungeon_move(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_dungeon_move(extra_code_id)


func _execute_look_direction(requested_heading: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_look_direction(
		requested_heading
	)


func _execute_compass(enabled: bool) -> Dictionary:
	return _map_time_opcode_runtime._execute_compass(enabled)


func _execute_map_view_mode(allow_map: bool) -> Dictionary:
	return _map_time_opcode_runtime._execute_map_view_mode(allow_map)


func _execute_darkland(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_darkland(extra_code_id)


func _execute_landlook(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_landlook(extra_code_id)


func _execute_position_shift(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_position_shift(extra_code_id)


func _execute_saved_position(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_saved_position(extra_code_id)


func _execute_time_mutation(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_time_mutation(extra_code_id)


func _execute_time_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Game-time branch references missing Extra Code row %d" % extra_code_id
		)
	if not execution_context.has("scenarioDay") \
			or not execution_context.has("scenarioHour"):
		return _halt_with_error(
			"Game-time branch %d requires the current scenario day and hour" % extra_code_id
		)
	var day := int(execution_context["scenarioDay"])
	var hour := int(execution_context["scenarioHour"])
	var latest_day := int(values[0])
	var latest_hour := int(values[1])
	# Classic compares the authored hour directly, and shipped scenarios use 24
	# as an inclusive end-of-day limit.
	if latest_day < -1 or latest_hour < -1 or latest_hour > 24:
		return _halt_with_error(
			"Game-time branch %d has an invalid day or hour limit" % extra_code_id
		)
	var within_time := (latest_day == -1 or day <= latest_day) \
		and (latest_hour == -1 or hour <= latest_hour)
	return _branch_to_extra_action_point(
		int(values[3] if within_time else values[4]),
		gosub,
		0
	)


func _execute_exploration_status(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_exploration_status(
		extra_code_id
	)


func _remove_current_action_point() -> Dictionary:
	remove_action_point = true
	removal_x = runtime_state.x
	removal_y = runtime_state.y
	call_stack.clear()
	gosub_active = false
	encounter_origins.clear()
	return _continue_result()


func _finish_action_point(reason: String, consume_codes: bool) -> Dictionary:
	if reason == "action-point-ended" and not remove_action_point:
		var repeated_encounter := _repeat_encounter_after_fallthrough()
		if not repeated_encounter.is_empty():
			return repeated_encounter
	if remove_action_point and not origin_action_point.is_empty():
		_persist_removed_action_point(consume_codes)
	elif consume_codes and not origin_action_point.is_empty():
		_set_origin_action_point_percent(-1)
	var destination_result := _action_point_destination_result(reason)
	if not destination_result.is_empty():
		return destination_result
	_clear_control_flow()
	return _completed_result(reason)


func _action_point_destination_result(reason: String) -> Dictionary:
	if origin_action_point.is_empty() or suppress_action_point_destination:
		return {}
	var source_level := int(origin_action_point.get(
		"levelIndex",
		runtime_state.level_index
	))
	var source_coordinate: Variant = origin_action_point.get("coordinate", {})
	var source_x := runtime_state.x
	var source_y := runtime_state.y
	if source_coordinate is Dictionary:
		source_x = int(source_coordinate.get("x", source_x))
		source_y = int(source_coordinate.get("y", source_y))
	var destination_level := int(active_action_point_header.get("landid", source_level))
	var destination_x := int(active_action_point_header.get("targetX", source_x))
	var destination_y := int(active_action_point_header.get("targetY", source_y))
	if destination_level == source_level \
			and destination_x == source_x \
			and destination_y == source_y:
		return {}
	if destination_level == runtime_state.level_index \
			and destination_x == runtime_state.x \
			and destination_y == runtime_state.y:
		return {}

	runtime_state.set_position(destination_level, destination_x, destination_y)
	pending_teleport = {
		"recheckDestination": true,
		"completionReason": reason,
	}
	return _yield_result("teleport", {
		"levelType": runtime_state.level_type,
		"levelIndex": runtime_state.level_index,
		"x": runtime_state.x,
		"y": runtime_state.y,
		"soundId": 0,
		"messageId": 0,
		"message": {},
		"recheckDestination": true,
		"actionPointDestination": true,
	})


func _repeat_encounter_after_fallthrough() -> Dictionary:
	if encounter_origins.is_empty():
		return {}
	var encounter_loop: Dictionary = encounter_origins[-1]
	encounter_loop["remainingAttempts"] = int(
		encounter_loop.get("remainingAttempts", 1)
	) - 1
	encounter_origins[-1] = encounter_loop
	if int(encounter_loop["remainingAttempts"]) <= 0:
		return {}
	# Classic repeats only when a result block falls through. Opcodes 24 and 25
	# clear the encounter flag before reaching this point and therefore terminate.
	return _yield_encounter(
		str(encounter_loop.get("encounterKind", "")),
		int(encounter_loop.get("encounterId", -1)),
		0
	)


func _persist_removed_action_point(consume_codes: bool) -> void:
	var level_kind := str(origin_action_point.get("levelType", runtime_state.level_type))
	var record_index := int(origin_action_point.get("recordIndex", -1))
	if consume_codes and record_index >= 0:
		_set_origin_action_point_percent(-1)

	var destination_level := int(active_action_point_header.get("landid", runtime_state.level_index))
	var destination_x := int(active_action_point_header.get("targetX", runtime_state.x))
	var destination_y := int(active_action_point_header.get("targetY", runtime_state.y))
	var changes_position := (
		destination_level != runtime_state.level_index
		or destination_x != runtime_state.x
		or destination_y != runtime_state.y
	)
	if not changes_position or record_index < 0:
		return

	# Classic loads the destination map before writing door[doornum], so a
	# cross-level removal replaces the same record slot on that map.
	runtime_state.set_position(destination_level, destination_x, destination_y)
	var replacement := active_action_point_header.duplicate(true)
	replacement["actions"] = current_trigger.get("actions", []).duplicate(true)
	replacement["targetX"] = removal_x
	replacement["targetY"] = removal_y
	replacement["source"] = "Data DDD" if level_kind == "dungeon" else "Data DD"
	replacement["levelType"] = level_kind
	replacement["levelIndex"] = destination_level
	replacement["recordIndex"] = record_index
	replacement["id"] = _map_action_point_id(level_kind, destination_level, record_index)
	replacement["coordinate"] = _coordinate_from_door_id(
		int(replacement.get("doorid", 0)),
		destination_level
	)
	replacement["active"] = (
		int(replacement.get("percent", 0)) >= 1
		and replacement.get("coordinate") is Dictionary
	)
	if consume_codes:
		runtime_state.set_trigger_percent(level_kind, destination_level, record_index, -1)
	runtime_state.set_action_point_override(str(replacement["id"]), replacement)


func _set_origin_action_point_percent(percent: int) -> void:
	if origin_action_point.is_empty():
		return
	var record_index := int(origin_action_point.get("recordIndex", -1))
	if record_index < 0:
		return
	var level_kind := str(origin_action_point.get("levelType", runtime_state.level_type))
	var source_level := int(origin_action_point.get("levelIndex", runtime_state.level_index))
	runtime_state.set_trigger_percent(level_kind, source_level, record_index, percent)
	active_action_point_header["percent"] = percent


func _map_action_point_id(level_kind: String, level: int, record_index: int) -> String:
	var source := "Data DDD" if level_kind == "dungeon" else "Data DD"
	return "%s:%d:%d" % [source, level, record_index]


func _effective_map_action_point(level_kind: String, level: int, record_index: int) -> Dictionary:
	var trigger_id := _map_action_point_id(level_kind, level, record_index)
	var action_point := runtime_state.get_action_point_override(trigger_id)
	if action_point.is_empty():
		action_point = bundle.get_trigger(trigger_id)
	return runtime_state.get_effective_action_point(action_point) if not action_point.is_empty() else {}


func _coordinate_from_door_id(door_id: int, level: int) -> Variant:
	if door_id <= 0 or floori(float(door_id) / 10000.0) != level:
		return null
	var packed_position := door_id % 10000
	return {
		"x": packed_position % 100,
		"y": floori(float(packed_position) / 100.0),
	}


func _is_map_action_point(action_point: Dictionary) -> bool:
	return str(action_point.get("source", "")) in ["Data DD", "Data DDD"]


func _execute_party_condition_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _character_opcode_runtime._execute_party_condition_branch(
		extra_code_id,
		gosub
	)


func _execute_selected_count_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _character_opcode_runtime._execute_selected_count_branch(
		extra_code_id,
		gosub
	)


func _execute_character_condition_branch(
	extra_code_id: int,
	gosub: bool
) -> Dictionary:
	return _character_opcode_runtime._execute_character_condition_branch(
		extra_code_id,
		gosub
	)


func _execute_misc_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _character_opcode_runtime._execute_misc_branch(
		extra_code_id,
		gosub
	)


func _execute_ally_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _character_opcode_runtime._execute_ally_branch(
		extra_code_id,
		gosub
	)


func _execute_remove_ally(monster_name_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_remove_ally(monster_name_id)


func _execute_add_ally(monster_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_add_ally(monster_id)


func _resume_ally_branch(values: Array, target_id: int, ally_check: Dictionary) -> Dictionary:
	return _character_opcode_runtime._resume_ally_branch(
		values,
		target_id,
		ally_check
	)


func _execute_random_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Random branch references missing Extra Code row %d" % extra_code_id
		)
	var target_mode := int(values[0])
	if target_mode < 0 or target_mode > 2:
		return _halt_with_error("Random branch has invalid target mode %d" % target_mode)
	var first_target := int(values[1])
	var last_target := int(values[2])
	if last_target < first_target:
		return _halt_with_error(
			"Random branch target range %d-%d is reversed" % [first_target, last_target]
		)
	var random_branch := {
		"targetMode": target_mode,
		"targetId": randi_range(first_target, last_target),
		"gosub": gosub,
	}
	var sound_id := int(values[3])
	var message_id := int(values[4])
	if sound_id == 0 and message_id == 0:
		return _apply_random_branch(random_branch)
	pending_random_branch = random_branch
	return _yield_result("present_random_branch", {
		"extraCodeId": extra_code_id,
		"targetMode": target_mode,
		"targetRange": [first_target, last_target],
		"targetId": int(random_branch["targetId"]),
		"soundId": sound_id,
		"messageId": message_id,
		"message": bundle.get_message(message_id),
	})


func _apply_random_branch(random_branch: Dictionary) -> Dictionary:
	var branch_result := _branch_to_action_or_encounter(
		int(random_branch["targetMode"]),
		int(random_branch["targetId"]),
		bool(random_branch.get("gosub", false))
	)
	if str(branch_result.get("status", "")) != "continue":
		return branch_result
	return run_until_yield()


func _branch_to_action_or_encounter(target_mode: int, target_id: int, gosub: bool) -> Dictionary:
	match target_mode:
		0:
			return _branch_to_extra_action_point(target_id, gosub, 0)
		1, 2:
			if gosub:
				var push_result := _push_call_frame()
				if str(push_result.get("status", "")) != "continue":
					return push_result
			return _execute_encounter("simple" if target_mode == 1 else "complex", target_id)
		_:
			return _halt_with_error("Unsupported classic branch target mode %d" % target_mode)


func _execute_quest_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error("Quest branch references missing Extra Code row %d" % extra_code_id)
	var quest_is_set := runtime_state.is_quest_set(int(values[0]))
	var condition := int(values[1])
	var should_branch := condition == 2 or (condition == 1 and quest_is_set) or (condition == 0 and not quest_is_set)
	if not should_branch:
		return _continue_result()
	return _branch_from_extra_code(values, gosub)


func _execute_quest_value_mutation(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Quest-value mutation references missing Extra Code row %d" % extra_code_id
		)
	var quest_id := int(values[0])
	if quest_id < 0 or quest_id >= 100:
		return _halt_with_error("Classic quest index %d is outside 0 through 99" % quest_id)
	var quest_value := runtime_state.adjust_quest_value(quest_id, int(values[1]))
	var threshold := int(values[3])
	if threshold == 0 or quest_value < threshold:
		return _continue_result()
	var target_mode := int(values[2]) - 1
	if target_mode < 0 or target_mode > 2:
		return _halt_with_error(
			"Quest-value mutation has invalid branch mode %d" % int(values[2])
		)
	return _branch_to_action_or_encounter(
		target_mode,
		int(values[4]),
		gosub
	)


func _execute_quest_value_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Quest-value branch references missing Extra Code row %d" % extra_code_id
		)
	var quest_id := int(values[0])
	if quest_id < 0 or quest_id >= 100:
		return _halt_with_error("Classic quest index %d is outside 0 through 99" % quest_id)
	var threshold_met := runtime_state.get_quest_value(quest_id) >= int(values[1])
	var target_id := int(values[4] if threshold_met else values[3])
	if target_id == 0:
		return _continue_result()
	var target_mode := int(values[2])
	if target_mode < 0 or target_mode > 2:
		return _halt_with_error(
			"Quest-value branch has invalid branch mode %d" % target_mode
		)
	return _branch_to_action_or_encounter(target_mode, target_id, gosub)


func _execute_quest_range_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.size() < 5:
		return _halt_with_error(
			"Quest-range branch references malformed Extra Code row %d"
			% extra_code_id
		)
	var first_quest := int(values[0])
	var last_quest := int(values[1])
	if first_quest < 0 or last_quest < first_quest or last_quest >= 100:
		return _halt_with_error(
			"Quest-range branch has invalid range %d through %d"
			% [first_quest, last_quest]
		)
	for quest_id: int in range(first_quest, last_quest + 1):
		if not runtime_state.is_quest_set(quest_id):
			return _continue_result()
	var target_mode := int(values[3])
	if target_mode < 0 or target_mode > 2:
		return _halt_with_error(
			"Quest-range branch has invalid target mode %d" % target_mode
		)
	return _branch_to_action_or_encounter(
		target_mode,
		int(values[4]),
		gosub
	)


func _execute_tile_parameter_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Tile-parameter branch references missing Extra Code row %d" % extra_code_id
		)
	var selector := int(values[0])
	var look_offset: Variant = execution_context.get("lookOffset", {})
	var look_x := int(look_offset.get("x", 0)) if look_offset is Dictionary else 0
	var look_y := int(look_offset.get("y", 0)) if look_offset is Dictionary else 0
	var tile_x := runtime_state.x + look_x
	var tile_y := runtime_state.y + look_y
	var tile_record := bundle.get_map_tile(
		runtime_state.level_type,
		runtime_state.level_index,
		tile_x,
		tile_y
	)
	if tile_record.is_empty():
		return _halt_with_error(
			"Tile-parameter branch cannot resolve the current map field"
		)
	var raw_tile := runtime_state.get_tile(
		runtime_state.level_type,
		runtime_state.level_index,
		tile_x,
		tile_y,
		int(tile_record.get("value", 0))
	)
	var tile_id := MapBridgeScript.normalize_tile_parameter_id(raw_tile)
	var matches := tile_id == int(values[1]) if selector == 7 else false
	var landlook := -1
	var attribute: Dictionary = {}
	if selector >= 1 and selector <= 6:
		var map: Dictionary = tile_record.get("map", {})
		var render: Variant = map.get("render", {})
		var baseline_landlook := int(render.get("landlook", -1)) \
			if render is Dictionary else -1
		landlook = runtime_state.get_landlook(
			runtime_state.level_type,
			runtime_state.level_index,
			baseline_landlook
		)
		attribute = bundle.get_land_tile_attribute(landlook, tile_id)
		if attribute.is_empty():
			return _halt_with_error(
				"Tile-parameter branch cannot resolve tile %d attributes for landlook %d"
				% [tile_id, landlook]
			)
		matches = _tile_parameter_is_set(attribute, selector)
	var target_id := int(values[4] if matches else values[3])
	if target_id == 0:
		return _continue_result()
	var target_mode := int(values[2])
	if target_mode < 0 or target_mode > 2:
		return _halt_with_error(
			"Tile-parameter branch has invalid branch mode %d" % target_mode
		)
	return _branch_to_action_or_encounter(target_mode, target_id, gosub)


func _tile_parameter_is_set(attribute: Dictionary, selector: int) -> bool:
	match selector:
		1:
			return int(attribute.get("shore", 0)) != 0
		2:
			return int(attribute.get(
				"boatRequirement",
				attribute.get("needBoat", 0)
			)) != 0
		3:
			return int(attribute.get("pathFlag", attribute.get("isPath", 0))) != 0
		4:
			return int(attribute.get("blocksLos", attribute.get("los", 0))) != 0
		5:
			return int(attribute.get(
				"flyFloatRequired",
				attribute.get("flyFloat", 0)
			)) != 0
		6:
			return int(attribute.get("forestType", attribute.get("forest", 0))) != 0
	return false


func _execute_experience_loss(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_experience_loss(extra_code_id)


func _execute_percent_branch(extra_code_id: int) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Percent branch references missing Extra Code row %d" % extra_code_id
		)
	var roll := _roll_percent()
	if roll < 1 or roll > 100:
		return _halt_with_error("Percent roll provider returned %d; expected 1 through 100" % roll)
	if roll > int(values[0]):
		return _continue_result()
	return _apply_force_branch_success(values)


func _execute_difficulty_branch(extra_code_id: int) -> Dictionary:
	var values := _extra_code_values(extra_code_id)
	if values.is_empty():
		return _halt_with_error(
			"Difficulty branch references missing Extra Code row %d" % extra_code_id
		)
	if runtime_state.difficulty < int(values[0]):
		return _continue_result()
	return _apply_force_branch_success(values)


func _apply_force_branch_success(values: Array) -> Dictionary:
	match int(values[1]):
		-2:
			return _finish_conditional_branch("dropout-and-erase", true)
		1:
			# Percent and difficulty branches do not push GOSUB in Classic.
			return _branch_from_extra_code(values, false)
		2:
			return _finish_conditional_branch("keep-codes", false)
		_:
			return _continue_result()


func _roll_percent() -> int:
	if percent_roll_provider.is_valid():
		return int(percent_roll_provider.call())
	return randi_range(1, 100)


func _finish_conditional_branch(reason: String, consume_codes: bool) -> Dictionary:
	var in_encounter := not encounter_origins.is_empty()
	if consume_codes and not in_encounter:
		_set_origin_action_point_percent(-1)
	if in_encounter:
		var repeated_encounter := _repeat_encounter_after_fallthrough()
		if not repeated_encounter.is_empty():
			return repeated_encounter
	_clear_control_flow()
	return _completed_result(reason)


func _branch_from_extra_code(values: Array, gosub: bool) -> Dictionary:
	if gosub:
		var push_result := _push_call_frame()
		if str(push_result.get("status", "")) != "continue":
			return push_result
	match int(values[2]):
		-1:
			_set_cursor(current_trigger, 7)
			return _continue_result()
		0:
			return _branch_to_extra_action_point(int(values[3]), false, 0)
		1, 2:
			return _branch_to_loaded_encounter_result(
				"simple" if int(values[2]) == 1 else "complex",
				int(values[3]),
				int(values[4])
			)
		3:
			return _finish_action_point("keep-codes", false)
		_:
			return _halt_with_error("Unsupported classic branch mode %d" % int(values[2]))


func _branch_to_loaded_encounter_result(
	encounter_kind: String,
	result_index: int,
	start_slot: int
) -> Dictionary:
	if result_index < 0 or result_index > 3:
		return _halt_with_error("Classic encounter result index must be between 0 and 3")
	# Classic keeps the most recently loaded simple and complex records in
	# separate buffers. A nested encounter can therefore branch back into its
	# enclosing record without starting another encounter.
	var encounter_id := (
		loaded_simple_encounter_id
		if encounter_kind == "simple"
		else loaded_complex_encounter_id
	)
	if encounter_id < 0:
		# Both Classic buffers are zeroed before their first load.
		_set_cursor({
			"id": "%s encounter:unloaded:outcome:%d" % [encounter_kind, result_index + 1],
			"actions": [],
		}, start_slot)
		return _continue_result()
	var encounter := bundle.get_encounter(encounter_kind, encounter_id)
	if encounter.is_empty():
		return _halt_with_error(
			"Missing loaded %s encounter record %d" % [encounter_kind, encounter_id]
		)
	if encounter_kind == "simple":
		encounter = runtime_state.get_effective_simple_encounter(encounter)
	else:
		encounter = runtime_state.get_effective_complex_encounter(encounter)
	var target := _encounter_outcome_trigger(
		encounter_kind,
		encounter_id,
		encounter,
		result_index + 1
	)
	if target.is_empty():
		return _halt_with_error("Classic encounter has no action array")
	_set_cursor(target, start_slot)
	return _continue_result()


func _branch_to_extra_action_point(record_id: int, gosub: bool, start_slot: int) -> Dictionary:
	var target := bundle.get_extra_action_point(record_id)
	if target.is_empty():
		return _halt_with_error("Missing Data ED3 action point %d" % record_id)
	if gosub:
		var push_result := _push_call_frame()
		if str(push_result.get("status", "")) != "continue":
			return push_result
	_set_cursor(target, start_slot)
	return _continue_result()


func _push_call_frame() -> Dictionary:
	if call_stack.size() >= MAX_CALL_STACK_DEPTH:
		return _halt_with_error(
			"Classic GOSUB stack exceeded %d frames" % MAX_CALL_STACK_DEPTH
		)
	call_stack.append({
		"trigger": current_trigger,
		"actionIndex": current_action_index,
		"actionPointHeader": active_action_point_header.duplicate(true),
	})
	return _continue_result()


func _set_cursor(trigger: Dictionary, start_slot: int) -> void:
	current_trigger = trigger
	current_action_index = 0
	var actions: Variant = trigger.get("actions", [])
	if not (actions is Array):
		return
	while current_action_index < actions.size():
		var action: Variant = actions[current_action_index]
		if action is Dictionary and int(action.get("slot", -1)) >= start_slot:
			break
		current_action_index += 1


func _encounter_outcome_trigger(
	encounter_kind: String,
	encounter_id: int,
	encounter: Dictionary,
	outcome: int
) -> Dictionary:
	var encounter_actions: Variant = encounter.get("actions", [])
	if not (encounter_actions is Array):
		return {}
	var first_slot := (outcome - 1) * 8
	var actions: Array = []
	for action_value: Variant in encounter_actions:
		if not (action_value is Dictionary):
			continue
		var slot := int(action_value.get("slot", -1))
		if slot < first_slot or slot >= first_slot + 8:
			continue
		var action: Dictionary = action_value.duplicate(true)
		var raw_code := int(action.get("rawCode", 0))
		action["code"] = normalize_opcode(raw_code)
		action["gosub"] = raw_code < 0 and raw_code not in [-14, -23]
		action["slot"] = slot - first_slot
		actions.append(action)
	return {
		"id": "%s encounter:%d:outcome:%d" % [encounter_kind, encounter_id, outcome],
		"source": "Data ED" if encounter_kind == "simple" else "Data ED2",
		"recordIndex": encounter_id,
		"actions": actions,
	}


func _break_encounter() -> Dictionary:
	if encounter_origins.is_empty():
		return _halt_with_error("Break encounter loop has no active encounter")
	var origin: Dictionary = encounter_origins.pop_back()
	current_trigger = origin["trigger"]
	current_action_index = int(origin["actionIndex"])
	call_stack = origin["callStack"]
	active_action_point_header = origin["actionPointHeader"]
	return _continue_result()


func _restore_call_frame() -> void:
	var frame: Dictionary = call_stack.pop_back()
	current_trigger = frame["trigger"]
	current_action_index = int(frame["actionIndex"])
	active_action_point_header = frame["actionPointHeader"]


func _update_gosub_state(action: Dictionary) -> void:
	# Classic keeps GOSUB active across positive actions while a call frame exists.
	if bool(action.get("gosub", false)):
		gosub_active = true
	elif call_stack.is_empty():
		gosub_active = false


func _clear_control_flow() -> void:
	current_trigger = {}
	current_action_index = 0
	origin_action_point.clear()
	active_action_point_header.clear()
	suppress_action_point_destination = false
	remove_action_point = false
	removal_x = 0
	removal_y = 0
	call_stack.clear()
	gosub_active = false
	encounter_origins.clear()


func _extra_code_values(record_id: int) -> Array:
	var row := bundle.get_extra_code(record_id)
	if row.is_empty():
		return []
	var values: Variant = row.get("values", [])
	if not (values is Array) or values.size() < 5:
		return []
	return values


func _current_trigger_id() -> String:
	return str(current_trigger.get("id", ""))


func _continue_result() -> Dictionary:
	return {"status": "continue"}


func _yield_result(command: String, payload: Dictionary) -> Dictionary:
	return {
		"status": "yield",
		"command": command,
		"payload": payload,
		"_scenarioContinuation": pending_continuation.duplicate(true),
		"triggerId": _current_trigger_id(),
	}


func _completed_result(reason: String) -> Dictionary:
	return {
		"status": "completed",
		"reason": reason,
	}


func _error_result(message: String) -> Dictionary:
	return {
		"status": "error",
		"message": message,
	}


func _halt_with_error(message: String) -> Dictionary:
	last_error = message
	halted = true
	return _error_result(message)
