class_name ClassicOpcodeRuntime
extends RefCounted

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
const ControlFlowOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_control_flow_opcode_runtime.gd"
)
const ClassicExecutionStateScript = preload(
	"res://scripts/scenario_runtime/classic_execution_state.gd"
)
const RulesStateOpcodeRuntimeScript = preload(
	"res://scripts/scenario_runtime/handlers/classic_rules_state_opcode_runtime.gd"
)
const MAX_CALL_STACK_DEPTH := 20
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
var _execution_state: RefCounted = \
	ClassicExecutionStateScript.new()
var current_trigger: Dictionary:
	get:
		return _execution_state.current_trigger
	set(value):
		_execution_state.current_trigger = value
var current_action_index: int:
	get:
		return _execution_state.current_action_index
	set(value):
		_execution_state.current_action_index = value
var origin_action_point: Dictionary:
	get:
		return _execution_state.origin_action_point
	set(value):
		_execution_state.origin_action_point = value
var active_action_point_header: Dictionary:
	get:
		return _execution_state.active_action_point_header
	set(value):
		_execution_state.active_action_point_header = value
var suppress_action_point_destination: bool:
	get:
		return _execution_state.suppress_action_point_destination
	set(value):
		_execution_state.suppress_action_point_destination = value
var remove_action_point: bool:
	get:
		return _execution_state.remove_action_point
	set(value):
		_execution_state.remove_action_point = value
var removal_x: int:
	get:
		return _execution_state.removal_x
	set(value):
		_execution_state.removal_x = value
var removal_y: int:
	get:
		return _execution_state.removal_y
	set(value):
		_execution_state.removal_y = value
var call_stack: Array:
	get:
		return _execution_state.call_stack
	set(value):
		_execution_state.call_stack = value
var gosub_active: bool:
	get:
		return _execution_state.gosub_active
	set(value):
		_execution_state.gosub_active = value
# Classic mechanics expose these views while older focused fixtures still call
# the typed resume helpers. The only stored continuation is pending_continuation;
# ScenarioInterpreter serializes it into ScenarioPendingCommand.
var pending_continuation: Dictionary:
	get:
		return _execution_state.pending_continuation
	set(value):
		_execution_state.pending_continuation = value
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
var execution_context: Dictionary:
	get:
		return _execution_state.execution_context
	set(value):
		_execution_state.execution_context = value
var encounter_origins: Array:
	get:
		return _execution_state.encounter_origins
	set(value):
		_execution_state.encounter_origins = value
var loaded_simple_encounter_id: int:
	get:
		return _execution_state.loaded_simple_encounter_id
	set(value):
		_execution_state.loaded_simple_encounter_id = value
var loaded_complex_encounter_id: int:
	get:
		return _execution_state.loaded_complex_encounter_id
	set(value):
		_execution_state.loaded_complex_encounter_id = value
var percent_roll_provider: Callable
var scenario_run_delegate: Callable
var trace: Array:
	get:
		return _execution_state.trace
	set(value):
		_execution_state.trace = value
var last_error: String:
	get:
		return _execution_state.last_error
	set(value):
		_execution_state.last_error = value
var halted: bool:
	get:
		return _execution_state.halted
	set(value):
		_execution_state.halted = value
var _combat_opcode_runtime: RefCounted
var _inventory_opcode_runtime: RefCounted
var _character_opcode_runtime: RefCounted
var _map_time_opcode_runtime: RefCounted
var _encounter_opcode_runtime: RefCounted
var _presentation_opcode_runtime: RefCounted
var _control_flow_opcode_runtime: RefCounted
var _rules_state_opcode_runtime: RefCounted


func bind_execution_state(state: RefCounted) -> void:
	if state != null:
		_execution_state = state


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
	if _control_flow_opcode_runtime == null:
		_control_flow_opcode_runtime = ControlFlowOpcodeRuntimeScript.new()
		_control_flow_opcode_runtime.configure(self)
	if _rules_state_opcode_runtime == null:
		_rules_state_opcode_runtime = RulesStateOpcodeRuntimeScript.new()
		_rules_state_opcode_runtime.configure(self)
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
	if handler_id == "core.control-flow":
		return _control_flow_opcode_runtime
	if handler_id == "core.rules-state":
		return _rules_state_opcode_runtime
	return self


