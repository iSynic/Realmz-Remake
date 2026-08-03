extends HBoxContainer

signal selected(row)
signal retained_changed(row, retained)

var creature: Creature
var summoner_name := ""

@onready var select_button: Button = $SelectButton
@onready var icon_rect: TextureRect = $SelectButton/ContentMargin/Content/IconFrame/Icon
@onready var name_label: Label = $SelectButton/ContentMargin/Content/Text/Name
@onready var detail_label: Label = $SelectButton/ContentMargin/Content/Text/Detail
@onready var retain_button: Button = $RetainButton


func configure(
	creature_value: Creature,
	detail_text: String,
	retained: bool,
	summoner: String = ""
) -> void:
	creature = creature_value
	summoner_name = summoner
	icon_rect.texture = creature.textureR
	name_label.text = creature.name
	detail_label.text = detail_text
	retain_button.set_pressed_no_signal(retained)
	retain_button.tooltip_text = (
		"Keep %s with the party" % creature.name
		if retained
		else "Add %s to the traveling party" % creature.name
	)


func set_selected(value: bool) -> void:
	select_button.set_pressed_no_signal(value)


func is_retained() -> bool:
	return retain_button.button_pressed


func _on_select_button_pressed() -> void:
	selected.emit(self)


func _on_retain_button_toggled(value: bool) -> void:
	retain_button.tooltip_text = (
		"Keep %s with the party" % creature.name
		if value
		else "Add %s to the traveling party" % creature.name
	)
	retained_changed.emit(self, value)
