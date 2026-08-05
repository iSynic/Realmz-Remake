extends Node

const RogueClass = preload("res://Data/Character Classes/Class_Assassin.gd")
const HumanRace = preload("res://Data/Character Races/Race_Human.gd")
const DefaultIcon = preload("res://scenes/UI/Main Menu/DefaultIcon.png")
const DefaultPortrait = preload(
	"res://scenes/UI/Main Menu/DefaultPortrait.png"
)

var failures: Array[String] = []
var assertions := 0
var _saved_players: Array = []
var _saved_allies: Array = []
var _saved_shop_name := ""
var _saved_shops: Dictionary = {}
var _saved_pool: Array = []


class ManualEncounterHost:
	extends Node

	var active := false
	var rectangle: Dictionary = {}
	var dispatches: Array[Dictionary] = []
	var consumed_doors: Array[int] = []

	func get_random_rectangle(
		_level_type: String,
		_level_index: int,
		_rect_index: int,
	) -> Dictionary:
		return rectangle.duplicate(true)

	func consume_random_rectangle_door(
		_level_type: String,
		_level_index: int,
		_rect_index: int,
		door_index: int,
	) -> Dictionary:
		var percentages: Array = rectangle.get("randomDoorPercent", []).duplicate()
		var previous_percent := int(percentages[door_index])
		if previous_percent > 0:
			percentages[door_index] = 0
			rectangle["randomDoorPercent"] = percentages
			consumed_doors.append(door_index)
		return {
			"status": "ok",
			"consumed": previous_percent > 0,
			"previousPercent": previous_percent,
			"rectangle": rectangle.duplicate(true),
		}

	func has_trigger(trigger_id: String) -> bool:
		return trigger_id in ["Data ED3:macro:42", "Data ED3:macro:43"]

	func run_trigger(
		trigger_id: String,
		start_slot: int,
		context: Dictionary,
	) -> Dictionary:
		dispatches.append({
			"triggerId": trigger_id,
			"startSlot": start_slot,
			"context": context.duplicate(true),
		})
		return {"status": "ok", "reason": "action-point-ended"}


class AreaSearchHost:
	extends Node

	var calls: Array[Dictionary] = []

	func discover_map_secrets(
		position: Vector2i,
		force_detection := false
	) -> Dictionary:
		calls.append({
			"position": position,
			"forceDetection": force_detection,
		})
		return {
			"status": "ok",
			"handled": true,
			"revealed": false,
			"discoveries": [],
		}


class QuietCampaignGlobal:
	extends RefCounted

	var has_on_time_pass := false


func _ready() -> void:
	call_deferred("_run_smoke")


func _run_smoke() -> void:
	await get_tree().process_frame
	var resources: CampaignResources = NodeAccess.__Resources()
	_expect(
		resources.load_item_resources("res://shared_assets/items/"),
		"shared catalog loads for item UI flow smoke",
	)
	_saved_players = GameGlobal.player_characters.duplicate()
	_saved_allies = GameGlobal.player_allies.duplicate()
	_saved_shop_name = GameGlobal.currentShop
	_saved_shops = GameGlobal.shops_dict
	_saved_pool = GameGlobal.money_pool.duplicate()
	_test_combat_ui_layout()
	_test_inventory_equipment_ui(resources)
	_test_shop_purchase_and_sale_ui(resources)
	_test_loot_transfer_ui(resources)
	_test_storage_transfer_ui(resources)
	_test_encounter_item_selection_ui(resources)
	await _test_party_actor_selection_ui()
	await _test_allies_ui()
	await _test_classic_torch_and_search_ui(resources)
	await _test_manual_encounter_dispatch()
	_restore_globals()
	_finish()


