class_name InventoryPort
extends DelegatingScenarioPort

const COMMANDS := [
	"query_party_wealth",
	"give_treasure",
	"drop_party_items",
	"load_shop",
	"alter_shop",
	"offer_temple",
	"enable_banking",
	"check_party_item",
	"take_party_wealth",
	"clear_party_currency",
	"alter_party_items",
	"store_party_equipment",
]
const OPERATIONS := {
	"query_party_wealth": "_query_party_wealth",
	"give_treasure": "_give_treasure",
	"drop_party_items": "_drop_party_items",
	"load_shop": "_load_shop",
	"alter_shop": "_alter_shop",
	"offer_temple": "_offer_temple",
	"enable_banking": "_enable_banking",
	"check_party_item": "_check_party_item",
	"take_party_wealth": "_take_party_wealth_with_warning",
	"clear_party_currency": "_clear_party_currency",
	"alter_party_items": "_alter_party_items",
	"store_party_equipment": "_store_party_equipment",
}


func port_id() -> String:
	return "core.inventory"


func service_operation(command_id: String) -> String:
	if str(rule_option("inventory", "itemIdentity", "scenario-stable")) == "native-name":
		if command_id == "check_party_item":
			return "_check_party_item_native_name"
		if command_id == "alter_party_items":
			return "_alter_party_items_native_name"
	return str(OPERATIONS.get(command_id, ""))


func owned_command_ids() -> PackedStringArray:
	return PackedStringArray(COMMANDS)


func save_policy() -> Dictionary:
	return {"state": "owned"}


func snapshot_state() -> Dictionary:
	if _port_runtime != null and _port_runtime.has_method("classic_save_state"):
		var value: Variant = _port_runtime.call("classic_save_state")
		return value.duplicate(true) if value is Dictionary else {}
	return {}


func restore_state(state: Dictionary) -> Dictionary:
	if _port_runtime != null and _port_runtime.has_method("restore_classic_save_state"):
		var result: Variant = _port_runtime.call(
			"restore_classic_save_state",
			state
		)
		return result if result is Dictionary else {
			"status": "error",
			"message": "Inventory port restore returned an invalid result",
		}
	return {"status": "ok"} if state.is_empty() else {
		"status": "error",
		"message": "Inventory port state cannot be restored without an inventory service",
	}


func has_item_behavior(instance: Object, hook_kind: String) -> bool:
	var hook := _behavior_hook(hook_kind)
	if hook.is_empty() or _port_runtime == null \
			or not _port_runtime.has_method("scenario_item_behavior_context"):
		return false
	var context: Dictionary = _port_runtime.call(
		"scenario_item_behavior_context",
		instance
	)
	if str(context.get("status", "")) != "ok" \
			or behavior_runner == null \
			or not behavior_runner.has_method("has_behavior_attachments"):
		return false
	return bool(behavior_runner.call(
		"has_behavior_attachments",
		"item",
		hook,
		"item",
		context.get("targetIds", [])
	))


func run_item_behavior(
	instance: Object,
	hook_kind: String,
	user: Object = null,
	target: Object = null
) -> Dictionary:
	var hook := _behavior_hook(hook_kind)
	if hook.is_empty():
		return {"status": "error", "message": "Unknown scenario item hook '%s'" % hook_kind}
	if _port_runtime == null \
			or not _port_runtime.has_method("scenario_item_behavior_context"):
		return {"handled": false}
	var context: Dictionary = _port_runtime.call(
		"scenario_item_behavior_context",
		instance,
		user,
		target
	)
	if str(context.get("status", "")) != "ok":
		return context
	var request: Dictionary = context.get("request", {})
	request["hook"] = hook
	var attachment_result := await invoke_behavior_attachments(
		"item",
		hook,
		"item",
		context.get("targetIds", []),
		request
	)
	if str(attachment_result.get("status", "")) == "error" \
			or bool(attachment_result.get("handled", false)):
		return attachment_result
	return await invoke_runtime_binding(
		"items",
		"itemBehaviors",
		context.get("targetIds", []),
		request
	)


