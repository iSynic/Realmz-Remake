class_name ScenarioGodotInventoryServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const InventoryRulesScript = preload(
	"res://scripts/classic_runtime/classic_inventory_rules.gd"
)


func _query_party_wealth(_payload: Dictionary = {}) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz party wealth is unavailable")
	var pooled: Variant = game_global.get("money_pool")
	if not (pooled is Array) or pooled.size() < 3:
		return _error("Realmz pooled wealth is unavailable")
	var totals := [
		int(pooled[0]),
		int(pooled[1]),
		int(pooled[2]),
	]
	for character_value: Variant in service_owner.call("_party_characters"):
		if not (character_value is Object):
			continue
		var money: Variant = character_value.get("money")
		if not (money is Array):
			continue
		for index: int in range(mini(3, money.size())):
			totals[index] += int(money[index])
	return {
		"gold": totals[0],
		"gems": totals[1],
		"jewelry": totals[2],
		"pooledGold": int(pooled[0]),
	}


func _query_party_items(payload: Dictionary = {}) -> Dictionary:
	var requested_owner := str(payload.get("characterId", ""))
	var snapshots: Array = []
	var party: Array = service_owner.call("_party_characters")
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = (
		node_access.__Resources() if node_access != null else null
	)
	for party_index: int in range(party.size()):
		var owner_value: Variant = party[party_index]
		if not (owner_value is Object):
			continue
		var owner_id := "party:%d" % party_index
		if not requested_owner.is_empty() and requested_owner != owner_id:
			continue
		for instance_value: Variant in service_owner.call(
			"_character_inventory_items",
			owner_value
		):
			if not (instance_value is ItemInstance):
				continue
			var definition: Variant = (
				resources.get_item_definition(instance_value)
				if resources != null \
					and resources.has_method("get_item_definition")
				else null
			)
			var classic_item_ids: Array[int] = []
			for item_id_value: Variant in service_owner.call(
				"_classic_item_ids",
				instance_value
			):
				var item_id := int(item_id_value)
				if item_id != 0 and not classic_item_ids.has(item_id):
					classic_item_ids.append(item_id)
			classic_item_ids.sort()
			snapshots.append({
				"id": str(instance_value.instance_id),
				"definitionId": str(instance_value.definition_id),
				"name": (
					str(definition.get("name"))
					if definition is Object else ""
				),
				"ownerId": owner_id,
				"charges": int(instance_value.charges),
				"equipped": bool(instance_value.equipped),
				"identified": bool(instance_value.identified),
				"classicItemIds": classic_item_ids,
			})
			if snapshots.size() >= 256:
				return {"items": snapshots, "value": snapshots}
	return {"items": snapshots, "value": snapshots}


func _query_item_definition(payload: Dictionary) -> Dictionary:
	if service_owner.classic_bundle == null:
		return _error("Scenario item definitions are unavailable")
	var item_id := int(payload.get("itemId", -1))
	if item_id < 0:
		return _error("Scenario item definition reference is invalid")
	var record: Dictionary = service_owner.classic_bundle.get_scenario_item(
		item_id
	)
	if record.is_empty():
		return _error("Scenario item %d is unavailable" % item_id)
	var text: Dictionary = service_owner.classic_bundle.get_item_text(item_id)
	return {
		"id": str(int(record.get("itemId", item_id))),
		"name": str(text.get(
			"identifiedName",
			text.get("unidentifiedName", "")
		)),
		"iconId": int(record.get("iconId", 0)),
		"itemType": int(record.get(
			"itemType",
			record.get("type", 0)
		)),
		"cost": int(record.get("cost", 0)),
		"weight": int(record.get("weight", 0)),
		"maximumCharges": int(record.get(
			"charge",
			record.get("charges", 0)
		)),
	}


func classic_save_state() -> Dictionary:
	return service_owner.call("classic_save_state")


func restore_classic_save_state(saved_state: Dictionary) -> Dictionary:
	return service_owner.call("restore_classic_save_state", saved_state)


func scenario_item_behavior_context(
	instance: Object,
	user: Object = null,
	target: Object = null,
	details := {}
) -> Dictionary:
	if instance == null:
		return _error("Scenario item behavior requires an item instance")
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	if resources == null or not resources.has_method("get_item_definition"):
		return _error("Realmz item definitions are unavailable")
	var definition: Variant = resources.get_item_definition(instance)
	if definition == null:
		return _error("Scenario item behavior cannot resolve its item definition")
	var target_ids: Array = [str(instance.get("definition_id"))]
	if definition.has_method("classic_item_ids"):
		for classic_id: Variant in definition.call("classic_item_ids"):
			var id_text := str(classic_id)
			if not target_ids.has(id_text):
				target_ids.append(id_text)
	var instance_state: Dictionary = {}
	if instance.has_method("state_data"):
		var state_value: Variant = instance.call("state_data")
		if state_value is Dictionary:
			instance_state = state_value.duplicate(true)
	var request := {
		"item": {
			"definitionId": str(instance.get("definition_id")),
			"instanceId": str(instance.get("instance_id")),
			"charges": int(instance.get("charges")),
			"state": instance_state,
		},
		"definition": {
			"id": str(definition.get("definition_id")),
			"name": str(definition.get("name")),
		},
		"user": _scenario_creature_snapshot(user),
		"target": _scenario_creature_snapshot(target),
	}
	if details is Dictionary and not details.is_empty():
		request["event"] = details.duplicate(true)
	return {
		"status": "ok",
		"targetIds": target_ids,
		"request": request,
	}