func _test_combat_ui_layout() -> void:
	var hud := UI.ow_hud
	var combat_panel = hud.combatBRPanel
	_expect(
		combat_panel.turnorderButton.get_parent() == combat_panel,
		"Turn Order toggle belongs to the lower-right combat action panel",
	)
	var order_panel: TurnOrderPanel = hud.turnorderPanel
	_expect(
		order_panel.get_node("ScrollContainer/VBoxContainer") is VBoxContainer,
		"turn order uses a vertical combatant strip",
	)
	_expect(
		is_equal_approx(order_panel.anchor_bottom, 1.0)
			and is_equal_approx(order_panel.offset_right, 72.0),
		"turn order occupies a bounded left-side viewport rail",
	)
	var debug_controls: VBoxContainer = combat_panel.debugControls
	_expect_equal(
		debug_controls.get_child_count(),
		3,
		"debug combat actions share one aligned control stack",
	)
	_expect(
		debug_controls.get_node("DebugFinish").pressed.is_connected(
			combat_panel._on_debug_finish_pressed
		)
			and debug_controls.get_node("DebugWin").pressed.is_connected(
				combat_panel._on_debug_win_pressed
			)
			and debug_controls.get_node("DebugKill").pressed.is_connected(
				combat_panel._on_debug_kill_pressed
			),
		"debug combat buttons use their dedicated handlers",
	)


func _test_inventory_equipment_ui(resources: CampaignResources) -> void:
	var character := _player("Inventory UI")
	var dagger := resources.create_item_instance("Dagger")
	_expect(character.add_inventory_item(dagger), "inventory fixture owns dagger")
	GameGlobal.player_characters = [character]
	UI.ow_hud.selected_character = character
	var inventory: InventoryControl = UI.ow_hud.inventoryRect
	inventory.fill_inventory_Vbox(inventory.inventoryBoxRight, character)
	var row = inventory.inventoryBoxRight.get_child(0)
	_expect(row.item == dagger, "inventory row retains exact ItemInstance")
	row.equip_item()
	_expect(
		dagger.equipped
			and character.current_melee_weapon_instances.has(dagger),
		"inventory equipment action uses the row ItemInstance",
	)
	_expect(row.iconequipped.visible, "inventory row renders equipped state")
	row.equip_item()
	_expect(not dagger.equipped, "inventory row unequips the same instance")


func _test_shop_purchase_and_sale_ui(resources: CampaignResources) -> void:
	var customer := _player("Shop UI")
	customer.money[0] = 100
	GameGlobal.player_characters = [customer]
	UI.ow_hud.selected_character = customer
	GameGlobal.money_pool = [0, 0, 0]
	GameGlobal.currentShop = "Item UI Smoke Shop"
	GameGlobal.shops_dict = {
		GameGlobal.currentShop: {
			"buy_rate": 0.5,
			"sell_rate": 1.0,
			"accepted_item_names": {"Dagger": true},
			"Weapons": [["Dagger", 1, 20]],
			"Armor": [],
			"Limbs": [],
			"Magic": [],
			"Supplies": [],
			"BuyBack": [],
		},
	}
	var inventory: InventoryControl = UI.ow_hud.inventoryRect
	var shop: ShopRect = inventory.shopRect
	shop.initialize()
	shop._on_ShopButton_pressed("Weapons")
	var shop_row = shop.vbox.get_child(0)
	var stock_item: ItemInstance = shop_row.item
	_expect(
		shop_row.item == stock_item,
		"shop row retains the actual purchasable ItemInstance",
	)
	_expect(
		inventory.purchase_shop_item(customer, stock_item),
		"shop purchase succeeds through the UI service",
	)
	_expect(
		customer.item_inventory.has(stock_item),
		"purchase transfers the exact shop-button instance",
	)
	_expect_equal(customer.money[0], 80, "purchase applies listed price")
	var sold := shop.sell_item(customer, stock_item)
	_expect(bool(sold.get("ok", false)), "shop sale succeeds")
	var stock_definition := resources.get_item_definition(stock_item)
	_expect_equal(
		int(sold.get("price", -1)),
		floori(stock_definition.price * 0.5),
		"sale applies shop buy rate",
	)
	var sold_stock: Array = GameGlobal.get_shop(
		GameGlobal.currentShop
	)["Weapons"]
	_expect(
		sold_stock.back()[0] == stock_item,
		"sale preserves exact ItemInstance in shop stock",
	)