func set_percent_roll_provider(provider: Callable) -> void:
	percent_roll_provider = provider


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
	_execution_state.reset()


func make_execution_snapshot() -> Dictionary:
	return _execution_state.make_snapshot()


func restore_execution_snapshot(snapshot: Variant) -> Dictionary:
	return _execution_state.restore_snapshot(snapshot)


static func validate_execution_snapshot(snapshot: Variant) -> Dictionary:
	return ClassicExecutionStateScript.validate_snapshot(snapshot)


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
	return _halt_with_error(
		"Classic opcode execution requires ScenarioInterpreter"
	)


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


func unsupported_instruction_result(action: Dictionary) -> Dictionary:
	var code := normalize_opcode(int(
		action.get("rawCode", action.get("code", 0))
	))
	halted = true
	last_error = (
		"Unsupported Classic opcode %d at %s record %d slot %d"
		% [
			code,
			str(current_trigger.get("source", "unknown source")),
			int(current_trigger.get("recordIndex", -1)),
			int(action.get("slot", -1)),
		]
	)
	return {
		"status": "unsupported",
		"message": last_error,
		"opcode": code,
		"action": action,
		"triggerId": _current_trigger_id(),
	}


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
	return _control_flow_opcode_runtime.resume_random_branch()


func resume_back_up_party() -> Dictionary:
	return _map_time_opcode_runtime.resume_back_up_party()


func resume_time_mutation(response: Dictionary) -> Dictionary:
	return _map_time_opcode_runtime.resume_time_mutation(response)


func resume_exploration_status(response: Dictionary) -> Dictionary:
	return _map_time_opcode_runtime.resume_exploration_status(response)


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
	return _encounter_opcode_runtime._eliminate_current_simple_option(
		option_index
	)


func _eliminate_simple_option_from_extra_code(extra_code_id: int) -> Dictionary:
	return _encounter_opcode_runtime \
		._eliminate_simple_option_from_extra_code(extra_code_id)


func _eliminate_simple_encounter_option(encounter_id: int, option_index: int) -> Dictionary:
	return _encounter_opcode_runtime \
		._eliminate_simple_encounter_option(
			encounter_id,
			option_index
		)


func _eliminate_complex_result(result_index: int) -> Dictionary:
	return _encounter_opcode_runtime._eliminate_complex_result(
		result_index
	)


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
	return _rules_state_opcode_runtime._execute_action_data_patch(
		extra_code_id
	)


func _execute_timed_encounter_mutation(extra_code_id: int) -> Dictionary:
	return _map_time_opcode_runtime._execute_timed_encounter_mutation(
		extra_code_id
	)


func _patch_map_action_point(values: Array, source: Dictionary) -> Dictionary:
	return _rules_state_opcode_runtime._patch_map_action_point(
		values,
		source
	)


func _patch_encounter_result(
	encounter_kind: String,
	encounter_id: int,
	result_index: int,
	source: Dictionary
) -> Dictionary:
	return _rules_state_opcode_runtime._patch_encounter_result(
		encounter_kind,
		encounter_id,
		result_index,
		source
	)


func _replace_encounter_result_actions(
	encounter_actions: Array,
	source_actions: Array,
	result_index: int
) -> Array:
	return _rules_state_opcode_runtime \
		._replace_encounter_result_actions(
			encounter_actions,
			source_actions,
			result_index
		)


func _execute_same_as_other_action_point(record_index: int) -> Dictionary:
	return _rules_state_opcode_runtime \
		._execute_same_as_other_action_point(record_index)


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
	return _control_flow_opcode_runtime \
		._remove_current_action_point()


func _finish_action_point(reason: String, consume_codes: bool) -> Dictionary:
	return _control_flow_opcode_runtime._finish_action_point(
		reason,
		consume_codes
	)


func _action_point_destination_result(reason: String) -> Dictionary:
	return _control_flow_opcode_runtime \
		._action_point_destination_result(reason)


func _repeat_encounter_after_fallthrough() -> Dictionary:
	return _encounter_opcode_runtime \
		._repeat_encounter_after_fallthrough()


