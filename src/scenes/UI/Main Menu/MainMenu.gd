extends Control

@export var newprofileVBox : VBoxContainer
@export var honest_mode_label : Label

@export var profilebutton : Button
@export var profilespopup : PopupMenu
@onready var splashArt : TextureRect = $TextureRect
@onready var volcanoFlame : AnimatedSprite2D = $TextureRect/ClassicVolcanoFlame
@onready var newProfilePanel : NinePatchRect = $NewProfilePanel
@onready var newProfileNameEdit : LineEdit = (
	$NewProfilePanel/MarginContainer/NewProfileVBox/NameRow/LineEdit
)
@onready var newProfileToggleButton : Button = $TopBar/NewProfileToggleButton
@onready var newCampaignButton : Button = $BottomMenu/NewCampaignButton
@onready var newCampaignPanel : NinePatchRect = $NewCampaignPanel
@onready var newCharacterButton : Button = $BottomMenu/NewCharacterButton
@onready var loadgameButton : Button = $BottomMenu/LoadButton
@onready var loadgameWindow : Window = $LoadWindow
@onready var loadgameCtrl : SaveLoadCtrl = $LoadWindow/SaveLoadRect
@onready var newCharacterPanel : NinePatchRect = $NewCharacterPanel
@onready var hdModeCheckButton : CheckButton = $TopBar/HDButton
var profileslist : Array =  []
var initial_profile_ready := false

signal initial_profile_loaded

# Called when the node enters the scene tree for the first time.
func _ready():
	for overlay: Node in [newCampaignPanel, newCharacterPanel, loadgameWindow]:
		if not overlay.is_connected(
			&"visibility_changed",
			_sync_main_menu_splash
		):
			overlay.connect(&"visibility_changed", _sync_main_menu_splash)
	_sync_main_menu_splash()
	newprofileVBox.my_menu = self
	build_profiles_list()
	#var config = FileAccess.open(Paths.realmzfolderpath+"settings.cfg", FileAccess.ModeFlags.WRITE_READ)
	#if config:
		#config.close()

	var profilefromcfg = Utils.FileHandler.get_cfg_setting(Paths.settingspath,"SETTINGS","current_profile", "Default Profile")
	pass
	var hd_mode_from_config = Utils.FileHandler.get_cfg_setting(Paths.settingspath,"SETTINGS","hd_mode", false)
	var game_speed_from_config := float(
		Utils.FileHandler.get_cfg_setting(
			Paths.settingspath,
			"SETTINGS",
			"game_speed_percent",
			GameGlobal.DEFAULT_GAME_SPEED_PERCENT
		)
	)
	var map_debug_overlays_from_config := bool(
		Utils.FileHandler.get_cfg_setting(
			Paths.settingspath,
			"SETTINGS",
			"show_map_debug_overlays",
			true
		)
	)
	
	GameGlobal.set_hd_mode(hd_mode_from_config)
	GameGlobal.set_game_speed_percent(game_speed_from_config)
	GameGlobal.set_map_debug_overlays_enabled(map_debug_overlays_from_config)
	_load_initial_profile_after_first_frame(profilefromcfg, hd_mode_from_config)


func _sync_main_menu_splash() -> void:
	var show_splash: bool = not (
		newCampaignPanel.visible
		or newCharacterPanel.visible
		or loadgameWindow.visible
	)
	splashArt.visible = show_splash
	if show_splash:
		volcanoFlame.play()
	else:
		volcanoFlame.pause()


func _unhandled_input(event: InputEvent) -> void:
	if newProfilePanel.visible and event.is_action_pressed(&"ui_cancel"):
		close_new_profile_editor(true)
		get_viewport().set_input_as_handled()


func _load_initial_profile_after_first_frame(
	profilefromcfg: String,
	_hd_mode_from_config: bool
) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
#	var dir = Directory.new()
	if DirAccess.dir_exists_absolute(Paths.profilesfolderpath+"/" + profilefromcfg) :
#	if dir.dir_exists(Paths.profilesfolderpath+"/" + profilefromcfg) :
		GameGlobal.set_current_profile(profilefromcfg)
		honest_mode_label.visible = GameGlobal.honest_mode
		profilebutton.text = profilefromcfg
		newCampaignButton.disabled = false
		newCharacterButton.disabled = false
		loadgameButton.disabled = false
		hdModeCheckButton.button_pressed = GameGlobal.hd_mode
		if GameGlobal.hd_mode:
			ScreenUtils.set_window_scale(self, 2.0)
	initial_profile_ready = true
	initial_profile_loaded.emit()

	#print("Mainmenu _ready over")





func build_profiles_list() -> void :
	profilespopup.clear()
#	for child in profilespopup.get_children() :
#		profilespopup.remove_child(child)
#		child.queue_free()
	profileslist = Utils.FileHandler.list_dirs_in_directory(Paths.profilesfolderpath)
	print("profileslist : ", Paths.profilesfolderpath)
	for i in range(profileslist.size()) :
		#add_item(label: String, id: int = -1, accel: int = 0)
		profilespopup.add_item(profileslist[i])






func _on_profile_button_pressed():
	close_new_profile_editor()
	profilespopup.position = Vector2i(
		profilebutton.global_position + Vector2(0.0, profilebutton.size.y)
	)
	profilespopup.popup()
	profilespopup.show()


func _on_profile_popup_menu_id_pressed(id):
	newCampaignButton.disabled = false
	newCharacterButton.disabled = false
	loadgameButton.disabled = false
	profilebutton.text = profileslist[id]
	GameGlobal.set_current_profile(profileslist[id])
	honest_mode_label.visible = GameGlobal.honest_mode


func _on_new_profile_toggle_button_pressed() -> void:
	if newProfilePanel.visible:
		close_new_profile_editor(true)
		return
	newProfileNameEdit.clear()
	newProfilePanel.show()
	newProfileNameEdit.grab_focus()


func _on_new_profile_cancel_button_pressed() -> void:
	close_new_profile_editor(true)


func close_new_profile_editor(restore_focus: bool = false) -> void:
	newProfilePanel.hide()
	newProfileNameEdit.clear()
	if restore_focus:
		newProfileToggleButton.grab_focus()


func _on_new_character_button_pressed():
	close_new_profile_editor()
	newCharacterPanel.clear_classic_campaign_context()
	newCharacterPanel.set_clean_character()
	newCharacterPanel.fill()
	newCharacterPanel.loadClassesRaces()
	newCharacterPanel.fillClassesRacesMenus()
	newCharacterPanel.show()
#	newCampaignButton.hide()

func _on_new_campaign_button_pressed():
	close_new_profile_editor()
	newCampaignPanel.fill()
	newCampaignPanel.show()
#	newCharacterButton.hide()


func _on_load_button_pressed():
	close_new_profile_editor()
	loadgameCtrl.fill('',false)
	loadgameCtrl.show()
	loadgameWindow.show()


func _on_hd_button_pressed():
	var hd_mode_chosen = hdModeCheckButton.button_pressed

	if hd_mode_chosen:
		# Switch to HD
		ScreenUtils.set_window_scale(self, 2.0)
	else:
				ScreenUtils.set_window_scale(self, 1.0)
		# Switch to SD


	GameGlobal.set_hd_mode(hd_mode_chosen)

	# Save the setting on change, otherwise smart defaults will be used every time
	# for the screen you start the game on
	GameGlobal.save_hd_mode(hd_mode_chosen)