func _test_loot_transfer_ui(resources: CampaignResources) -> void:
	var looter := _player("Loot UI")
	var loot := resources.create_item_instance("Refresh Potion")
	GameGlobal.player_characters = [looter]
	UI.ow_hud.selected_character = looter
	var treasure = UI.ow_hud.treasureControl
	treasure.display([loot], [0, 0, 0], 0)
	var button: Button = treasure.itemsContainer.get_child(0)
	_expect(
		button.get_meta("item_instance") == loot,
		"loot button retains exact ItemInstance",
	)
	treasure._on_itemlootbutton_pressed(loot, button)
	_expect(
		looter.item_inventory.has(loot),
		"loot action transfers the exact button ItemInstance",
	)
	treasure.hide()


func _test_storage_transfer_ui(resources: CampaignResources) -> void:
	var character := _player("Storage UI")
	var stored_item := resources.create_item_instance("Dagger")
	_expect(character.add_inventory_item(stored_item), "storage fixture owns item")
	var storage: Honest_Storage = UI.ow_hud.honestStorageControl
	var saved_storage := storage.storage_inventory.duplicate()
	storage.storage_inventory.clear()
	storage.cur_chara = character
	var character_button := storage.create_chara_item_button(stored_item)
	_expect(
		character_button.get_meta("item_instance") == stored_item,
		"storage character button retains exact ItemInstance",
	)
	character_button.free()
	_expect(
		storage.store_item(character, stored_item),
		"storage accepts an unequipped ItemInstance",
	)
	_expect(
		storage.storage_inventory.has(stored_item)
			and not character.item_inventory.has(stored_item),
		"storage transfer preserves exact identity",
	)
	var storage_button := storage.create_storage_item_button(stored_item)
	_expect(
		storage_button.get_meta("item_instance") == stored_item,
		"stored-item button retains exact ItemInstance",
	)
	storage_button.free()
	var serialized := resources.serialize_item_inventory(
		storage.storage_inventory
	)
	_expect(
		bool(serialized.get("ok", false))
			and serialized.get("value", [])[0].get("formatVersion") == 1,
		"storage writes the versioned ItemInstance schema",
	)
	_expect(
		storage.retrieve_item(character, stored_item),
		"storage returns the item to a character",
	)
	_expect(
		character.item_inventory.has(stored_item)
			and storage.storage_inventory.is_empty(),
		"storage return preserves exact ItemInstance",
	)
	storage.storage_inventory.assign(saved_storage)


func _test_encounter_item_selection_ui(resources: CampaignResources) -> void:
	var character := _player("Encounter UI")
	var selected_item := resources.create_item_instance("Dagger")
	_expect(
		character.add_inventory_item(selected_item),
		"encounter fixture owns item",
	)
	GameGlobal.player_characters = [character]
	UI.ow_hud.selected_character = character
	var picker = UI.ow_hud.encounterControl.useitemRect
	picker.initialize_for_encounter(character)
	var button: Button = picker.itemsContainer.get_child(0)
	_expect(
		button.get_meta("item_instance") == selected_item,
		"encounter button retains exact ItemInstance",
	)
	picker._on_itembutton_pressed(selected_item, character)
	_expect(
		picker.picked_item == selected_item
			and picker.picked_character == character,
		"encounter selection returns exact item and owner",
	)