func run_item_behavior_pure(
	instance: Object,
	hook_kind: String,
	user: Object = null,
	target: Object = null,
	details := {}
) -> Dictionary:
	var hook := _behavior_hook(hook_kind)
	if hook.is_empty():
		return {"status": "error", "message": "Unknown scenario item hook '%s'" % hook_kind}
	if hook in ["use-field", "use-combat"]:
		return {
			"status": "error",
			"message": "Scenario item hook '%s' is not pure" % hook,
		}
	if _port_runtime == null \
			or not _port_runtime.has_method("scenario_item_behavior_context"):
		return {"handled": false, "outcomes": []}
	var context: Dictionary = _port_runtime.call(
		"scenario_item_behavior_context",
		instance,
		user,
		target,
		details
	)
	if str(context.get("status", "")) != "ok":
		return context
	var request: Dictionary = context.get("request", {})
	request["hook"] = hook
	request["hookKind"] = hook_kind
	var attachment_result := invoke_behavior_attachments_pure(
		"item",
		hook,
		"item",
		context.get("targetIds", []),
		request
	)
	if str(attachment_result.get("status", "")) == "error":
		return attachment_result
	if bool(attachment_result.get("handled", false)):
		attachment_result["outcomes"] = _provider_outcomes(attachment_result)
		return attachment_result
	var binding_result := invoke_runtime_binding_pure(
		"items",
		"itemBehaviors",
		context.get("targetIds", []),
		request
	)
	if str(binding_result.get("status", "")) == "error":
		return binding_result
	binding_result["outcomes"] = _provider_outcomes(binding_result)
	return binding_result


static func _provider_outcomes(result: Dictionary) -> Array:
	var outcomes: Array = []
	var value: Variant = result.get("value")
	if value is Dictionary:
		outcomes.append(value.duplicate(true))
	for result_value: Variant in result.get("results", []):
		if not (result_value is Dictionary):
			continue
		var nested_value: Variant = result_value.get("value")
		if nested_value is Dictionary:
			outcomes.append(nested_value.duplicate(true))
	return outcomes


static func _behavior_hook(hook_kind: String) -> String:
	return str({
		"field_use": "use-field",
		"combat_use": "use-combat",
		"equip": "equip",
		"unequip": "unequip",
		"melee_attack": "attack",
		"melee_accuracy": "attack",
		"defense": "defense",
		"passive": "passive",
	}.get(hook_kind, ""))


func execute(command_id: String, request: Dictionary) -> Dictionary:
	var routed_request := request.duplicate(true)
	var scenario_operation := str(
		routed_request.get("_scenarioApiOperation", "")
	)
	if scenario_operation == "core.inventory.temple":
		routed_request["soundId"] = 0
	if scenario_operation == "core.inventory.banking":
		routed_request["soundId"] = 0
		routed_request["warningId"] = 0
	if scenario_operation == "core.inventory.alter-item":
		var action := str(routed_request.get("action", "")).to_lower()
		var operation := int({
			"remove": 1,
			"charges": 2,
			"replace": 3,
		}.get(action, 0))
		if operation == 0:
			return {
				"status": "error",
				"message": (
					"Scenario item action must be remove, charges, or replace"
				),
			}
		routed_request["operation"] = operation
		routed_request["maxMatches"] = maxi(
			1,
			int(routed_request.get("maximum", 100))
		)
	if scenario_operation \
			== "core.inventory.take-wealth":
		if _port_runtime == null \
				or not _port_runtime.has_method("_take_scenario_wealth"):
			return {
				"status": "error",
				"message": "Scenario wealth service is unavailable",
			}
		return await _port_runtime.call(
			"_take_scenario_wealth",
			routed_request
		)
	var extension_result := await invoke_runtime_binding(
		"items",
		"itemBehaviors",
		[
			routed_request.get("definitionId", ""),
			routed_request.get("scenarioItemId", ""),
			routed_request.get("itemId", ""),
			routed_request.get("itemName", ""),
		],
		routed_request
	)
	if bool(extension_result.get("handled", false)):
		return extension_result
	return await super.execute(command_id, routed_request)
