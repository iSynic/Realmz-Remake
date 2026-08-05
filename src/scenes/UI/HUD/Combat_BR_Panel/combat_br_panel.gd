extends TextureRect

var hud : OW_HUD
@onready var autobutton : Button = $AutoButton
@onready var spellbutton : Button = $SpellButton
@onready var inventorybutton : Button= $InventoryButton

@onready var finishbutton : Button = $FinishButton
@onready var preparebutton : Button = $PrepareButton
@onready var turnundeadbutton : Button = $TurnUndeadButton
@onready var turnorderButton : CheckButton = $TurnOrderButton
@onready var debugControls : VBoxContainer = $DebugControls
@onready var buttons : Array = [
	autobutton,
	spellbutton,
	inventorybutton,
	finishbutton,
	turnundeadbutton,
]

var escape_allowed : bool = true

# Called when the node enters the scene tree for the first time.
func _ready():
	debugControls.visible = OS.is_debug_build()


func prepare_for_creab( creab : CombatCreaButton ) :
	var controllable : bool =  creab.creature.curFaction == 0
	turnundeadbutton.visible = controllable and StateMachine.combat_state.can_turn_undead(creab)
	if controllable :
		var already_prepared : bool = false
		for t in creab.creature.traits :
			if t.get("trait_types") :
				if t.trait_types.has("Prep.") :
					if not t.prep_can_use_every_round :
						already_prepared = true
						break
		preparebutton.disabled = already_prepared
	
	for b in buttons :
		b.disabled = not controllable
	spellbutton.disabled = creab.creature.spells.is_empty()
	turnundeadbutton.disabled = not turnundeadbutton.visible
	_set_debug_buttons_enabled(StateMachine._state_name == "CbDecideAction")
	
func set_buttons_enabled(enabled : bool) -> void :
	for b in get_children() :
		if b.is_class("BaseButton") and b != turnorderButton:
			if b == inventorybutton :
				b.disabled = false
			else :
				b.disabled = not enabled
	_set_debug_buttons_enabled(enabled)

func enable_all(crea : Creature) :
	for b in get_children() :
		if b.is_class("BaseButton") and b != turnorderButton:
			b.disabled = false
	spellbutton.disabled = (crea.spells.size()==0)
	_set_debug_buttons_enabled(true)

func _on_finish_button_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		if StateMachine.state.current_active_creabutton.creature.is_crea_player_controlled() :
			StateMachine.state.end_active_creature_turn(false)


func _on_auto_button_pressed() -> void:
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name != "CbDecideAction":
		return
	var active_button: CombatCreaButton = (
		StateMachine.cb_decide_state.current_active_creabutton
	)
	if not is_instance_valid(active_button) \
			or not active_button.creature.is_crea_player_controlled():
		return
	set_buttons_enabled(false)
	StateMachine.cb_decide_state.begin_player_auto_turn(active_button.creature)


func _on_InventoryButton_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine.cb_decide_state.current_active_creabutton.creature.is_crea_player_controlled() :
		if ["CbDecideAction","CbMenus"].has(StateMachine._state_name) :
			hud._on_InventoryButton_pressed()

func _on_SpellButton_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		hud._on_SpellButton_pressed()


func _on_debug_finish_pressed() -> void:
	if not _debug_action_available():
		return
	StateMachine.cb_decide_state.end_active_creature_turn(false)


func _on_debug_win_pressed() -> void:
	if not _debug_action_available():
		return
	var defeated_any := false
	for cb: CombatCreaButton in (
		StateMachine.combat_state.all_battle_creatures_btns.duplicate()
	):
		if is_instance_valid(cb) \
				and cb.creature.curFaction != 0 \
				and cb.creature.get_stat("curHP") > 0:
			cb.creature.change_cur_hp(-999999999)
			defeated_any = true
	if defeated_any:
		StateMachine.transition_to("Combat/CbAnimation")


func _on_debug_kill_pressed() -> void:
	if not _debug_action_available():
		return
	var target := _debug_target_button()
	if not is_instance_valid(target) or target.creature.get_stat("curHP") <= 0:
		return
	target.creature.change_cur_hp(-999999999)
	StateMachine.transition_to("Combat/CbAnimation")


func _on_turn_order_button_toggled(toggled_on: bool) -> void:
	if is_instance_valid(hud):
		hud._on_turn_order_button_toggled(toggled_on)


func _debug_action_available() -> bool:
	return (
		OS.is_debug_build()
		and StateMachine._state_name == "CbDecideAction"
		and is_instance_valid(StateMachine.cb_decide_state.current_active_creabutton)
	)