func _test_party_actor_selection_ui() -> void:
	var first := _player("First Actor")
	var second := _player("Second Actor")
	GameGlobal.player_characters = [first, second]
	var hud: OW_HUD = UI.ow_hud
	hud.fillCharactersRect()
	hud.set_selected_creature(first)
	hud.set_charactersRect_type(1)
	hud.treasureControl.show()
	hud._sync_party_actor_selection()
	var second_panel: CharaSmallPanel = hud.charsVContainer.get_child(1)
	_expect(
		second_panel.selectButton.anchor_right == 1.0,
		"loot mode makes the complete party row a selection target",
	)
	second_panel._on_SelectButton_pressed()
	_expect(
		hud.selected_character == second,
		"loot mode can change the character who receives an item",
	)
	hud.treasureControl.hide()
	hud.textRect.choicesContainer.show()
	hud._sync_party_actor_selection()
	await get_tree().process_frame
	var first_panel: CharaSmallPanel = hud.charsVContainer.get_child(0)
	_expect(
		first_panel.selectButton.anchor_right == 1.0,
		"Classic encounter choices make the complete party row selectable",
	)
	var input_viewport := SubViewport.new()
	input_viewport.size = Vector2i(320, 60)
	add_child(input_viewport)
	hud.charsVContainer.remove_child(first_panel)
	input_viewport.add_child(first_panel)
	first_panel.position = Vector2.ZERO
	first_panel.size = Vector2(320.0, 60.0)
	await get_tree().process_frame
	await _click_control(first_panel.selectButton)
	_expect(
		hud.selected_character == first,
		"a physical encounter-row click changes the character who performs an action",
	)
	input_viewport.remove_child(first_panel)
	hud.charsVContainer.add_child(first_panel)
	hud.charsVContainer.move_child(first_panel, 0)
	input_viewport.queue_free()
	hud.textRect.choicesContainer.hide()
	hud._sync_party_actor_selection()
	_expect(
		first_panel.selectButton.anchor_right == 0.0,
		"party selection returns to the compact arrow outside action contexts",
	)
	hud.set_charactersRect_type(0)


func _click_control(control: Control) -> void:
	var viewport := control.get_viewport()
	var click_position := control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = click_position
	motion.global_position = click_position
	viewport.push_input(motion)
	await get_tree().process_frame
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = click_position
		event.global_position = click_position
		viewport.push_input(event)
		await get_tree().process_frame


