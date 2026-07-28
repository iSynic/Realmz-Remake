class_name ScenarioRulesStateHandler
extends ClassicOpcodeHandler


func _init() -> void:
	configure("core.rules-state", PackedInt32Array([7, 8, 47]))


func execute_on_runtime(instruction: Dictionary, runtime: Object) -> Dictionary:
	var code := int(instruction.get("code", 0))
	var record_id := int(instruction.get("id", 0))
	match code:
		7:
			return _invoke(
				runtime,
				"_execute_action_data_patch",
				[record_id]
			)
		8:
			return _invoke(
				runtime,
				"_execute_same_as_other_action_point",
				[record_id]
			)
		47:
			runtime.runtime_state.set_quest_flag(record_id)
			return _invoke(runtime, "_continue_result")
	return _unsupported(instruction)
