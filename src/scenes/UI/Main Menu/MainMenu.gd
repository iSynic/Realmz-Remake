extends Control

const NEW_CAMPAIGN_SCENE := "res://scenes/UI/Main Menu/new_campaign_panel.tscn"
const NEW_CHARACTER_SCENE := "res://scenes/UI/Main Menu/new_character_panel.tscn"
const SAVE_LOAD_SCENE := "res://scenes/UI/HUD/SaveLoad/save_load_rect.tscn"
const NativeContextBuilderScript = preload(
	"res://scripts/classic_runtime/classic_native_context_builder.gd"
)
const DEFERRED_SCENES: Array[String] = [
	NEW_CAMPAIGN_SCENE,
	NEW_CHARACTER_SCENE,
	SAVE_LOAD_SCENE,
]

@export var newprofileVBox: VBoxContainer
@export var honest_mode_label: Label
@export var profilebutton: Button
@export var profilespopup: PopupMenu
@onready var splashArt: TextureRect = $TextureRect
@onready var volcanoFlame: AnimatedSprite2D = $TextureRect/ClassicVolcanoFlame
@onready var newProfilePanel: NinePatchRect = $NewProfilePanel
@onready var newProfileNameEdit: LineEdit = (
	$NewProfilePanel/MarginContainer/NewProfileVBox/NameRow/LineEdit
)
@onready var newProfileToggleButton: Button = $TopBar/NewProfileToggleButton
@onready var newCampaignButton: Button = $BottomMenu/NewCampaignButton
@onready var newCharacterButton: Button = $BottomMenu/NewCharacterButton
@onready var loadgameButton: Button = $BottomMenu/LoadButton
@onready var hdModeCheckButton: CheckButton = $TopBar/HDButton
@onready var profileLoadingLabel: Label = $TopBar/ProfileLoadingLabel

var _new_campaign_panel: NinePatchRect
var _new_character_panel: NinePatchRect
var _loadgame_window: Window
var _loadgame_ctrl: SaveLoadCtrl
var _deferred_requests_started := false
var _deferred_scene_cache: Dictionary = {}
var _profile_generation := 0

# These properties preserve the presentation facade used by tests and gameplay.
# UI button handlers use the asynchronous ensure methods below.
var newCampaignPanel: NinePatchRect:
	get:
		return ensure_new_campaign_panel()
var newCharacterPanel: NinePatchRect:
	get:
		return ensure_new_character_panel()
var loadgameWindow: Window:
	get:
		return ensure_load_window()
var loadgameCtrl: SaveLoadCtrl:
	get:
		ensure_load_window()
		return _loadgame_ctrl

var profileslist: Array = []
var initial_profile_ready := false

signal initial_profile_loaded


func _ready() -> void:
	_sync_main_menu_splash()
	newprofileVBox.my_menu = self
	build_profiles_list()
	var profile_from_config := str(Utils.FileHandler.get_cfg_setting(
		Paths.settingspath,
		"SETTINGS",
		"current_profile",
		"Default Profile"
	))
	var hd_mode_from_config := bool(Utils.FileHandler.get_cfg_setting(
		Paths.settingspath,
		"SETTINGS",
		"hd_mode",
		false
	))
	var game_speed_from_config := float(Utils.FileHandler.get_cfg_setting(
		Paths.settingspath,
		"SETTINGS",
		"game_speed_percent",
		GameGlobal.DEFAULT_GAME_SPEED_PERCENT
	))
	var map_debug_overlays_from_config := bool(Utils.FileHandler.get_cfg_setting(
		Paths.settingspath,
		"SETTINGS",
		"show_map_debug_overlays",
		true
	))
	GameGlobal.set_hd_mode(hd_mode_from_config)
	GameGlobal.set_game_speed_percent(game_speed_from_config)
	GameGlobal.set_map_debug_overlays_enabled(map_debug_overlays_from_config)
	_set_profile_busy(true)
	_load_initial_profile_after_first_frame(profile_from_config, hd_mode_from_config)
	_preload_secondary_scenes_after_first_frame()
	_warm_campaign_catalog_after_first_frame()


