extends NinePatchRect

@onready var itemLootButton: PackedScene = preload(
	"res://scenes/UI/HUD/Looting/ItemLootButton.tscn"
)
@onready var charportrait: TextureRect = $CharFaceRect
@onready var charnamelabel: Label = $CharNameLabel
@onready var itemsContainer = $itemsRect/ScrollContainer/ItemContainer
@onready var itempreview = $ItemPreview

var character: Creature = null
enum { ALL, FIELD, BATTLE }
var itemkind := ALL
var encounter_selection_mode := false
var picked_item: ItemInstance = null
var picked_character: Creature = null

signal item_picked
signal encounter_item_picked


func display_character_inventory() -> void:
	if character == null:
		return
	charportrait.texture = character.portrait
	charnamelabel.text = character.name
	itempreview.clear_item()
	for child: Node in itemsContainer.get_children():
		child.queue_free()
	var resources = NodeAccess.__Resources()
	for item: ItemInstance in character.inventory_instances():
		var definition := resources.get_item_definition(item)
		if definition == null or not _matches_filter(definition):
			continue
		var button: Button = itemLootButton.instantiate()
		button.set_meta("item_instance", item)
		button.find_child("ItemTextureRect").texture = (
			resources.item_texture(item)
		)
		button.pressed.connect(_on_itembutton_pressed.bind(item, character))
		button.mouse_entered.connect(_on_itembutton_mouse_entered.bind(item))
		button.mouse_exited.connect(_on_itembutton_mouse_exited)
		itemsContainer.add_child(button)


func initialize_for_encounter(chara: Creature) -> void:
	encounter_selection_mode = true
	picked_item = null
	picked_character = null
	character = chara
	itemkind = ALL
	display_character_inventory()


func _on_LeftButton_pressed() -> void:
	var charindex := GameGlobal.player_characters.find(character)
	character = GameGlobal.player_characters[
		(charindex - 1 + GameGlobal.player_characters.size())
		% GameGlobal.player_characters.size()
	]
	display_character_inventory()


func _on_RightButton_pressed() -> void:
	var charindex := GameGlobal.player_characters.find(character)
	character = GameGlobal.player_characters[
		(charindex + 1) % GameGlobal.player_characters.size()
	]
	display_character_inventory()


func _on_itembutton_mouse_entered(item: ItemInstance) -> void:
	itempreview.set_item(item)


func _on_itembutton_mouse_exited() -> void:
	itempreview.clear_item()


func _on_itembutton_pressed(item: ItemInstance, chara: Creature) -> void:
	if encounter_selection_mode:
		encounter_selection_mode = false
		picked_item = item
		picked_character = chara
		hide()
		encounter_item_picked.emit()
		return
	item_picked.emit(item, chara)


func _on_CancelButton_pressed() -> void:
	hide()
	if encounter_selection_mode:
		encounter_selection_mode = false
		picked_item = null
		picked_character = null
		encounter_item_picked.emit()


func _matches_filter(definition: ItemDefinition) -> bool:
	match itemkind:
		FIELD:
			return definition.has_use("field") \
				or _scenario_has_use(definition, "field_use")
		BATTLE:
			return definition.has_use("combat") \
				or _scenario_has_use(definition, "combat_use")
	return true


func _scenario_has_use(definition: ItemDefinition, hook_kind: String) -> bool:
	var host: Variant = GameGlobal.classic_runtime_host
	if not is_instance_valid(host) or not host.has_method("has_item_behavior"):
		return false
	for character_value: Variant in GameGlobal.player_characters:
		if not (character_value is Object) \
				or not character_value.has_method("inventory_instances"):
			continue
		for instance_value: Variant in character_value.call("inventory_instances"):
			if instance_value is Object \
					and str(instance_value.get("definition_id")) == definition.definition_id:
				return bool(host.call(
					"has_item_behavior",
					instance_value,
					hook_kind
				))
	return false
