class_name ScenarioControlFlowHandler
extends ClassicOpcodeHandler


func _init() -> void:
	configure(
		"core.control-flow",
		PackedInt32Array([
			-23, -14, 0, 24, 25, 34, 35, 38, 39, 41, 42, 44, 46, 55,
			56, 58, 64, 67, 72, 76, 77, 78, 84, 85, 86, 98, 99, 107, 111, 112,
		])
	)


func semantic_operations() -> PackedStringArray:
	return PackedStringArray([
		"core.flow.branch",
		"core.flow.halt",
		"core.flow.mark-result",
	])


func execute(instruction: Dictionary, context: Object) -> ScenarioStepResult:
	if str(instruction.get("kind", "")) != "semantic":
		return super.execute(instruction, context)
	var parameters: Variant = instruction.get("parameters", {})
	if not (parameters is Dictionary):
		return ScenarioStepResult.failed(
			"Semantic flow parameters must be an object"
		)
	match str(instruction.get("operation", "")):
		"core.flow.branch":
			var action_index := int(parameters.get("actionIndex", -1))
			if action_index < 0:
				return ScenarioStepResult.failed(
					"core.flow.branch requires a non-negative action index"
				)
			var result_ref: Variant = parameters.get("resultRef")
			if result_ref is Dictionary \
					and context != null \
					and context.has_method("record_semantic_result_reference"):
				context.call("record_semantic_result_reference", result_ref)
			return ScenarioStepResult.branched(action_index)
		"core.flow.halt":
			return ScenarioStepResult.halted({
				"reason": str(parameters.get("reason", "semantic-flow")),
				"outcome": str(parameters.get("outcome", "continue")),
			})
		"core.flow.mark-result":
			var result_ref: Variant = parameters.get("resultRef")
			if not (result_ref is Dictionary):
				return ScenarioStepResult.failed(
					"core.flow.mark-result requires a result reference"
				)
			if context == null \
					or not context.has_method("record_semantic_result_reference"):
				return ScenarioStepResult.failed(
					"Semantic result tracking is unavailable"
				)
			if not bool(context.call(
				"record_semantic_result_reference",
				result_ref
			)):
				return ScenarioStepResult.failed(
					"Encounter result transition limit exceeded"
				)
			return ScenarioStepResult.continued()
	return ScenarioStepResult.failed("Unsupported semantic flow operation")


func execute_on_runtime(instruction: Dictionary, runtime: Object) -> Dictionary:
	var code := int(instruction.get("code", 0))
	var record_id := int(instruction.get("id", 0))
	var gosub := bool(runtime.gosub_active)
	match code:
		-23:
			return _invoke(
				runtime,
				"_execute_random_rectangle_mutation",
				[record_id, true]
			)
		-14:
			return _invoke(
				runtime,
				"_execute_character_pick",
				[record_id, true]
			)
		0:
			return _invoke(runtime, "_continue_result")
		24:
			return _invoke(
				runtime,
				"_finish_action_point",
				["keep-codes", false]
			)
		25:
			return _invoke(runtime, "_remove_current_action_point")
		34:
			return _invoke(runtime, "_break_encounter")
		35:
			return _invoke(
				runtime,
				"_eliminate_current_simple_option",
				[record_id]
			)
		38:
			return _invoke(runtime, "_execute_item_result_branch", [record_id])
		39:
			return _invoke(
				runtime,
				"_branch_to_extra_action_point",
				[record_id, false, 0]
			)
		41:
			return _invoke(
				runtime,
				"_eliminate_simple_option_from_extra_code",
				[record_id]
			)
		42:
			return _invoke(runtime, "_execute_percent_branch", [record_id])
		44:
			return _invoke(runtime, "_eliminate_complex_result", [record_id])
		46:
			return _invoke(runtime, "_execute_quest_branch", [record_id, gosub])
		55:
			return _invoke(
				runtime,
				"_execute_selected_count_branch",
				[record_id, gosub]
			)
		56:
			return _invoke(
				runtime,
				"_execute_battle_outcome",
				[record_id, gosub]
			)
		58:
			return _invoke(runtime, "_execute_difficulty_branch", [record_id])
		64:
			return _invoke(runtime, "_execute_time_branch", [record_id, gosub])
		67:
			return _invoke(
				runtime,
				"_execute_item_charge_branch",
				[record_id, gosub]
			)
		72:
			return _invoke(
				runtime,
				"_execute_quest_range_branch",
				[record_id, gosub]
			)
		76:
			return _invoke(
				runtime,
				"_execute_quest_value_mutation",
				[record_id, gosub]
			)
		77:
			return _invoke(
				runtime,
				"_execute_quest_value_branch",
				[record_id, gosub]
			)
		78:
			return _invoke(
				runtime,
				"_execute_tile_parameter_branch",
				[record_id, gosub]
			)
		84, 98, 99:
			return _invoke(runtime, "_continue_result")
		85:
			return _invoke(runtime, "_execute_random_branch", [record_id, gosub])
		86:
			return _invoke(runtime, "_execute_misc_branch", [record_id, gosub])
		107:
			return _invoke(
				runtime,
				"_execute_improved_selective_battle",
				[record_id, gosub]
			)
		111:
			if runtime.call_stack.is_empty():
				if bool(runtime.remove_action_point):
					return _invoke(runtime, "_continue_result")
				_call_void(runtime, "_clear_control_flow")
				return _invoke(
					runtime,
					"_completed_result",
					["return-with-empty-stack"]
				)
			_call_void(runtime, "_restore_call_frame")
			return _invoke(runtime, "_continue_result")
		112:
			if not runtime.call_stack.is_empty():
				runtime.call_stack.pop_back()
			return _invoke(runtime, "_continue_result")
	return _unsupported(instruction)