func _sync_main_menu_splash() -> void:
	var overlay_visible := (
		(is_instance_valid(_new_campaign_panel) and _new_campaign_panel.visible)
		or (is_instance_valid(_new_character_panel) and _new_character_panel.visible)
		or (is_instance_valid(_loadgame_window) and _loadgame_window.visible)
	)
	var show_splash := not overlay_visible
	splashArt.visible = show_splash
	if show_splash:
		volcanoFlame.play()
	else:
		volcanoFlame.pause()


func _connect_overlay(overlay: Node) -> void:
	if not overlay.visibility_changed.is_connected(_sync_main_menu_splash):
		overlay.visibility_changed.connect(_sync_main_menu_splash)
	_sync_main_menu_splash()


func _unhandled_input(event: InputEvent) -> void:
	if newProfilePanel.visible and event.is_action_pressed(&"ui_cancel"):
		close_new_profile_editor(true)
		get_viewport().set_input_as_handled()


func _load_initial_profile_after_first_frame(
	profile_from_config: String,
	hd_mode_from_config: bool
) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	LoadPerformanceTrace.begin_named(&"startup.profile", {"profile": profile_from_config})
	var loaded := false
	if DirAccess.dir_exists_absolute(
		Paths.profilesfolderpath.path_join(profile_from_config)
	):
		loaded = await GameGlobal.set_current_profile_async(profile_from_config)
		if loaded:
			honest_mode_label.visible = GameGlobal.honest_mode
			profilebutton.text = profile_from_config
			hdModeCheckButton.button_pressed = GameGlobal.hd_mode
			if hd_mode_from_config:
				ScreenUtils.set_window_scale(self, 2.0)
	initial_profile_ready = loaded
	_set_profile_busy(not loaded)
	if not loaded:
		profileLoadingLabel.text = "Profile could not be loaded"
	initial_profile_loaded.emit()
	LoadPerformanceTrace.end_named(&"startup.profile", loaded, {
		"profile": profile_from_config,
		"character_count": GameGlobal.profile_characters_list.size(),
	})
	if loaded:
		call_deferred("_warm_shared_resources_after_profile")
		call_deferred("_warm_native_context_after_profile")


func _warm_shared_resources_after_profile() -> void:
	await get_tree().process_frame
	var resources: CampaignResources = NodeAccess.__Resources()
	if resources != null:
		await resources.ensure_shared_resources_loaded_async()


func _warm_native_context_after_profile() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	var context_builder = NativeContextBuilderScript.new()
	await context_builder.warm_shared_cache_async(get_tree())


func _set_profile_busy(busy: bool) -> void:
	newCampaignButton.disabled = busy
	newCharacterButton.disabled = busy
	loadgameButton.disabled = busy
	profileLoadingLabel.visible = busy
	if busy:
		profileLoadingLabel.text = "Loading profile…"