func _scenario_creature_snapshot(creature: Object) -> Dictionary:
	if creature == null:
		return {}
	var stats: Variant = creature.get("stats")
	if not (stats is Dictionary):
		stats = {}
	var health := int(stats.get("curHP", 0))
	var maximum_health := int(stats.get("maxHP", health))
	return {
		"id": str(creature.get_instance_id()),
		"name": str(creature.get("name")),
		"health": health,
		"maximumHealth": maximum_health,
		"alive": health > 0,
	}


func _offer_temple(payload: Dictionary) -> Dictionary:
	var built: Dictionary = service_owner.call(
		"build_temple_services",
		int(payload.get("costPercent", 100))
	)
	if str(built.get("status", "")) == "error":
		return built
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	game_global.currentTemple = built["services"]
	game_global.allow_temple(true)
	service_owner.call("_play_sound", payload)
	return {
		"costPercent": int(payload.get("costPercent", 100)),
		"serviceCount": built["services"].size(),
	}


func _enable_banking(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	game_global.allow_banking(true)
	service_owner.call("_play_sound", payload)
	var warning_id := int(payload.get("warningId", 0))
	var warning_result: Dictionary = await service_owner.call(
		"_show_classic_warning",
		warning_id
	)
	if str(warning_result.get("status", "")) == "error":
		return warning_result
	return {
		"warningId": warning_id,
		"warningPresentation": warning_result,
	}


func _check_party_item(payload: Dictionary) -> Dictionary:
	var item_id: int = abs(int(payload.get("itemId", 0)))
	if item_id == 0:
		return _error("Classic item check has no item ID")
	if payload.has("minimumCharges"):
		var charge_total := int(service_owner.call(
			"classic_party_item_charge_total",
			service_owner.call("_party_characters"),
			item_id
		))
		return {
			"possessed": charge_total >= int(payload.get("minimumCharges", 0)),
			"charges": charge_total,
		}
	return {
		"possessed": InventoryRulesScript.party_has_classic_item(
			service_owner.call("_party_characters"),
			[item_id],
		),
	}


func _check_party_item_native_name(payload: Dictionary) -> Dictionary:
	var item_id: int = abs(int(payload.get("itemId", 0)))
	if item_id == 0:
		return _error("Native-name item check has no item ID")
	var names: Array = service_owner.call("_mapped_item_names", payload)
	if names.is_empty():
		return _error("Native-name item check cannot resolve an item name")
	return {
		"possessed": InventoryRulesScript.party_has_named_item(
			service_owner.call("_party_characters"),
			names,
		),
		"identityMode": "native-name",
	}


func _take_party_wealth_with_warning(payload: Dictionary) -> Dictionary:
	var result: Dictionary = service_owner.call("_take_party_wealth", payload)
	if str(result.get("status", "")) == "error" \
			or bool(result.get("paid", false)):
		return result
	var warning_result: Dictionary = await service_owner.call(
		"_show_classic_warning",
		int(result.get("warningId", payload.get("warningId", 0)))
	)
	if str(warning_result.get("status", "")) == "error":
		return warning_result
	result["warningPresentation"] = warning_result
	return result


func _take_scenario_wealth(payload: Dictionary) -> Dictionary:
	var requested := [
		maxi(0, int(payload.get("gold", 0))),
		maxi(0, int(payload.get("gems", 0))),
		maxi(0, int(payload.get("jewelry", 0))),
	]
	var wealth := _query_party_wealth()
	if str(wealth.get("status", "")) == "error":
		return wealth
	var available := [
		int(wealth.get("gold", 0)),
		int(wealth.get("gems", 0)),
		int(wealth.get("jewelry", 0)),
	]
	for index: int in 3:
		if requested[index] > available[index]:
			return {
				"paid": false,
				"requested": requested,
				"available": available,
			}
	var removed := [0, 0, 0]
	for index: int in 3:
		if requested[index] == 0:
			continue
		var result: Dictionary = service_owner.call(
			"_take_party_wealth",
			{"currency": index, "amount": requested[index]}
		)
		if str(result.get("status", "")) == "error" \
				or not bool(result.get("paid", false)):
			return _error(
				"Scenario wealth changed during an atomic payment"
			)
		removed[index] = requested[index]
	return {
		"paid": true,
		"removed": removed,
	}


func _clear_party_currency(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var pooled_money: Variant = game_global.money_pool
	if not (pooled_money is Array):
		return _error("Realmz pooled wealth is unavailable")
	var party: Array = service_owner.call("_party_characters")
	var result: Dictionary = service_owner.call(
		"clear_classic_party_currency",
		payload,
		party,
		service_owner.call("_current_selected_characters"),
		pooled_money
	)
	if str(result.get("status", "")) != "error":
		service_owner.call("_refresh_party_panels", party)
	return result


func _alter_party_items(payload: Dictionary) -> Dictionary:
	return service_owner.call("_alter_party_items_with_identity", payload, false)


func _alter_party_items_native_name(payload: Dictionary) -> Dictionary:
	return service_owner.call("_alter_party_items_with_identity", payload, true)


func _store_party_equipment(payload: Dictionary) -> Dictionary:
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var party: Array = service_owner.call("_party_characters")
	if party.is_empty():
		return _error("Classic equipment storage has no party members")
	var pooled_money: Variant = game_global.money_pool
	if not (pooled_money is Array):
		return _error("Realmz pooled wealth is unavailable")

	var stored_equipment: Dictionary = service_owner.stored_party_equipment
	if bool(payload.get("capture", false)):
		if bool(stored_equipment.get("active", false)):
			return {"captured": false, "active": true}
		var captured: Dictionary = InventoryRulesScript.capture_party_equipment(
			party,
			pooled_money
		)
		if str(captured.get("status", "")) == "error":
			return captured
		service_owner.stored_party_equipment = captured
		service_owner.call("_refresh_party_panels", party)
		return {
			"captured": true,
			"active": true,
			"itemCount": int(captured.get("itemCount", 0)),
		}

	if not bool(stored_equipment.get("active", false)):
		return {"restored": false, "active": false}
	var restored: Dictionary = InventoryRulesScript.restore_party_equipment(
		party,
		pooled_money,
		stored_equipment
	)
	if str(restored.get("status", "")) == "error":
		return restored
	service_owner.stored_party_equipment = {}
	service_owner.call("_refresh_party_panels", party)
	var extra_items: Array = restored.get("extraItems", [])
	if not extra_items.is_empty():
		await game_global.show_loot_menu(extra_items, [0, 0, 0], 0)
	return {
		"restored": true,
		"active": false,
		"restoredCount": int(restored.get("restoredCount", 0)),
		"extraItemCount": extra_items.size(),
		"reequipFailures": int(restored.get("reequipFailures", 0)),
	}


func _load_shop(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.inventory.open-shop":
		if service_owner.classic_bundle == null:
			return _error("Scenario shop catalog is unavailable")
		var shop_id := int(routed_payload.get("shopId", -1))
		var shop: Dictionary = service_owner.classic_bundle.get_shop(shop_id)
		if shop.is_empty():
			return _error("Scenario shop %d is unavailable" % shop_id)
		var runtime_state := _classic_runtime_state()
		if runtime_state != null:
			shop = runtime_state.get_effective_shop(shop)
		routed_payload["shop"] = shop
		routed_payload["acceptRanges"] = [0, 0, 0, 0]
		var item_texts: Array = []
		var item_text_ids: Array = (
			service_owner.classic_bundle.item_texts_by_id.keys()
		)
		item_text_ids.sort()
		for item_text_id: Variant in item_text_ids:
			item_texts.append(
				service_owner.classic_bundle.item_texts_by_id[item_text_id]
			)
		routed_payload["itemTexts"] = item_texts
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	if resources == null:
		return _error("Realmz item resources are unavailable")
	var built: Dictionary = service_owner.call(
		"build_shop_inventory_from_catalog",
		routed_payload,
		resources
	)
	if str(built.get("status", "")) == "error":
		return built
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var shop_name := "classic_shop_%d" % int(
		routed_payload.get("shopId", 0)
	)
	if not game_global.shops_dict.has(shop_name):
		game_global.shops_dict[shop_name] = built["shop"]
	else:
		var loaded_shop: Dictionary = game_global.shops_dict[shop_name]
		loaded_shop.erase("classic_accept_ranges")
		loaded_shop.erase("accepted_item_names")
		for rule_name: String in ["classic_accept_ranges", "accepted_item_names"]:
			if built["shop"].has(rule_name):
				loaded_shop[rule_name] = built["shop"][rule_name]
	game_global.currentShop = shop_name
	game_global.allow_banking(true)
	game_global.allow_money_change(true)
	var ui: Object = _autoload("UI")
	if (
		ui != null
		and ui.ow_hud != null
		and ui.ow_hud.has_method("_sync_shop_control")
	):
		ui.ow_hud._sync_shop_control()

	if bool(routed_payload.get("openImmediately", false)):
		if ui == null or ui.ow_hud == null or ui.ow_hud.inventoryRect == null:
			return _error("Realmz shop UI is unavailable")
		if service_owner.call("_selected_character") == null:
			return _error("Classic shop has no selected party member")
		ui.ow_hud._on_InventoryButton_pressed()
		var main_loop := Engine.get_main_loop()
		if main_loop is SceneTree:
			await main_loop.process_frame
		var inventory_rect: Object = ui.ow_hud.inventoryRect
		if not inventory_rect.visible:
			return _error("Realmz inventory did not open for the Classic shop")
		inventory_rect._on_ButtonShop_pressed()
		if not inventory_rect.shopRect.visible:
			return _error("Realmz shop did not open")
		await inventory_rect.shopRect.visibility_changed
	return {
		"shopName": shop_name,
		"itemCount": int(built.get("itemCount", 0)),
	}


func _alter_shop(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.inventory.change-shop":
		if service_owner.classic_bundle == null:
			return _error("Scenario shop catalog is unavailable")
		var shop_id := int(routed_payload.get("shopId", -1))
		var authored_shop: Dictionary = service_owner.classic_bundle.get_shop(
			shop_id
		)
		if authored_shop.is_empty():
			return _error("Scenario shop %d is unavailable" % shop_id)
		var runtime_state := _classic_runtime_state()
		if runtime_state == null:
			return _error("Scenario shop state is unavailable")
		var effective: Dictionary = runtime_state.alter_shop(
			authored_shop,
			int(routed_payload.get("inflationDelta", 0)),
			int(routed_payload.get("itemId", 0)),
			int(routed_payload.get("quantityDelta", 0))
		)
		if effective.is_empty():
			return _error("Scenario shop %d could not be changed" % shop_id)
		routed_payload["shop"] = effective
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var shop_name := "classic_shop_%d" % int(routed_payload.get("shopId", 0))
	if not game_global.shops_dict.has(shop_name):
		return {
			"shopName": shop_name,
			"loaded": false,
			"persisted": true,
			"matchingSlots": _shop_matching_slots(
				routed_payload.get("shop", {}),
				int(routed_payload.get("itemId", 0))
			),
		}
	var native_shop: Variant = game_global.shops_dict[shop_name]
	if not (native_shop is Dictionary):
		return _error("Loaded Classic shop state is invalid")
	var result: Dictionary = service_owner.call(
		"apply_classic_shop_mutation",
		routed_payload,
		native_shop
	)
	result["shopName"] = shop_name
	result["loaded"] = true
	result["persisted"] = true
	return result


static func _shop_matching_slots(shop_value: Variant, item_id: int) -> int:
	if not (shop_value is Dictionary):
		return 0
	var item_ids: Variant = shop_value.get("itemIds", [])
	if not (item_ids is Array):
		return 0
	var matches := 0
	for value: Variant in item_ids:
		if int(value) == item_id:
			matches += 1
	return matches


func _give_treasure(payload: Dictionary) -> Dictionary:
	var routed_payload := payload.duplicate(true)
	if str(routed_payload.get("_scenarioApiOperation", "")) \
			== "core.inventory.give-treasure":
		if service_owner.classic_bundle == null:
			return _error("Scenario treasure catalog is unavailable")
		var treasure_id := int(routed_payload.get("treasureId", -1))
		var treasure: Dictionary = (
			service_owner.classic_bundle.get_treasure(treasure_id)
		)
		if treasure.is_empty():
			return _error(
				"Scenario treasure %d is unavailable" % treasure_id
			)
		routed_payload["treasure"] = treasure
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	if resources == null:
		return _error("Realmz item resources are unavailable")
	var delivery: Dictionary = service_owner.call(
		"build_treasure_delivery_from_catalog",
		routed_payload,
		resources
	)
	if str(delivery.get("status", "")) == "error":
		return delivery
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	await game_global.show_loot_menu(
		delivery.get("items", []),
		delivery.get("money", [0, 0, 0]),
		int(delivery.get("experience", 0))
	)
	return {}


func _drop_party_items(payload: Dictionary) -> Dictionary:
	var party: Array = service_owner.call("_party_characters")
	var result: Dictionary = service_owner.call("drop_all_party_items", party)
	if str(result.get("status", "")) == "error":
		return result
	if int(result.get("itemsRemoved", 0)) > 0:
		result["soundPresentation"] = service_owner.call("_play_sound", payload)
	service_owner.call("_refresh_party_panels", party)
	return result