func _test_allies_ui() -> void:
	var ally := Creature.new()
	ally.name = "Vodalian"
	ally.level = 11
	ally.is_npc_ally = true
	ally.textureR = DefaultPortrait
	ally.stats["curHP"] = 21
	ally.stats["maxHP"] = 21
	ally.stats["curSP"] = 90
	ally.stats["maxSP"] = 90
	ally.stats["MaxMovement"] = 12
	ally.set_meta("classic_armor", 25)
	ally.set_meta("classic_magic_resistance", 8)
	var traveling_allies: Array = [ally]
	for index in range(5):
		var companion := Creature.new()
		companion.name = "Companion %d" % (index + 1)
		companion.is_npc_ally = true
		companion.textureR = DefaultPortrait
		companion.stats["curHP"] = 10
		companion.stats["maxHP"] = 10
		traveling_allies.append(companion)
	GameGlobal.player_allies = traveling_allies
	var hud: OW_HUD = UI.ow_hud
	hud.fillCharactersRect()
	await get_tree().process_frame
	_expect_equal(
		hud.charsVContainer.get_child_count(),
		GameGlobal.player_characters.size() + traveling_allies.size(),
		"allies appear after player characters in the party rail",
	)
	var ally_panel: CharaSmallPanel = hud.charsVContainer.get_child(
		GameGlobal.player_characters.size()
	)
	_expect(
		ally_panel.paneltype == 1 and ally_panel.character == ally,
		"the first ally retains its live creature identity in the party rail",
	)
	var party_scrollbar: VScrollBar = hud.charscrollcont.get_v_scroll_bar()
	_expect(
		hud.charscrollcont.vertical_scroll_mode \
			== ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
			and party_scrollbar.visible,
		"the party rail provides a persistent visible scrollbar",
	)
	_expect(
		party_scrollbar.max_value > party_scrollbar.page,
		"the party scrollbar owns overflow when characters and allies exceed the rail",
	)
	var portrait_viewport := SubViewport.new()
	portrait_viewport.size = Vector2i(320, 60)
	add_child(portrait_viewport)
	var ally_panel_index := ally_panel.get_index()
	hud.charsVContainer.remove_child(ally_panel)
	portrait_viewport.add_child(ally_panel)
	ally_panel.position = Vector2.ZERO
	ally_panel.size = Vector2(320.0, 60.0)
	await get_tree().process_frame
	await _click_control(ally_panel.faceButton)
	_expect_equal(
		hud.characterStatRect.name_label.text,
		"Vodalian",
		"clicking an ally portrait opens that ally's details from the party rail",
	)
	_expect_equal(
		hud.characterStatRect.description_header_label.text,
		"Equipment & Classic Details",
		"the party-rail ally view identifies its Classic detail section",
	)
	_expect(
		not hud.characterStatRect.descr_label.text.contains("NOTES"),
		"ally details do not expose an unsupported free-floating notes section",
	)
	hud.characterStatRect.hide()
	portrait_viewport.remove_child(ally_panel)
	hud.charsVContainer.add_child(ally_panel)
	hud.charsVContainer.move_child(ally_panel, ally_panel_index)
	portrait_viewport.queue_free()

	var input_viewport := SubViewport.new()
	input_viewport.size = Vector2i(1152, 648)
	add_child(input_viewport)
	var allies_screen: AlliesRect = preload(
		"res://scenes/UI/HUD/Allies/allies_rect.tscn"
	).instantiate()
	input_viewport.add_child(allies_screen)
	await get_tree().process_frame
	allies_screen.fill([ally])
	await get_tree().process_frame
	_expect_equal(
		allies_screen.entry_container.get_child_count(),
		1,
		"the Allies menu renders each live companion as a roster entry",
	)
	_expect_equal(
		allies_screen.info_panel.name_label.text,
		"Vodalian",
		"selecting an ally populates the shared detail panel",
	)
	var detail_scroll: ScrollContainer = allies_screen.get_node(
		"OuterMargin/MainVBox/Body/InfoScroll"
	)
	var detail_scrollbar: VScrollBar = detail_scroll.get_v_scroll_bar()
	_expect(
		detail_scrollbar.max_value > detail_scrollbar.page,
		"the compact Allies window scrolls its complete detail panel instead of collapsing it",
	)
	_expect(
		not allies_screen.info_panel.close_button.visible,
		"the embedded detail panel does not add a second overlapping close action",
	)
	var row = allies_screen.entry_container.get_child(0)
	await _click_control(row.retain_button)
	_expect(
		not row.is_retained(),
		"a physical click can remove an ally from the retained party",
	)
	await _click_control(row.retain_button)
	_expect(
		row.is_retained(),
		"a second physical click restores the ally retention choice",
	)
	input_viewport.remove_child(allies_screen)
	allies_screen.queue_free()
	input_viewport.queue_free()
	GameGlobal.player_allies = []
	hud.fillCharactersRect()
	_expect_equal(
		hud.charsVContainer.get_child_count(),
		GameGlobal.player_characters.size(),
		"removing allies removes their party-rail entries without a separate HUD action",
	)


