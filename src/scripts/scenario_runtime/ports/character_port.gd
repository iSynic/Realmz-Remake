class_name CharacterPort
extends DelegatingScenarioPort

const COMMANDS := [
	"query_party_members",
	"query_spell_definition",
	"alter_party_fatigue",
	"check_party_condition",
	"check_party_ally",
	"add_party_ally",
	"remove_party_ally",
	"give_experience",
	"remove_experience",
	"give_character_condition",
	"pick_characters",
	"filter_selected_characters",
	"check_character_ability",
	"level_up_selected_characters",
	"alter_selected_characters",
	"select_characters_by_misc",
	"select_characters_by_identity",
	"check_party_misc",
	"change_selected_health",
	"change_party_health",
	"cast_classic_spell",
]
const OPERATIONS := {
	"query_party_members": "_query_party_members",
	"query_spell_definition": "_query_spell_definition",
	"alter_party_fatigue": "_alter_party_fatigue",
	"check_party_condition": "_check_party_condition",
	"check_party_ally": "_check_party_ally",
	"add_party_ally": "_add_classic_ally",
	"remove_party_ally": "_remove_classic_allies",
	"give_experience": "_give_experience",
	"remove_experience": "_remove_experience",
	"give_character_condition": "_give_character_condition",
	"pick_characters": "_pick_characters",
	"filter_selected_characters": "_filter_selected_characters",
	"check_character_ability": "_check_character_ability",
	"level_up_selected_characters": "_level_up_selected_characters",
	"alter_selected_characters": "_alter_selected_characters",
	"select_characters_by_misc": "_select_characters_by_misc",
	"select_characters_by_identity": "_select_characters_by_identity",
	"check_party_misc": "_check_party_misc",
	"change_selected_health": "_change_selected_health",
	"change_party_health": "_change_party_health",
	"cast_classic_spell": "_cast_classic_spell",
}


func port_id() -> String:
	return "core.character"


func service_operation(command_id: String) -> String:
	return str(OPERATIONS.get(command_id, ""))


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func has_spell_behavior(spell: Object) -> bool:
	var context := _spell_behavior_context(spell, null, [], 0, {})
	if str(context.get("status", "")) != "ok" \
			or behavior_runner == null \
			or not behavior_runner.has_method("has_behavior_attachments"):
		return false
	for hook: String in ["validate", "cast", "effect", "tick", "expire"]:
		if bool(behavior_runner.call(
			"has_behavior_attachments",
			"spell",
			hook,
			"spell",
			context.get("targetIds", [])
		)):
			return true
	return false


func run_spell_behavior(
	spell: Object,
	caster: Object,
	targets: Array,
	power: int,
	cast_context := {}
) -> Dictionary:
	var context := _spell_behavior_context(
		spell,
		caster,
		targets,
		power,
		cast_context
	)
	if str(context.get("status", "")) != "ok":
		return context
	var request: Dictionary = context.get("request", {})
	var target_ids: Array = context.get("targetIds", [])
	var validation_result := await _run_spell_behavior_hook(
		"validate",
		target_ids,
		request
	)
	if str(validation_result.get("status", "")) == "error":
		return validation_result
	if _spell_behavior_invalid(validation_result):
		return {
			"status": "ok",
			"handled": true,
			"valid": false,
			"validationResults": validation_result.get("results", []),
		}
	var cast_result := await _run_spell_behavior_hook("cast", target_ids, request)
	if str(cast_result.get("status", "")) == "error":
		return cast_result
	if _spell_behavior_cancelled(cast_result):
		return {
			"status": "ok",
			"handled": true,
			"valid": false,
			"cancelled": true,
			"validationResults": validation_result.get("results", []),
			"castResults": cast_result.get("results", []),
		}
	var effect_result := await _run_spell_behavior_hook(
		"effect",
		target_ids,
		request
	)
	if str(effect_result.get("status", "")) == "error":
		return effect_result
	var schedule_result := _register_spell_effect_from_results(
		target_ids,
		request,
		effect_result
	)
	if str(schedule_result.get("status", "")) == "error":
		return schedule_result
	var spell_request: Dictionary = request.get("spell", {})
	var extension_result := await invoke_runtime_binding(
		"spells",
		"spells",
		target_ids + [spell_request.get("name", "")],
		request
	)
	if str(extension_result.get("status", "")) == "error":
		return extension_result
	return {
		"status": "ok",
		"handled": (
			bool(effect_result.get("handled", false))
			or bool(extension_result.get("handled", false))
		),
		"valid": true,
		"validationResults": validation_result.get("results", []),
		"castResults": cast_result.get("results", []),
		"effectResults": effect_result.get("results", []),
		"effectSchedule": schedule_result,
		"extensionResult": extension_result,
	}


