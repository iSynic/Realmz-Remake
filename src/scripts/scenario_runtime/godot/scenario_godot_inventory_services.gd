class_name ScenarioGodotInventoryServices
extends "res://scripts/scenario_runtime/godot/scenario_godot_domain_service.gd"

const InventoryRulesScript = preload(
	"res://scripts/classic_runtime/classic_inventory_rules.gd"
)


func classic_save_state() -> Dictionary:
	return service_owner.call("classic_save_state")


func restore_classic_save_state(saved_state: Dictionary) -> Dictionary:
	return service_owner.call("restore_classic_save_state", saved_state)


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
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	if resources == null:
		return _error("Realmz item resources are unavailable")
	var built: Dictionary = service_owner.call(
		"build_shop_inventory_from_catalog",
		payload,
		resources
	)
	if str(built.get("status", "")) == "error":
		return built
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var shop_name := "classic_shop_%d" % int(payload.get("shopId", 0))
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

	if bool(payload.get("openImmediately", false)):
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
	var game_global: Object = _autoload("GameGlobal")
	if game_global == null:
		return _error("Realmz game state is unavailable")
	var shop_name := "classic_shop_%d" % int(payload.get("shopId", 0))
	if not game_global.shops_dict.has(shop_name):
		return {
			"shopName": shop_name,
			"loaded": false,
			"persisted": true,
		}
	var native_shop: Variant = game_global.shops_dict[shop_name]
	if not (native_shop is Dictionary):
		return _error("Loaded Classic shop state is invalid")
	var result: Dictionary = service_owner.call(
		"apply_classic_shop_mutation",
		payload,
		native_shop
	)
	result["shopName"] = shop_name
	result["loaded"] = true
	result["persisted"] = true
	return result


func _give_treasure(payload: Dictionary) -> Dictionary:
	var node_access: Object = _autoload("NodeAccess")
	var resources: Object = node_access.__Resources() if node_access != null else null
	if resources == null:
		return _error("Realmz item resources are unavailable")
	var delivery: Dictionary = service_owner.call(
		"build_treasure_delivery_from_catalog",
		payload,
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