func _test_classic_torch_and_search_ui(resources: CampaignResources) -> void:
	var torch: ClassicTorchButton = preload(
		"res://scenes/UI/HUD/ClassicTorch/classic_torch_button.tscn"
	).instantiate()
	add_child(torch)
	await get_tree().process_frame
	torch.sync_status(true, 0, true, true)
	_expect(
		torch.size == Vector2(32.0, 78.0)
			and torch.fuel_segment_count() == 2,
		"the tall Torch button contains Realmz's two-segment unlit stump",
	)
	_expect(
		torch.artwork_bounds() == Rect2(12.0, 50.0, 8.0, 22.0),
		"the unlit Torch stump uses native-size source segments",
	)
	torch.sync_status(true, 119, true, true)
	var full_lit_bounds := torch.artwork_bounds()
	_expect(
		torch.fuel_segment_count() == 4
			and torch.flame_y() == 7
			and full_lit_bounds == Rect2(8.0, 11.0, 16.0, 61.0),
		"a fresh Torch fills the tall button with its flame and fuel column",
	)
	torch.sync_status(true, 1, true, true)
	var burned_down_bounds := torch.artwork_bounds()
	_expect(
		torch.fuel_segment_count() == 1
			and torch.flame_y() == ClassicTorchButton.FLAME_BASE_Y
			and burned_down_bounds.position.y > full_lit_bounds.position.y
			and burned_down_bounds.size.y < full_lit_bounds.size.y,
		"the flame and fuel column burn downward with the Classic condition",
	)
	torch.sync_status(true, 0, false, false)
	_expect(
		torch.artwork_bounds() == Rect2(),
		"the Torch image is absent when the party owns no Torch",
	)
	torch.queue_free()
	UI.ow_hud._layout_action_dock(Vector2(320.0, 200.0))
	_expect(
		UI.ow_hud.classicTorchButton.size == Vector2(32.0, 78.0)
			and UI.ow_hud.globaleffectsRect.size == Vector2(109.0, 73.0)
			and not Rect2(
				UI.ow_hud.classicTorchButton.position,
				UI.ow_hud.classicTorchButton.size
			).intersects(Rect2(
				UI.ow_hud.globaleffectsRect.position,
				UI.ow_hud.globaleffectsRect.size
			)),
		"the non-square Torch button fits beside the wider Effects grid without overlap",
	)
	_expect(
		UI.ow_hud.globaleffectsRect.eye_sprite.position == Vector2(74.0, 2.0)
			and UI.ow_hud.globaleffectsRect.sentry_sprite.position == Vector2(74.0, 38.0),
		"Effects use two native-height rows and three columns",
	)
	var system_buttons: Array[Button] = [
		UI.ow_hud.get_node("VBoxScreen/HBoxBot/BotUtilityPanel/CharSwapButton"),
		UI.ow_hud.get_node("VBoxScreen/HBoxBot/BotUtilityPanel/QSaveButton"),
		UI.ow_hud.get_node("VBoxScreen/HBoxBot/BotUtilityPanel/SaveButton"),
		UI.ow_hud.get_node("VBoxScreen/HBoxBot/BotUtilityPanel/SettingsButton"),
	]
	var system_row_layout_matches := true
	for button: Button in system_buttons:
		if button.position.y != 139.0 or button.size != Vector2(48.0, 48.0):
			system_row_layout_matches = false
			break
	_expect(
		system_row_layout_matches,
		"Swap, Quick Save, Save, and Settings share one System row",
	)
	_expect(
		UI.ow_hud.botrightpanel.custom_minimum_size.x == 320.0
			and UI.ow_hud.charactersrect.custom_minimum_size.x == 320.0,
		"the gameplay console aligns with the Classic party rail",
	)
	_expect(
		UI.ow_hud.botutilitypanel.custom_minimum_size.x == 220.0
			and UI.ow_hud.areaSearchButton.position == Vector2(112.0, 132.0),
		"the separate utility console leaves a full Context row for Area Search",
	)
	_expect(
		not UI.ow_hud.classicSearchButton.has_node("LabelBackdrop")
			and not UI.ow_hud.get_node(
				"VBoxScreen/HBoxBot/BotRightPanel/EncounterButton"
			).has_node("LabelBackdrop"),
		"Encounter and Search use the shared button face without black label overlays",
	)
	var encounter_button: Button = UI.ow_hud.get_node(
		"VBoxScreen/HBoxBot/BotRightPanel/EncounterButton"
	)
	var action_buttons: Array[Button] = [
		encounter_button,
		UI.ow_hud.classicSearchButton,
		UI.ow_hud.areaSearchButton,
	]
	var expected_action_textures := [
		"/Button_EncounterAction.png",
		"/Button_Search.png",
		"/Button_AreaSearch.png",
	]
	var actions_use_native_button_art := true
	for index in action_buttons.size():
		var button := action_buttons[index]
		actions_use_native_button_art = (
			actions_use_native_button_art
			and button.icon != null
			and button.icon.get_size() == Vector2(50.0, 50.0)
			and button.icon.resource_path.ends_with(expected_action_textures[index])
			and not button.has_node("Label")
		)
	_expect(
		actions_use_native_button_art,
		"Encounter, Search, and Area Search use complete native-size Classic button art",
	)

	var saved_session: Object = GameGlobal.classic_campaign_session
	var saved_host: Object = GameGlobal.classic_runtime_host
	var saved_conditions := GameGlobal.classic_party_conditions.duplicate(true)
	var saved_effects := GameGlobal.global_effects.duplicate(true)
	var saved_state: State = StateMachine.state
	var saved_time := GameGlobal.time
	var saved_fatigue := GameGlobal.fatigue
	var saved_camping := GameGlobal.camping
	var saved_campaign_global: Variant = GameGlobal.campaign_global_script
	var dummy_session := Node.new()
	var area_search_host := AreaSearchHost.new()
	add_child(dummy_session)
	add_child(area_search_host)
	GameGlobal.classic_campaign_session = dummy_session
	GameGlobal.classic_runtime_host = area_search_host
	GameGlobal.campaign_global_script = QuietCampaignGlobal.new()
	GameGlobal.camping = false
	GameGlobal.fatigue = 4.0
	var torch_holder := _player("Torch Initialization")
	var inventory_torch := resources.create_item_instance("Torch")
	_expect(
		torch_holder.add_inventory_item(inventory_torch),
		"Torch initialization fixture owns a usable Torch",
	)
	GameGlobal.player_characters = [torch_holder]
	_expect(
		StateMachine.ensure_gameplay_states_loaded(),
		"Torch initialization test has the exploration state graph",
	)
	StateMachine.set_state(StateMachine.exploration_state.get_node("ExAnim"))
	_expect(
		UI.ow_hud.classicTorchButton.disabled,
		"the Torch is unavailable while an exploration movement is active",
	)
	StateMachine.set_state(StateMachine.exploration_state)
	_expect(
		not UI.ow_hud.classicTorchButton.disabled,
		"returning to exploration enables the Torch without another UI click",
	)
	GameGlobal.set_classic_search_enabled(false)
	GameGlobal.global_effects["Awareness"]["Duration"] = 0
	UI.ow_hud.updateGlobalEffectsDisplay()
	_expect(
		not UI.ow_hud.classicSearchEffectButton.visible
			and not UI.ow_hud.globaleffectsRect.eye_sprite.visible,
		"Search contributes no effect-slot artwork while inactive",
	)
	GameGlobal.set_classic_search_enabled(true)
	UI.ow_hud.updateGlobalEffectsDisplay()
	_expect(
		UI.ow_hud.classicSearchEffectButton.visible
			and UI.ow_hud.globaleffectsRect.eye_sprite.visible,
		"active Search displays its animated effect slot",
	)
	GameGlobal.set_classic_search_enabled(false)
	UI.ow_hud.updateGlobalEffectsDisplay()
	var area_search_start_time := GameGlobal.time
	UI.ow_hud._on_area_search_button_down()
	_expect(
		area_search_host.calls.size() == 1
			and bool(area_search_host.calls[0].get("forceDetection")),
		"pressing Area Search forces one source-backed three-by-three check",
	)
	_expect(
		GameGlobal.time > area_search_start_time
			and not UI.ow_hud.areaSearchTimer.is_stopped(),
		"holding Area Search advances Classic time and schedules another pass",
	)
	UI.ow_hud._on_area_search_button_up()
	_expect(
		UI.ow_hud.areaSearchTimer.is_stopped(),
		"releasing Area Search immediately stops its repeated checks",
	)
	GameGlobal.classic_campaign_session = saved_session
	GameGlobal.classic_runtime_host = saved_host
	GameGlobal.classic_party_conditions = saved_conditions
	GameGlobal.global_effects = saved_effects
	GameGlobal.time = saved_time
	GameGlobal.fatigue = saved_fatigue
	GameGlobal.camping = saved_camping
	GameGlobal.campaign_global_script = saved_campaign_global
	StateMachine.set_state(saved_state)
	dummy_session.queue_free()
	area_search_host.queue_free()