func run_spell_behavior_hook(
	spell: Object,
	hook: String,
	caster: Object,
	targets: Array,
	power: int,
	cast_context := {}
) -> Dictionary:
	if hook not in ["validate", "cast", "effect", "tick", "expire"]:
		return {
			"status": "error",
			"message": "Unknown scenario spell hook '%s'" % hook,
		}
	var context := _spell_behavior_context(
		spell,
		caster,
		targets,
		power,
		cast_context
	)
	if str(context.get("status", "")) != "ok":
		return context
	var request: Dictionary = context.get("request", {})
	var target_ids: Array = context.get("targetIds", [])
	var result := await _run_spell_behavior_hook(hook, target_ids, request)
	if str(result.get("status", "")) == "error":
		return result
	if hook == "validate":
		result["valid"] = not _spell_behavior_invalid(result)
	if hook == "cast":
		result["cancelled"] = _spell_behavior_cancelled(result)
	if hook == "effect":
		var schedule_result := _register_spell_effect_from_results(
			target_ids,
			request,
			result
		)
		if str(schedule_result.get("status", "")) == "error":
			return schedule_result
		result["effectSchedule"] = schedule_result
		var spell_request: Dictionary = request.get("spell", {})
		var extension_result := await invoke_runtime_binding(
			"spells",
			"spells",
			target_ids + [spell_request.get("name", "")],
			request
		)
		if str(extension_result.get("status", "")) == "error":
			return extension_result
		if bool(extension_result.get("handled", false)):
			result["handled"] = true
			result["extensionResult"] = extension_result
	return result


func run_stored_spell_behavior_hook(
	effect: Dictionary,
	hook: String,
	event := {}
) -> Dictionary:
	if hook not in ["tick", "expire"]:
		return {
			"status": "error",
			"message": "Stored spell effect cannot dispatch hook '%s'" % hook,
		}
	var target_ids: Variant = effect.get("spellTargetIds", [])
	var request_value: Variant = effect.get("request", {})
	if not (target_ids is Array) or not (request_value is Dictionary):
		return {
			"status": "error",
			"message": "Stored scenario spell effect is malformed",
		}
	var normalized_target_ids: Array = target_ids
	var request: Dictionary = request_value.duplicate(true)
	request["hook"] = hook
	request["activeEffect"] = {
		"id": str(effect.get("id", "")),
		"effectKey": str(effect.get("effectKey", "")),
		"interval": str(effect.get("interval", "")),
		"remainingTicks": int(effect.get("remainingTicks", 0)),
	}
	request["effectEvent"] = (
		event.duplicate(true) if event is Dictionary else {}
	)
	var result := await _run_spell_behavior_hook(
		hook,
		normalized_target_ids,
		request
	)
	if str(result.get("status", "")) == "error":
		return result
	var spell_request: Dictionary = request.get("spell", {})
	var extension_result := await invoke_runtime_binding(
		"spells",
		"spells",
		normalized_target_ids + [spell_request.get("name", "")],
		request
	)
	if str(extension_result.get("status", "")) == "error":
		return extension_result
	if bool(extension_result.get("handled", false)):
		result["handled"] = true
		result["extensionResult"] = extension_result
	return result


