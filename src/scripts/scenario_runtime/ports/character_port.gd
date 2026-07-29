class_name CharacterPort
extends DelegatingScenarioPort

const COMMANDS := [
	"query_party_members",
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


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	if command_id == "give_experience":
		var base_experience := float(
			routed_request.get(
				"experience",
				routed_request.get("amount", 0)
			)
		)
		var experience_result := await apply_rule_modifiers(
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
		var health_result := await apply_rule_modifiers(
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
		var effect_result := await invoke_behavior_attachments(
			"spell",
			"effect",
			"spell",
			spell_ids,
			routed_request
		)
		if str(effect_result.get("status", "")) == "error":
			return effect_result
		if bool(cast_result.get("handled", false)) \
				or bool(effect_result.get("handled", false)):
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
				and str(effect_value.get("kind", "")) == "invalid":
			return true
	return false