func _test_manual_encounter_dispatch() -> void:
	var saved_session: Object = GameGlobal.classic_campaign_session
	var saved_host: Object = GameGlobal.classic_runtime_host
	var saved_areas := GameGlobal.map.mapscriptareas.duplicate(true)
	var host := ManualEncounterHost.new()
	var dummy_session := Node.new()
	add_child(host)
	add_child(dummy_session)
	GameGlobal.classic_campaign_session = dummy_session
	GameGlobal.classic_runtime_host = host

	host.rectangle = {
		"rectIndex": 1,
		"left": 4,
		"top": 5,
		"right": 8,
		"bottom": 9,
		"percent": -1,
		"only": false,
		"randomDoors": [42, 0, 0],
		"randomDoorPercent": [-100, 0, 0],
		"battleRange": [0, 0],
	}
	GameGlobal.map.mapscriptareas = {
		"LRR0.1": GameGlobal.ClassicRandomRectangleScript.project_area(
			"land",
			0,
			host.rectangle,
			"",
		),
	}
	var repeatable_outcome: int = await GameGlobal.check_classic_manual_encounter_rectangles(
		Vector2i(6, 7)
	)
	_expect(
		repeatable_outcome == GameGlobal.ClassicRandomRectangleScript.Outcome.TRIGGER_DISPATCHED
			and host.dispatches[-1]["triggerId"] == "Data ED3:macro:42"
			and bool(host.dispatches[-1]["context"].get("manualEncounter", false))
			and bool(host.dispatches[-1]["context"].get("seamless", false)),
		"Encounter dispatches the current manual rectangle through the Classic runtime",
	)

	host.rectangle["randomDoors"] = [43, 0, 0]
	host.rectangle["randomDoorPercent"] = [100, 0, 0]
	var one_shot_outcome: int = await GameGlobal.check_classic_manual_encounter_rectangles(
		Vector2i(6, 7)
	)
	_expect(
		one_shot_outcome == GameGlobal.ClassicRandomRectangleScript.Outcome.TRIGGER_DISPATCHED
			and host.dispatches[-1]["triggerId"] == "Data ED3:macro:43"
			and host.consumed_doors == [0]
			and int(host.rectangle["randomDoorPercent"][0]) == 0,
		"Encounter consumes a positive one-shot random-door result",
	)
	var consumed_outcome: int = await GameGlobal.check_classic_manual_encounter_rectangles(
		Vector2i(6, 7)
	)
	_expect(
		consumed_outcome == GameGlobal.ClassicRandomRectangleScript.Outcome.NONE,
		"a consumed manual encounter does not dispatch again",
	)

	GameGlobal.map.mapscriptareas = saved_areas
	GameGlobal.classic_runtime_host = saved_host
	GameGlobal.classic_campaign_session = saved_session
	host.queue_free()
	dummy_session.queue_free()


func _player(character_name: String) -> PlayerCharacter:
	return GameGlobal.playerCharacterGD.new(
		{
			"name": character_name,
			"level": 1,
			"exp_tnl": 10000,
		},
		DefaultIcon,
		DefaultPortrait,
		RogueClass,
		HumanRace,
	)


func _restore_globals() -> void:
	GameGlobal.player_characters = _saved_players
	GameGlobal.player_allies = _saved_allies
	GameGlobal.currentShop = _saved_shop_name
	GameGlobal.shops_dict = _saved_shops
	GameGlobal.money_pool = _saved_pool


func _expect(condition: bool, description: String) -> void:
	assertions += 1
	if condition:
		print("PASS: %s" % description)
		return
	failures.append(description)
	push_error("FAIL: %s" % description)


func _expect_equal(
	actual: Variant,
	expected: Variant,
	description: String,
) -> void:
	_expect(
		actual == expected,
		"%s (expected %s, got %s)" % [description, expected, actual],
	)


func _finish() -> void:
	if failures.is_empty():
		print("Item UI flow smoke passed: %d assertions." % assertions)
		get_tree().quit(0)
		return
	printerr("Item UI flow smoke failed: %s" % "; ".join(failures))
	get_tree().quit(1)
