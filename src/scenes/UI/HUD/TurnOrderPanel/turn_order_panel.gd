extends Panel
class_name TurnOrderPanel

@onready var box: VBoxContainer = $ScrollContainer/VBoxContainer

# Called when the node enters the scene tree for the first time.
func update_display() -> void:
	for child: Node in box.get_children():
		box.remove_child(child)
		child.queue_free()
	var battle_creatures_yet_to_act_btns: Array = (
		StateMachine.combat_state.battle_creatures_yet_to_act_btns
	)
	for cb: CombatCreaButton in battle_creatures_yet_to_act_btns:
		var nbutton: Button = Button.new()
		nbutton.icon = cb.sprite.texture
		nbutton.custom_minimum_size = Vector2(56.0, 56.0)
		nbutton.expand_icon = true
		nbutton.focus_mode = Control.FOCUS_NONE
		nbutton.tooltip_text = cb.creature.name
		nbutton.mouse_entered.connect(UI.ow_hud._on_mouse_enter_combat_crea_button.bind(cb))
		nbutton.mouse_exited.connect(UI.ow_hud._on_mouse_exit_combat_crea_button)
		box.add_child(nbutton)

func _on_mouse_entered():
	#UI.ow_hud._on_mouse_enter_combat_crea_button(self)
	GameGlobal.map.mouseinside = true


func _on_mouse_exited():
	UI.ow_hud._on_mouse_exit_combat_crea_button()