func _preload_secondary_scenes_after_first_frame() -> void:
	await get_tree().process_frame
	if (
		not is_inside_tree()
		or _deferred_requests_started
		or OS.get_cmdline_args().has("--script")
	):
		return
	_deferred_requests_started = true
	for scene_path: String in DEFERRED_SCENES:
		var error := ResourceLoader.load_threaded_request(scene_path, "PackedScene")
		if error != OK:
			push_warning("Could not queue deferred UI scene: %s" % scene_path)
			continue
		while is_inside_tree():
			if _deferred_scene_cache.has(scene_path):
				break
			var status := ResourceLoader.load_threaded_get_status(scene_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				# Finalize one request before starting the next. The panels share
				# dependencies, and concurrent text-scene loads can race in headless runs.
				_cache_threaded_scene(scene_path)
				break
			if status == ResourceLoader.THREAD_LOAD_FAILED:
				push_warning("Deferred UI scene failed to load: %s" % scene_path)
				break
			if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				break
			await get_tree().process_frame


func _warm_campaign_catalog_after_first_frame() -> void:
	await get_tree().process_frame
	if not is_inside_tree() or OS.get_cmdline_args().has("--script"):
		return
	await GameGlobal.warm_campaign_selection_previews_async()


func _instantiate_deferred_scene(scene_path: String, scene: PackedScene) -> void:
	if scene == null:
		return
	match scene_path:
		NEW_CAMPAIGN_SCENE:
			if not is_instance_valid(_new_campaign_panel):
				_new_campaign_panel = scene.instantiate() as NinePatchRect
				_new_campaign_panel.name = "NewCampaignPanel"
				_new_campaign_panel.hide()
				add_child(_new_campaign_panel)
				_connect_overlay(_new_campaign_panel)
		NEW_CHARACTER_SCENE:
			if not is_instance_valid(_new_character_panel):
				_new_character_panel = scene.instantiate() as NinePatchRect
				_new_character_panel.name = "NewCharacterPanel"
				_new_character_panel.hide()
				add_child(_new_character_panel)
				_connect_overlay(_new_character_panel)
		SAVE_LOAD_SCENE:
			if not is_instance_valid(_loadgame_window):
				_create_load_window(scene)


func _create_load_window(scene: PackedScene) -> void:
	_loadgame_window = Window.new()
	_loadgame_window.name = "LoadWindow"
	_loadgame_window.transparent_bg = true
	_loadgame_window.size = Vector2i(1152, 648)
	_loadgame_window.transient = true
	_loadgame_window.exclusive = true
	_loadgame_window.unresizable = true
	_loadgame_window.borderless = true
	_loadgame_window.always_on_top = true
	_loadgame_window.transparent = true
	_loadgame_window.popup_window = true
	add_child(_loadgame_window)
	_loadgame_window.hide()
	_loadgame_ctrl = scene.instantiate() as SaveLoadCtrl
	_loadgame_ctrl.name = "SaveLoadRect"
	_loadgame_window.add_child(_loadgame_ctrl)
	_connect_overlay(_loadgame_window)


func _loaded_or_sync(scene_path: String) -> PackedScene:
	if _deferred_scene_cache.has(scene_path):
		return _deferred_scene_cache[scene_path] as PackedScene
	if _deferred_requests_started:
		var status := ResourceLoader.load_threaded_get_status(scene_path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			return _cache_threaded_scene(scene_path)
	var scene := load(scene_path) as PackedScene
	if scene != null:
		_deferred_scene_cache[scene_path] = scene
	return scene


func _cache_threaded_scene(scene_path: String) -> PackedScene:
	if _deferred_scene_cache.has(scene_path):
		return _deferred_scene_cache[scene_path] as PackedScene
	var scene := ResourceLoader.load_threaded_get(scene_path) as PackedScene
	if scene != null:
		_deferred_scene_cache[scene_path] = scene
	return scene


func ensure_new_campaign_panel() -> NinePatchRect:
	if not is_instance_valid(_new_campaign_panel):
		_instantiate_deferred_scene(
			NEW_CAMPAIGN_SCENE,
			_loaded_or_sync(NEW_CAMPAIGN_SCENE)
		)
	return _new_campaign_panel


func ensure_new_character_panel() -> NinePatchRect:
	if not is_instance_valid(_new_character_panel):
		_instantiate_deferred_scene(
			NEW_CHARACTER_SCENE,
			_loaded_or_sync(NEW_CHARACTER_SCENE)
		)
	return _new_character_panel


func ensure_load_window() -> Window:
	if not is_instance_valid(_loadgame_window):
		_instantiate_deferred_scene(SAVE_LOAD_SCENE, _loaded_or_sync(SAVE_LOAD_SCENE))
	return _loadgame_window


func _await_deferred_scene(scene_path: String) -> PackedScene:
	if _deferred_scene_cache.has(scene_path):
		return _deferred_scene_cache[scene_path] as PackedScene
	if not _deferred_requests_started:
		return _loaded_or_sync(scene_path)
	while is_inside_tree():
		if _deferred_scene_cache.has(scene_path):
			return _deferred_scene_cache[scene_path] as PackedScene
		var status := ResourceLoader.load_threaded_get_status(scene_path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			return _cache_threaded_scene(scene_path)
		if status == ResourceLoader.THREAD_LOAD_FAILED:
			break
		if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			break
		await get_tree().process_frame
	return _loaded_or_sync(scene_path)


func ensure_new_campaign_panel_async() -> NinePatchRect:
	if not is_instance_valid(_new_campaign_panel):
		_instantiate_deferred_scene(
			NEW_CAMPAIGN_SCENE,
			await _await_deferred_scene(NEW_CAMPAIGN_SCENE)
		)
	return _new_campaign_panel


func ensure_new_character_panel_async() -> NinePatchRect:
	if not is_instance_valid(_new_character_panel):
		_instantiate_deferred_scene(
			NEW_CHARACTER_SCENE,
			await _await_deferred_scene(NEW_CHARACTER_SCENE)
		)
	return _new_character_panel


func ensure_load_window_async() -> Window:
	if not is_instance_valid(_loadgame_window):
		_instantiate_deferred_scene(
			SAVE_LOAD_SCENE,
			await _await_deferred_scene(SAVE_LOAD_SCENE)
		)
	return _loadgame_window


func build_profiles_list() -> void:
	profilespopup.clear()
	profileslist = Utils.FileHandler.list_dirs_in_directory(Paths.profilesfolderpath)
	profileslist.sort()
	for profile_name: Variant in profileslist:
		profilespopup.add_item(str(profile_name))


func _on_profile_button_pressed() -> void:
	close_new_profile_editor()
	profilespopup.position = Vector2i(
		profilebutton.global_position + Vector2(0.0, profilebutton.size.y)
	)
	profilespopup.popup()


func _on_profile_popup_menu_id_pressed(id: int) -> void:
	if id < 0 or id >= profileslist.size():
		return
	_profile_generation += 1
	var generation := _profile_generation
	_set_profile_busy(true)
	var profile_name := str(profileslist[id])
	profilebutton.text = profile_name
	var loaded := await GameGlobal.set_current_profile_async(profile_name)
	if generation != _profile_generation:
		return
	initial_profile_ready = loaded
	_set_profile_busy(not loaded)
	honest_mode_label.visible = loaded and GameGlobal.honest_mode
	if not loaded:
		profileLoadingLabel.text = "Profile could not be loaded"


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


func _on_new_character_button_pressed() -> void:
	close_new_profile_editor()
	var panel := await ensure_new_character_panel_async()
	panel.clear_classic_campaign_context()
	panel.set_clean_character()
	panel.fill()
	panel.loadClassesRaces()
	panel.fillClassesRacesMenus()
	panel.show()


func _on_new_campaign_button_pressed() -> void:
	close_new_profile_editor()
	var panel := await ensure_new_campaign_panel_async()
	panel.show()
	panel.fill_async()


func _on_load_button_pressed() -> void:
	close_new_profile_editor()
	await ensure_load_window_async()
	_loadgame_ctrl.fill("", false)
	_loadgame_ctrl.show()
	_loadgame_window.show()


func _on_hd_button_pressed() -> void:
	var hd_mode_chosen := hdModeCheckButton.button_pressed
	ScreenUtils.set_window_scale(self, 2.0 if hd_mode_chosen else 1.0)
	GameGlobal.set_hd_mode(hd_mode_chosen)
	GameGlobal.save_hd_mode(hd_mode_chosen)