func _persist_removed_action_point(consume_codes: bool) -> void:
	_control_flow_opcode_runtime._persist_removed_action_point(
		consume_codes
	)


func _set_origin_action_point_percent(percent: int) -> void:
	_control_flow_opcode_runtime._set_origin_action_point_percent(
		percent
	)


func _map_action_point_id(level_kind: String, level: int, record_index: int) -> String:
	return _control_flow_opcode_runtime._map_action_point_id(
		level_kind,
		level,
		record_index
	)


func _effective_map_action_point(level_kind: String, level: int, record_index: int) -> Dictionary:
	return _control_flow_opcode_runtime \
		._effective_map_action_point(
			level_kind,
			level,
			record_index
		)


func _coordinate_from_door_id(door_id: int, level: int) -> Variant:
	return _control_flow_opcode_runtime._coordinate_from_door_id(
		door_id,
		level
	)


func _is_map_action_point(action_point: Dictionary) -> bool:
	return _control_flow_opcode_runtime._is_map_action_point(
		action_point
	)


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
	return _control_flow_opcode_runtime._execute_random_branch(
		extra_code_id,
		gosub
	)


func _apply_random_branch(random_branch: Dictionary) -> Dictionary:
	return _control_flow_opcode_runtime._apply_random_branch(
		random_branch
	)


func _branch_to_action_or_encounter(target_mode: int, target_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._branch_to_action_or_encounter(
		target_mode,
		target_id,
		gosub
	)


func _execute_quest_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._execute_quest_branch(
		extra_code_id,
		gosub
	)


func _execute_quest_value_mutation(extra_code_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._execute_quest_value_mutation(
		extra_code_id,
		gosub
	)


func _execute_quest_value_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._execute_quest_value_branch(
		extra_code_id,
		gosub
	)


func _execute_quest_range_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._execute_quest_range_branch(
		extra_code_id,
		gosub
	)


func _execute_tile_parameter_branch(extra_code_id: int, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._execute_tile_parameter_branch(
		extra_code_id,
		gosub
	)


func _tile_parameter_is_set(attribute: Dictionary, selector: int) -> bool:
	return _control_flow_opcode_runtime._tile_parameter_is_set(
		attribute,
		selector
	)


func _execute_experience_loss(extra_code_id: int) -> Dictionary:
	return _character_opcode_runtime._execute_experience_loss(extra_code_id)


func _execute_percent_branch(extra_code_id: int) -> Dictionary:
	return _control_flow_opcode_runtime._execute_percent_branch(
		extra_code_id
	)


func _execute_difficulty_branch(extra_code_id: int) -> Dictionary:
	return _control_flow_opcode_runtime._execute_difficulty_branch(
		extra_code_id
	)


func _apply_force_branch_success(values: Array) -> Dictionary:
	return _control_flow_opcode_runtime._apply_force_branch_success(
		values
	)


func _roll_percent() -> int:
	return _control_flow_opcode_runtime._roll_percent()


func _finish_conditional_branch(reason: String, consume_codes: bool) -> Dictionary:
	return _control_flow_opcode_runtime._finish_conditional_branch(
		reason,
		consume_codes
	)


func _branch_from_extra_code(values: Array, gosub: bool) -> Dictionary:
	return _control_flow_opcode_runtime._branch_from_extra_code(
		values,
		gosub
	)


func _branch_to_loaded_encounter_result(
	encounter_kind: String,
	result_index: int,
	start_slot: int
) -> Dictionary:
	return _encounter_opcode_runtime \
		._branch_to_loaded_encounter_result(
			encounter_kind,
			result_index,
			start_slot
		)


func _branch_to_extra_action_point(record_id: int, gosub: bool, start_slot: int) -> Dictionary:
	return _control_flow_opcode_runtime._branch_to_extra_action_point(
		record_id,
		gosub,
		start_slot
	)


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
	return _encounter_opcode_runtime._encounter_outcome_trigger(
		encounter_kind,
		encounter_id,
		encounter,
		outcome
	)


func _break_encounter() -> Dictionary:
	return _encounter_opcode_runtime._break_encounter()


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