func _debug_target_button() -> CombatCreaButton:
	for cb: CombatCreaButton in StateMachine.combat_state.all_battle_creatures_btns:
		if is_instance_valid(cb) and cb.creature == hud.selected_character:
			return cb
	var displayed: Variant = hud.creatureRect.my_crea_button
	if is_instance_valid(displayed) \
			and StateMachine.combat_state.all_battle_creatures_btns.has(displayed):
		return displayed as CombatCreaButton
	return StateMachine.cb_decide_state.current_active_creabutton


func _set_debug_buttons_enabled(enabled: bool) -> void:
	for child: Node in debugControls.get_children():
		if child is BaseButton:
			child.disabled = not enabled


func _on_guard_button_pressed():
	print("\n\n\n\n\n\n Combat_br_panel GUARD BUTTON PRESSED \n\n\n\n\n\n")
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		var active_cb : CombatCreaButton = StateMachine.combat_state.get_selected_character_combatbutton()
		if active_cb.creature.get("classgd") : #is a PlayerCharacter
			active_cb.creature.start_guarding()
		else :
			var traitscript = load('res://shared_assets/traits/'+'guarding.gd')
			active_cb.creature.add_trait(traitscript, [active_cb.creature])
		hud._on_guard_button_pressed()
		StateMachine.state.end_active_creature_turn(false)


func _on_parry_button_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		var active_cb : CombatCreaButton = StateMachine.combat_state.get_selected_character_combatbutton()
		if active_cb.creature.get("classgd") : #is a PlayerCharacter
			active_cb.creature.start_parrying()
		else :
			var traitscript = load('res://shared_assets/traits/'+'parrying.gd')
			active_cb.creature.add_trait(traitscript, [active_cb.creature])
		hud._on_parry_button_pressed()
		StateMachine.state.end_active_creature_turn(false)


func _on_delay_button_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		if StateMachine.state.current_active_creabutton.creature.is_crea_player_controlled() :
			StateMachine.state.delay_active_creature_turn()


func _on_prepare_button_pressed():
	hud.creatureRect._on_mouse_entered()
	if StateMachine._state_name == "CbDecideAction" :
		var active_cb : CombatCreaButton = StateMachine._state.get_selected_character_combatbutton()
		if active_cb.creature.get("classgd") : #is a PlayerCharacter
			active_cb.creature.start_preparing()
		else :
			var traitscript = load('res://shared_assets/traits/'+'preparing.gd')
			active_cb.creature.add_trait(traitscript, [active_cb.creature])
		hud._on_parry_button_pressed()


func _on_escape_button_pressed():
	var sounds_book = NodeAccess.__Resources().get_sounds_book()
	if StateMachine._state_name == "CbDecideAction" :
		var success : bool = true
		var active_cb : CombatCreaButton = StateMachine.combat_state.get_selected_character_combatbutton()
		var crea : Creature = active_cb.creature
		for cb : CombatCreaButton in StateMachine.combat_state.all_battle_creatures_btns :
			if cb.creature.curFaction != 0 and active_cb.creature.position.distance_to(cb.creature.position)<=10:
				success = false
		if success :
			crea.fled_battle = true
			StateMachine.cb_decide_state.end_active_creature_turn(true)
			active_cb.leave_combat()
		else :
			SfxPlayer.stream = sounds_book["target error.wav"]
			SfxPlayer.play()
		#_on_finish_button_pressed()
		#print("CombatBRPanel _on_escape_button_pressed success ? "+str(success))
		

func _on_bandage_button_pressed():
	if not StateMachine._state_name == "CbDecideAction" :
		return
	var picked_characters : Array = await StateMachine.state.request_picked_menu_charas(1, true)

	var sounds_book = GameGlobal.cmp_resources.get_sounds_book()

	if not picked_characters.is_empty() and picked_characters[0].life_status==1 :
		var crea : Creature = picked_characters[0]
		crea.life_status = 2
		crea.change_cur_hp(0)
		SfxPlayer.stream = sounds_book["Target On.wav"]
		UI.ow_hud.updateCharPanelDisplay()
		StateMachine.cb_decide_state.end_active_creature_turn(true)
		UI.ow_hud.creatureRect.logrect.log_bandage(StateMachine.state.current_active_creabutton.creature, crea)
	else :
		SfxPlayer.stream = sounds_book["target error.wav"]
	SfxPlayer.play()


func _on_turn_undead_button_pressed() -> void:
	if StateMachine._state_name != "CbDecideAction":
		return
	var caster_button: CombatCreaButton = StateMachine.cb_decide_state.current_active_creabutton
	if not StateMachine.combat_state.can_turn_undead(caster_button):
		return
	hud.creatureRect._on_mouse_entered()
	StateMachine.combat_state.add_to_action_queue([{
		"type": "TurnUndead",
		"caster": caster_button,
	}])
	StateMachine.transition_to("Combat/CbAnimation")