func _register_spell_effect_from_results(
	target_ids: Array,
	request: Dictionary,
	result: Dictionary
) -> Dictionary:
	if behavior_runner == null \
			or not behavior_runner.has_method("register_spell_behavior_effect"):
		return {"status": "ok", "registered": false}
	for provider_result_value: Variant in result.get("results", []):
		if not (provider_result_value is Dictionary):
			continue
		var outcome: Variant = provider_result_value.get("value")
		if not (outcome is Dictionary) \
				or str(outcome.get("kind", "")) != "applied" \
				or int(outcome.get("duration", 0)) <= 0:
			continue
		return behavior_runner.call(
			"register_spell_behavior_effect",
			target_ids,
			request,
			outcome
		)
	return {"status": "ok", "registered": false}


func _run_spell_behavior_hook(
	hook: String,
	target_ids: Array,
	request: Dictionary
) -> Dictionary:
	return await invoke_behavior_attachments(
		"spell",
		hook,
		"spell",
		target_ids,
		request
	)


func _spell_behavior_context(
	spell: Object,
	caster: Object,
	targets: Array,
	power: int,
	cast_context: Dictionary
) -> Dictionary:
	if _port_runtime == null \
			or not _port_runtime.has_method("scenario_spell_behavior_context"):
		return {
			"status": "error",
			"message": "Scenario spell behavior service is unavailable",
		}
	return _port_runtime.call(
		"scenario_spell_behavior_context",
		spell,
		caster,
		targets,
		power,
		cast_context
	)


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	var scenario_operation := str(
		routed_request.get("_scenarioApiOperation", "")
	)
	if scenario_operation == "core.character.fatigue":
		var fatigue_result := apply_rule_modifiers(
			"fatigue",
			float(routed_request.get("amount", 0.0)),
			{
				"commandId": command_id,
				"request": routed_request.duplicate(true),
			}
		)
		if str(fatigue_result.get("status", "")) != "ok":
			return fatigue_result
		routed_request["amount"] = float(
			fatigue_result.get("value", 0.0)
		)
		if _port_runtime == null \
				or not _port_runtime.has_method(
					"_change_scenario_party_fatigue"
				):
			return {
				"status": "error",
				"message": "Scenario party fatigue service is unavailable",
			}
		return await _port_runtime.call(
			"_change_scenario_party_fatigue",
			routed_request
		)
	if scenario_operation == "core.character.remove-experience":
		routed_request["experience"] = maxi(
			0,
			int(routed_request.get("amount", 0))
		)
		routed_request["mode"] = (
			"selected"
			if bool(routed_request.get("selectedOnly", false))
			else "each"
		)
	if scenario_operation == "core.character.condition":
		routed_request["soundId"] = 0
	if scenario_operation == "core.character.cast-spell":
		routed_request["saveAdjustment"] = int(
			routed_request.get("saveAdjustment", 0)
		)
		routed_request["forceAffect"] = bool(
			routed_request.get("forceAffect", false)
		)
	if scenario_operation == "core.character.change-stat":
		var stat_modes := {
			"actions": 1,
			"spell-actions": 2,
			"movement": 3,
			"damage-bonus": 4,
			"maximum-spell-points": 5,
			"hand-to-hand": 6,
			"maximum-health": 7,
			"defense": 8,
			"melee-accuracy": 9,
			"ranged-accuracy": 10,
			"magic-resistance": 11,
			"prestige": 12,
		}
		var stat_name := str(routed_request.get("stat", ""))
		if not stat_modes.has(stat_name):
			return {
				"status": "error",
				"message": "Scenario character stat '%s' is unavailable"
					% stat_name,
			}
		routed_request["mode"] = int(stat_modes[stat_name])
		routed_request["change"] = int(routed_request.get("amount", 0))
	if command_id == "give_experience":
		var base_experience := float(
			routed_request.get(
				"experience",
				routed_request.get("amount", 0)
			)
		)
		var experience_result := apply_rule_modifiers(
			"experience",
			base_experience,
			{
				"minimum": 0.0,
				"commandId": command_id,
				"request": routed_request.duplicate(true),
			}
		)
		if str(experience_result.get("status", "")) != "ok":
			return experience_result
		routed_request["experience"] = maxi(
			0,
			roundi(float(experience_result.get("value", 0)))
		)
	if command_id in ["change_selected_health", "change_party_health"]:
		var base_health := float(routed_request.get("amount", 0))
		var health_family := "healing" if base_health >= 0.0 else "damage"
		var health_result := apply_rule_modifiers(
			health_family,
			absf(base_health),
			{
				"minimum": 0.0,
				"commandId": command_id,
				"request": routed_request.duplicate(true),
			}
		)
		if str(health_result.get("status", "")) != "ok":
			return health_result
		var resolved_health := roundi(float(health_result.get("value", 0)))
		routed_request["amount"] = (
			resolved_health if base_health >= 0.0 else -resolved_health
		)
		if scenario_operation == "core.character.change-health":
			if _port_runtime == null \
					or not _port_runtime.has_method(
						"_change_scenario_party_health"
					):
				return {
					"status": "error",
					"message": "Scenario party health service is unavailable",
				}
			return await _port_runtime.call(
				"_change_scenario_party_health",
				routed_request
			)
	if not bool(rule_option("character", "classicConditions", true)):
		if command_id == "give_character_condition":
			return {
				"status": "ok",
				"skipped": true,
				"reason": "gameplay-rules",
			}
		if command_id == "check_party_condition":
			return {
				"status": "ok",
				"active": false,
				"reason": "gameplay-rules",
			}
	if command_id == "cast_classic_spell":
		var spell_ids := [
			request.get("authoredSpellId", ""),
			request.get("spellId", ""),
		]
		var validation_result := await invoke_behavior_attachments(
			"spell",
			"validate",
			"spell",
			spell_ids,
			routed_request
		)
		if str(validation_result.get("status", "")) == "error":
			return validation_result
		if _spell_behavior_invalid(validation_result):
			return {
				"status": "ok",
				"handled": true,
				"valid": false,
				"behaviorResults": validation_result.get("results", []),
			}
		var cast_result := await invoke_behavior_attachments(
			"spell",
			"cast",
			"spell",
			spell_ids,
			routed_request
		)
		if str(cast_result.get("status", "")) == "error":
			return cast_result
		if _spell_behavior_cancelled(cast_result):
			return {
				"status": "ok",
				"handled": true,
				"valid": false,
				"cancelled": true,
				"castResults": cast_result.get("results", []),
			}
		var effect_result := await invoke_behavior_attachments(
			"spell",
			"effect",
			"spell",
			spell_ids,
			routed_request
		)
		if str(effect_result.get("status", "")) == "error":
			return effect_result
		if bool(effect_result.get("handled", false)):
			return {
				"status": "ok",
				"handled": true,
				"valid": true,
				"castResults": cast_result.get("results", []),
				"effectResults": effect_result.get("results", []),
			}
		var extension_result := await invoke_runtime_binding(
			"spells",
			"spells",
			[
				request.get("spellId", ""),
				request.get("authoredSpellId", ""),
				request.get("spellName", ""),
			],
			routed_request
		)
		if bool(extension_result.get("handled", false)):
			return extension_result
	return await super.execute(command_id, routed_request)


func _spell_behavior_invalid(result: Dictionary) -> bool:
	for behavior_result_value: Variant in result.get("results", []):
		if not (behavior_result_value is Dictionary):
			continue
		var effect_value: Variant = behavior_result_value.get("value")
		if effect_value is Dictionary \
				and str(effect_value.get("kind", "")) in ["blocked", "invalid"]:
			return true
	return false


func _spell_behavior_cancelled(result: Dictionary) -> bool:
	for behavior_result_value: Variant in result.get("results", []):
		if not (behavior_result_value is Dictionary):
			continue
		var cast_value: Variant = behavior_result_value.get("value")
		if cast_value is Dictionary \
				and str(cast_value.get("kind", "")) == "cancelled":
			return true
	return false
