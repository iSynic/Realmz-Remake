extends NinePatchRect

enum CreationStage {
	IDENTITY,
	CALLING,
	APPEARANCE,
	REVIEW,
	SPELLS,
}

const ClassicCampaignInstallScript = preload(
	"res://scripts/scenario_runtime/scenario_campaign_install.gd"
)
const ClassicCharacterRulesScript = preload(
	"res://scripts/classic_runtime/classic_character_rules.gd"
)
const ClassicStandardCharacterRulesScript = preload(
	"res://scripts/classic_runtime/classic_standard_character_rules.gd"
)
const ClassicItemMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_item_materializer.gd"
)
const MIN_STARTING_LEVEL := 1
const MAX_STARTING_LEVEL := 1000
const APPEARANCE_WIDE_COLUMNS := 12
const APPEARANCE_COMPACT_COLUMNS := 6
const APPEARANCE_COLUMN_GAP := 6
const APPEARANCE_BUTTON_SIZE := Vector2(56, 56)

# Declare member variables here. Examples:
# var a = 2
# var b = "text"
@export var cancelButton : Button# = $CancelButton
@export var okButton : Button# = $OKButton
@export var lineEdit : LineEdit# = $LineEdit
@export var portraitContainer : GridContainer# = $"PortraitScrollContainer/PortraitContainer"
@export var iconContainer : GridContainer# = $"IconScrollContainer/IconContainer"
@export var portraitScroll : ScrollContainer# = $"PortraitScrollContainer"
@export var iconScroll : ScrollContainer# = $"IconScrollContainer"
@export var classitemlist : ItemList #= $"ClassItemList"
@export var raceitemlist : ItemList #= $"RaceItemList"
@export var characterstatrect : NewCharStatsRect #= $"CharacterStatsRect"
@export var levelInput : LineEdit
@export var classicContextLabel : Label
@export var genderOptionButton : OptionButton


@export var abilities_rect : AbilitiesManagementRect

var iconsImages : Array = []
var portraitsTextures: Array = []
var iconsTextures : Array = []

var classesgd : Array = []
var racesgd : Array = []
var newchar_level: int = 1
#var onlyportrait : Texture2D = preload("res://Main Menu/onlyportrait.png")

var new_char_name = ""
var new_char_portrait : Texture2D
var new_char_icon : Texture2D
var new_char_class : GDScript = null
var new_char_race : GDScript = null

var new_character = null
var previous_music_info = null  # Store info about music playing before character creation
var classic_campaign_name := ""
var classic_install: Object
var classic_race_options: Array[Dictionary] = []
var classic_caste_options: Array[Dictionary] = []
var classic_race_id := 0
var classic_caste_id := 0
var classic_gender := 1
var return_to_campaign_panel: Control
var classic_creation_active := false
var character_rules_bundle: Dictionary = {}
var _normalizing_level_input := false

@export var portraitRect : TextureRect# = $"PortraitRect"
@export var iconRect : TextureRect# = $"IconRect"

var default_icon : Texture2D
var default_portrait : Texture2D
@onready var stageLabel : Label = $BigVBox/HeaderRow/StageLabel
@onready var identityStage : Control = $BigVBox/ContentRow/StageWorkspace/IdentityStage
@onready var callingStage : Control = $BigVBox/ContentRow/StageWorkspace/CallingStage
@onready var appearanceStage : Control = $BigVBox/ContentRow/StageWorkspace/AppearanceStage
@onready var reviewStage : Control = $BigVBox/ContentRow/StageWorkspace/ReviewStage
@onready var backButton : Button = $BigVBox/FooterRow/BackButton
@onready var statusLabel : Label = $BigVBox/StatusLabel
@onready var portraitTabButton : Button = (
	$BigVBox/ContentRow/StageWorkspace/AppearanceStage/AppearanceVBox/TabRow/PortraitTabButton
)
@onready var iconTabButton : Button = (
	$BigVBox/ContentRow/StageWorkspace/AppearanceStage/AppearanceVBox/TabRow/IconTabButton
)
@onready var summaryNameLabel : Label = $BigVBox/ContentRow/SummaryVBox/SummaryNameLabel
@onready var summaryCallingLabel : Label = $BigVBox/ContentRow/SummaryVBox/SummaryCallingLabel
@onready var summaryLevelLabel : Label = $BigVBox/ContentRow/SummaryVBox/SummaryLevelLabel
@onready var classHeadingLabel : Label = (
	$BigVBox/ContentRow/StageWorkspace/CallingStage/CallingVBox/ChoicesRow/ClassVBox/ClassLabel
)
@onready var callingHeadingLabel : Label = (
	$BigVBox/ContentRow/StageWorkspace/CallingStage/CallingVBox/Heading
)
@onready var classDescriptionLabel : Label = (
	$BigVBox/ContentRow/StageWorkspace/CallingStage/CallingVBox/ChoicesRow/ClassVBox/ClassDescription
)
@onready var raceDescriptionLabel : Label = (
	$BigVBox/ContentRow/StageWorkspace/CallingStage/CallingVBox/ChoicesRow/RaceVBox/RaceDescription
)
@onready var reviewHelpLabel : Label = (
	$BigVBox/ContentRow/StageWorkspace/ReviewStage/ReviewVBox/ReviewHelp
)

@onready var stageButtons : Array[Button] = [
	$BigVBox/StageBar/IdentityButton,
	$BigVBox/StageBar/CallingButton,
	$BigVBox/StageBar/AppearanceButton,
	$BigVBox/StageBar/ReviewButton,
	$BigVBox/StageBar/SpellsButton,
]
@onready var stageContainers : Array[Control] = [
	identityStage,
	callingStage,
	appearanceStage,
	reviewStage,
	abilities_rect,
]

var current_stage: CreationStage = CreationStage.IDENTITY
var spell_selection_prepared := false
var portraitButtons : Array[Button] = []
var iconButtons : Array[Button] = []
var portraitButtonGroup := ButtonGroup.new()
var iconButtonGroup := ButtonGroup.new()

#var dir = Directory.new()

# Called when the node enters the scene tree for the first time.
func _ready():
	var _err_on_CancelButton_pressed = cancelButton.connect("pressed",Callable(self,"_on_CancelButton_pressed"))
	var _err_on_OKButton_pressed = okButton.connect("pressed",Callable(self,"_on_primary_button_pressed"))
	var _err_on_LineEdit_changed = lineEdit.connect("text_changed",Callable(self,"_on_LineEdit_changed"))
	backButton.pressed.connect(_on_back_button_pressed)
	portraitTabButton.pressed.connect(_show_appearance_browser.bind(true))
	iconTabButton.pressed.connect(_show_appearance_browser.bind(false))
	portraitScroll.resized.connect(_update_appearance_columns)
	iconScroll.resized.connect(_update_appearance_columns)
	for stage_index: int in range(stageButtons.size()):
		stageButtons[stage_index].pressed.connect(
			_on_stage_button_pressed.bind(stage_index)
		)
	_load_default_appearance()
	character_rules_bundle = ClassicStandardCharacterRulesScript.effective_bundle()
	fillIconsPortraitsChoices()
	loadClassesRaces()
	fillClassesRacesMenus()
	levelInput.text_changed.connect(_on_level_text_changed)
	levelInput.text_submitted.connect(_commit_level_input)
	levelInput.focus_exited.connect(_commit_level_input)
	abilities_rect.set_creation_mode(true)
	genderOptionButton.item_selected.connect(_on_gender_selected)
	genderOptionButton.visible = true
	genderOptionButton.get_parent().visible = true
	_update_mode_copy()
	_show_appearance_browser(true)
	_show_stage(CreationStage.IDENTITY, false)

	# Connect to visibility changed signal to handle music
	connect("visibility_changed", Callable(self, "_on_visibility_changed"))


func _load_default_appearance() -> void:
	default_portrait = Utils.FileHandler.load_img_texture(
		Paths.datafolderpath + "Character Portraits/Human 1.png"
	)
	default_icon = Utils.FileHandler.load_img_texture(
		Paths.datafolderpath + "Character Icons/Vampire 5.png"
	)
	new_char_portrait = default_portrait
	new_char_icon = default_icon
	portraitRect.texture = default_portrait
	iconRect.texture = default_icon


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_cancel"):
		if current_stage > CreationStage.IDENTITY:
			_show_stage(current_stage - 1)
		else:
			_on_CancelButton_pressed()
		get_viewport().set_input_as_handled()


func _on_primary_button_pressed() -> void:
	if current_stage < CreationStage.REVIEW:
		_show_stage(current_stage + 1)
		return
	if current_stage == CreationStage.REVIEW:
		if _prepare_spell_selection_stage():
			_show_stage(CreationStage.SPELLS)
		return
	_finish_character_creation()


func _on_back_button_pressed() -> void:
	if current_stage > CreationStage.IDENTITY:
		_show_stage(current_stage - 1)


func _on_stage_button_pressed(stage_index: int) -> void:
	if stage_index < 0 or stage_index >= stageButtons.size():
		return
	if stageButtons[stage_index].disabled:
		return
	_show_stage(stage_index)


func _show_stage(stage_index: int, focus_stage: bool = true) -> void:
	current_stage = clampi(
		stage_index,
		CreationStage.IDENTITY,
		CreationStage.SPELLS
	) as CreationStage
	for index: int in range(stageContainers.size()):
		stageContainers[index].visible = index == current_stage
		stageButtons[index].button_pressed = index == current_stage
	stageLabel.text = "Step %d of %d" % [current_stage + 1, stageContainers.size()]
	_refresh_creation_ui()
	if current_stage == CreationStage.APPEARANCE:
		_update_appearance_columns.call_deferred()
	if focus_stage:
		_focus_current_stage.call_deferred()


func _focus_current_stage() -> void:
	match current_stage:
		CreationStage.IDENTITY:
			lineEdit.grab_focus()
		CreationStage.CALLING:
			classitemlist.grab_focus()
		CreationStage.APPEARANCE:
			portraitTabButton.grab_focus()
		CreationStage.REVIEW:
			okButton.grab_focus()
		CreationStage.SPELLS:
			if abilities_rect.has_spell_choices():
				abilities_rect.focus_first_control()
			else:
				okButton.grab_focus()


func _name_validation_message() -> String:
	if new_char_name.strip_edges().is_empty():
		return "Enter a character name to continue."
	var validity: Array = Utils.FileHandler.is_valid_file_name(new_char_name)
	if validity[0] != 1:
		return str(validity[1])
	var character_path: String = (
		Paths.profilesfolderpath
		+ Paths.currentProfileFolderName
		+ "/Characters/"
		+ new_char_name
	)
	if DirAccess.dir_exists_absolute(character_path):
		return "That character name is already used in this profile."
	return ""


func _calling_is_complete() -> bool:
	return (
		_name_validation_message().is_empty()
		and new_char_class != null
		and new_char_race != null
		and new_character != null
		and ClassicStandardCharacterRulesScript.is_caste_allowed(
			character_rules_bundle,
			classic_race_id,
			classic_caste_id
		)
	)


func _refresh_creation_ui() -> void:
	if stageButtons.is_empty():
		return
	var name_is_valid := _name_validation_message().is_empty()
	var calling_is_complete := _calling_is_complete()
	stageButtons[CreationStage.IDENTITY].disabled = false
	stageButtons[CreationStage.CALLING].disabled = not name_is_valid
	stageButtons[CreationStage.APPEARANCE].disabled = not calling_is_complete
	stageButtons[CreationStage.REVIEW].disabled = not calling_is_complete
	stageButtons[CreationStage.SPELLS].disabled = not spell_selection_prepared
	backButton.disabled = current_stage == CreationStage.IDENTITY

	match current_stage:
		CreationStage.IDENTITY:
			okButton.text = "Continue"
			okButton.disabled = not name_is_valid
			statusLabel.text = (
				"Choose a starting level and gender, then continue."
				if name_is_valid
				else _name_validation_message()
			)
		CreationStage.CALLING:
			okButton.text = "Continue"
			okButton.disabled = not calling_is_complete
			statusLabel.text = (
				"Review both selections, then continue to appearance."
				if calling_is_complete
				else "Choose both a %s and a race to continue." % (
					"caste" if classic_install != null else "class"
				)
			)
		CreationStage.APPEARANCE:
			okButton.text = "Continue"
			okButton.disabled = not calling_is_complete
			statusLabel.text = "Choose a portrait and combat icon, or keep the defaults."
		CreationStage.REVIEW:
			okButton.text = "Continue to Spells"
			okButton.disabled = not calling_is_complete
			statusLabel.text = "Review the generated character, then choose spells."
		CreationStage.SPELLS:
			okButton.text = "Create Character"
			okButton.disabled = not spell_selection_prepared
			statusLabel.text = (
				"Choose spells within the available selection-point budget."
				if abilities_rect.has_spell_choices()
				else "This character has no spells to choose."
			)
	_update_summary()


func _selected_item_text(item_list: ItemList, fallback: String) -> String:
	var selected_items: PackedInt32Array = item_list.get_selected_items()
	if selected_items.is_empty():
		return fallback
	return item_list.get_item_text(selected_items[0])


func _update_summary() -> void:
	summaryNameLabel.text = (
		new_char_name
		if _name_validation_message().is_empty()
		else "— unnamed —"
	)
	var race_name := _selected_item_text(raceitemlist, "No race selected")
	var calling_name := _selected_item_text(
		classitemlist,
		"No caste selected" if classic_install != null else "No class selected"
	)
	summaryCallingLabel.text = "%s\n%s" % [race_name, calling_name]
	summaryLevelLabel.text = "Starting level %d" % newchar_level


func _update_mode_copy() -> void:
	var is_classic := classic_install != null
	classHeadingLabel.text = "Caste" if is_classic else "Class"
	stageButtons[CreationStage.CALLING].text = (
		"2  Caste & Race" if is_classic else "2  Class & Race"
	)
	callingHeadingLabel.text = (
		"Choose a Caste and Race" if is_classic else "Choose a Class and Race"
	)
	reviewHelpLabel.text = "Review the character before choosing spells."
	_refresh_rules_context_label()


func _rules_context_text() -> String:
	if classic_install != null:
		return "Campaign: %s" % str(
			classic_install.bundle.manifest.get(
				"name",
				classic_campaign_name
			)
		)
	return ""


func _refresh_rules_context_label() -> void:
	classicContextLabel.text = _rules_context_text()
	classicContextLabel.visible = not classicContextLabel.text.is_empty()


func _show_appearance_browser(show_portraits: bool) -> void:
	portraitScroll.visible = show_portraits
	iconScroll.visible = not show_portraits
	portraitTabButton.button_pressed = show_portraits
	iconTabButton.button_pressed = not show_portraits
	if portraitsTextures.size() == iconsTextures.size():
		if show_portraits:
			portraitScroll.set_v_scroll(iconScroll.get_v_scroll())
		else:
			iconScroll.set_v_scroll(portraitScroll.get_v_scroll())


func configure_classic_campaign(
	campaign_name: String,
	campaign_panel: Control
) -> Dictionary:
	var install = ClassicCampaignInstallScript.new()
	if not install.load_from_campaigns_directory(
		Paths.campaignsfolderpath,
		campaign_name
	):
		return {"status": "error", "message": install.last_error}
	classic_campaign_name = campaign_name
	classic_install = install
	character_rules_bundle = (
		ClassicStandardCharacterRulesScript.effective_bundle(install.bundle)
	)
	if character_rules_bundle.is_empty():
		return {
			"status": "error",
			"message": ClassicStandardCharacterRulesScript.last_error(),
		}
	return_to_campaign_panel = campaign_panel
	genderOptionButton.visible = true
	genderOptionButton.get_parent().visible = true
	classic_gender = 1
	classic_creation_active = false
	genderOptionButton.select(0)
	fill()
	loadClassesRaces()
	fillClassesRacesMenus()
	_update_mode_copy()
	_refresh_creation_ui()
	return {"status": "ok"}


func clear_classic_campaign_context() -> void:
	classic_campaign_name = ""
	classic_install = null
	classic_race_options.clear()
	classic_caste_options.clear()
	classic_race_id = 0
	classic_caste_id = 0
	classic_gender = 1
	classic_creation_active = false
	character_rules_bundle = ClassicStandardCharacterRulesScript.effective_bundle()
	genderOptionButton.visible = true
	genderOptionButton.get_parent().visible = true
	return_to_campaign_panel = null
	if is_node_ready():
		loadClassesRaces()
		fillClassesRacesMenus()
	_update_mode_copy()
	_refresh_creation_ui()


func set_clean_character() :
	new_character = null

	new_char_portrait = default_portrait
	portraitRect.texture = default_portrait
	characterstatrect.display_portrait(portraitRect.texture )
	new_char_icon = default_icon
	iconRect.texture = default_icon
	_update_summary()

#	new_character = GameGlobal.playerCharacterGD.new({"name":"ENTER NAME"}, default_icon, default_portrait, null, null)
	#GameGlobal.playerCharacterGD.new(jsonresult, newicon, newportrait, classgd, racegd)

func try_create_character() :
	if not (new_char_class and  new_char_race) :
		return
	if not ClassicStandardCharacterRulesScript.is_caste_allowed(
		character_rules_bundle,
		classic_race_id,
		classic_caste_id
	):
		new_character = null
		classic_creation_active = false
		statusLabel.text = "That race and class combination is not allowed by Realmz."
		_refresh_creation_ui()
		return
	spell_selection_prepared = false
	new_character = GameGlobal.playerCharacterGD.new(
		{"level": 1},
		new_char_icon,
		new_char_portrait,
		new_char_class,
		new_char_race
	)
	new_character.classic_race_id = classic_race_id
	new_character.classic_caste_id = classic_caste_id
	var classic_result := (
		ClassicCharacterRulesScript.initialize_character_creation(
			character_rules_bundle,
			new_character,
			classic_gender,
			newchar_level
		)
	)
	var classic_status := str(classic_result.get("status", ""))
	if classic_status == "ok":
		classic_creation_active = true
		_refresh_rules_context_label()
	else:
		classicContextLabel.text = str(classic_result.get(
			"message",
			"The selected Realmz race and class cannot create a character."
		))
		classicContextLabel.visible = true
		new_character = null
		classic_creation_active = false
		okButton.disabled = true
		return
	new_character.portrait = new_char_portrait
	new_character.icon = new_char_icon
	new_character.name = new_char_name
#	new_character.apply_raceclass_base_stats()
#	for l in range(newchar_level) : done in  playerCharacterGD _init now
#		new_character.level_up()
#	new_character.recalculate_stats()
	characterstatrect.display_data(new_character)
	_refresh_creation_ui()

func _on_level_text_changed(value: String) -> void:
	if _normalizing_level_input:
		return
	var digits := ""
	for character in value:
		if character >= "0" and character <= "9":
			digits += character
	if digits == value:
		return
	var previous_caret := levelInput.caret_column
	_normalizing_level_input = true
	levelInput.text = digits
	levelInput.caret_column = mini(previous_caret, digits.length())
	_normalizing_level_input = false


func _commit_level_input(_submitted_text: String = "") -> void:
	var requested_level: int = newchar_level
	if levelInput.text.is_valid_int():
		requested_level = int(levelInput.text)
	newchar_level = clampi(
		requested_level,
		MIN_STARTING_LEVEL,
		MAX_STARTING_LEVEL
	)
	_normalizing_level_input = true
	levelInput.text = str(newchar_level)
	_normalizing_level_input = false
	characterstatrect.set_character_level(newchar_level)
	if new_character :
		try_create_character()
	_update_summary()
	_refresh_creation_ui()


func fillIconsPortraitsChoices():
	_update_appearance_columns()
	var portraitspath = Paths.datafolderpath+"Character Portraits/"
	var portraitfilenames : Array = Utils.FileHandler.list_files_in_directory(portraitspath)
#	print("NewCharacter portraitfilenames : ",portraitfilenames )
	portraitfilenames.sort()
	for pfn in portraitfilenames :
		var portraittex = Utils.FileHandler.load_img_texture(portraitspath+pfn)
		portraitsTextures.append(portraittex)
	var iconspath = Paths.datafolderpath+"Character Icons/"
	print('newcharacterpanel iconspath : ', iconspath)
	var iconfilenames : Array = Utils.FileHandler.list_files_in_directory(iconspath)
	iconfilenames.sort()
	for ifn in iconfilenames :
		var icontex = Utils.FileHandler.load_img_texture(iconspath+ifn)
		iconsTextures.append(icontex)

	for p in range(portraitsTextures.size()) :
		var b = Button.new()
		b.custom_minimum_size = APPEARANCE_BUTTON_SIZE
		b.toggle_mode = true
		b.button_group = portraitButtonGroup
		b.icon = portraitsTextures[p]
		b.expand_icon = true
		b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		b.tooltip_text = "Portrait %d" % (p + 1)
		b.connect("pressed",Callable(self,"_on_portrait_button_pressed").bind(p))
		portraitContainer.add_child(b)
		portraitButtons.append(b)
	for i in range(iconsTextures.size()) :
		var b = Button.new()
		b.custom_minimum_size = APPEARANCE_BUTTON_SIZE
		b.toggle_mode = true
		b.button_group = iconButtonGroup
		b.icon = iconsTextures[i]
		b.expand_icon = true
		b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		b.tooltip_text = "Combat icon %d" % (i + 1)
		b.connect("pressed",Callable(self,"_on_icon_button_pressed").bind(i))
		iconContainer.add_child(b)
		iconButtons.append(b)


func _update_appearance_columns() -> void:
	var available_width := maxf(portraitScroll.size.x, iconScroll.size.x)
	var columns := _appearance_columns_for_width(available_width)
	portraitContainer.columns = columns
	iconContainer.columns = columns


func _appearance_columns_for_width(available_width: float) -> int:
	var wide_grid_width := (
		APPEARANCE_BUTTON_SIZE.x * APPEARANCE_WIDE_COLUMNS
		+ APPEARANCE_COLUMN_GAP * (APPEARANCE_WIDE_COLUMNS - 1)
	)
	return (
		APPEARANCE_WIDE_COLUMNS
		if available_width >= wide_grid_width
		else APPEARANCE_COMPACT_COLUMNS
	)


func loadClassesRaces() :
	classesgd = []
	racesgd = []
	var classespath = Paths.datafolderpath+"Character Classes/"
	var classesfilenames : Array = Utils.FileHandler.list_files_in_directory(classespath)
	classesfilenames.sort()
	for cf in classesfilenames :
		var classgd : GDScript = load(classespath + cf)
		classesgd.append(classgd)
	var racespath = Paths.datafolderpath+"Character Races/"
	var racesfilenames : Array = Utils.FileHandler.list_files_in_directory(racespath)
	racesfilenames.sort()
	for rf in racesfilenames :
		var racegd : GDScript = load(racespath + rf)
		racesgd.append(racegd)
	classic_race_options = _classic_identity_options(
		"race",
		racesgd
	)
	classic_caste_options = _classic_identity_options(
		"caste",
		classesgd
	)


func fillClassesRacesMenus() :
	classitemlist.clear()
	raceitemlist.clear()
	for option_index: int in range(classic_caste_options.size()):
		var caste_option: Dictionary = classic_caste_options[option_index]
		classitemlist.add_item(str(caste_option.get("name", "")))
	for option_index: int in range(classic_race_options.size()):
		var race_option: Dictionary = classic_race_options[option_index]
		raceitemlist.add_item(str(race_option.get("name", "")))
	_refresh_identity_legality()


func _classic_identity_options(
	identity_kind: String,
	native_definitions: Array
) -> Array[Dictionary]:
	var documents: Dictionary = character_rules_bundle.get("documents", {})
	var rules: Dictionary = documents.get("rules", {})
	var rule_names: Dictionary = rules.get("ruleNames", {})
	var names_value: Variant = rule_names.get(
		"raceNames" if identity_kind == "race" else "casteNames",
		[]
	)
	var names: Array = names_value if names_value is Array else []
	if names.is_empty():
		names = (
			ClassicItemMaterializerScript.STANDARD_RACE_NAMES.duplicate()
			if identity_kind == "race"
			else ClassicItemMaterializerScript.STANDARD_CASTE_NAMES.duplicate()
		)
	var native_by_name: Dictionary = {}
	for definition_value: Variant in native_definitions:
		if not (definition_value is GDScript):
			continue
		var definition: GDScript = definition_value
		var definition_name := str(
			definition.get_script_constant_map().get("classrace_name", "")
		)
		native_by_name[definition_name.to_lower()] = definition
	var fallback_name := "Human" if identity_kind == "race" else "Fighter"
	var fallback: GDScript = native_by_name.get(fallback_name.to_lower())
	if fallback == null and not native_definitions.is_empty():
		fallback = native_definitions[0]

	var option_ids: Array[int] = []
	for definition_name_value: Variant in native_by_name.keys():
		var definition_name := str(definition_name_value)
		for name_index: int in range(names.size()):
			if str(names[name_index]).to_lower() == definition_name:
				option_ids.append(name_index + 1)
				break
	var table_selection: Dictionary = rules.get("tableSelection", {})
	var selected_table: Dictionary = table_selection.get(
		"races" if identity_kind == "race" else "castes",
		{}
	)
	if str(selected_table.get("source", "")) == "scenario-local":
		for record_id_value: Variant in selected_table.get(
			"changedRecordIds",
			[]
		):
			var identity_id := int(record_id_value) + 1
			if identity_id > 0 and identity_id not in option_ids:
				option_ids.append(identity_id)
	option_ids.sort()

	var selection_rules: Dictionary = (
		classic_install.selection_rules()
		if classic_install != null
		else {}
	)
	var banned_ids: Variant = selection_rules.get(
		"bannedRaceIds" if identity_kind == "race" else "bannedCasteIds",
		[]
	)
	var options: Array[Dictionary] = []
	for identity_id: int in option_ids:
		if identity_id < 1 or identity_id > names.size():
			continue
		var display_name := str(names[identity_id - 1]).strip_edges()
		if display_name.is_empty():
			continue
		var native_definition: GDScript = native_by_name.get(
			display_name.to_lower(),
			fallback
		)
		var allowed: bool = not (
			banned_ids is Array and identity_id in banned_ids
		)
		var native_description := str(
			native_definition.get_script_constant_map().get(
				"classrace_definition",
				""
			)
		) if native_definition != null else ""
		if native_description.to_lower().begins_with("description will come soon"):
			native_description = ""
		options.append({
			"id": identity_id,
			"name": display_name,
			"nativeDefinition": native_definition,
			"allowed": allowed,
			"description": native_description,
			"tooltip": (
				"Not allowed by this scenario."
				if not allowed
				else native_description
			),
		})
	return options


func _refresh_identity_legality() -> void:
	for option_index: int in range(classic_race_options.size()):
		var option: Dictionary = classic_race_options[option_index]
		var allowed := bool(option.get("allowed", true))
		raceitemlist.set_item_disabled(option_index, not allowed)
		raceitemlist.set_item_tooltip(
			option_index,
			str(option.get("tooltip", ""))
		)
	for option_index: int in range(classic_caste_options.size()):
		var option: Dictionary = classic_caste_options[option_index]
		var allowed := bool(option.get("allowed", true))
		var pair_allowed := (
			classic_race_id == 0
			or ClassicStandardCharacterRulesScript.is_caste_allowed(
				character_rules_bundle,
				classic_race_id,
				int(option.get("id", 0))
			)
		)
		classitemlist.set_item_disabled(
			option_index,
			not allowed or not pair_allowed
		)
		var tooltip := str(option.get("tooltip", ""))
		if allowed and not pair_allowed:
			tooltip = "Not available to the selected race."
		classitemlist.set_item_tooltip(option_index, tooltip)


func _on_class_select(i : int) :
	if i < 0 or i >= classic_caste_options.size():
		return
	var option: Dictionary = classic_caste_options[i]
	new_char_class = option.get("nativeDefinition") as GDScript
	classic_caste_id = int(option.get("id", 0))
	_on_LineEdit_changed(lineEdit.text)
	characterstatrect.display_partial_selection(new_char_race, new_char_class)
	classDescriptionLabel.text = _class_description(i)
	_refresh_identity_legality()
	try_create_character()
	_refresh_creation_ui()

func _on_race_select(i : int) :
	if i < 0 or i >= classic_race_options.size():
		return
	var option: Dictionary = classic_race_options[i]
	new_char_race = option.get("nativeDefinition") as GDScript
	classic_race_id = int(option.get("id", 0))
	if classic_caste_id > 0 \
			and not ClassicStandardCharacterRulesScript.is_caste_allowed(
				character_rules_bundle,
				classic_race_id,
				classic_caste_id
			):
		classitemlist.deselect_all()
		new_char_class = null
		classic_caste_id = 0
		new_character = null
		spell_selection_prepared = false
	_on_LineEdit_changed(lineEdit.text)
	characterstatrect.display_partial_selection(new_char_race, new_char_class)
	raceDescriptionLabel.text = _race_description(i)
	_refresh_identity_legality()
	try_create_character()
	_refresh_creation_ui()


func _class_description(index: int) -> String:
	if index >= 0 and index < classic_caste_options.size():
		var option: Dictionary = classic_caste_options[index]
		return str(option.get("description", ""))
	if index >= 0 and index < classesgd.size():
		return str(classesgd[index].classrace_definition)
	return "Select a class to view its description."


func _race_description(index: int) -> String:
	if index >= 0 and index < classic_race_options.size():
		var option: Dictionary = classic_race_options[index]
		return str(option.get("description", ""))
	if index >= 0 and index < racesgd.size():
		return str(racesgd[index].classrace_definition)
	return "Select a race to view its description."

func _on_portrait_button_pressed(i : int) :
	new_char_portrait = portraitsTextures[i]
	if new_character :
		new_character.portrait = portraitsTextures[i]
	portraitRect.texture = portraitsTextures[i]
	characterstatrect.display_portrait( portraitsTextures[i])
	if i >= 0 and i < portraitButtons.size():
		portraitButtons[i].button_pressed = true
	_update_summary()


func _on_icon_button_pressed(i : int) :
	new_char_icon = iconsTextures[i]
	iconRect.texture = iconsTextures[i]
	if new_character :
		new_character.icon = iconsTextures[i]
	if i >= 0 and i < iconButtons.size():
		iconButtons[i].button_pressed = true
	_update_summary()

func _on_CancelButton_pressed() -> void :
	var campaign_panel := return_to_campaign_panel
	var campaign_name := classic_campaign_name
	fill()
	clear_classic_campaign_context()
	self.hide()
	if campaign_panel != null \
			and campaign_panel.has_method("resume_after_character_creation"):
		campaign_panel.call(
			"resume_after_character_creation",
			campaign_name
		)
#	self.get_parent().get_parent().newCampaignButton.show()

func _prepare_spell_selection_stage() -> bool:
	if spell_selection_prepared:
		return true
	if new_character==null or new_char_name == "" or new_char_class==null or new_char_race==null :
		okButton.disabled = true
		return false
	new_character.name = new_char_name
	if classic_install != null:
		new_character.cur_campaign = classic_campaign_name
	
	NodeAccess.__Resources().load_spell_resources("res://shared_assets/spells/")
	


	#var max_spell_level = new_character.classgd.max_spell_lvl
	#new_character.spells.clear()
	#for i  in  range(max_spell_level) :
		#new_character.spells.append([])

	abilities_rect.set_displayed_character(new_character, true, [])
	spell_selection_prepared = true
	_refresh_creation_ui()
	return true


func _finish_character_creation() -> void:
	if not spell_selection_prepared:
		if not _prepare_spell_selection_stage():
			return
	okButton.disabled = true
	abilities_rect.apply_selection()

	if classic_creation_active:
		var resources: Object = NodeAccess.__Resources()
		if resources != null:
			resources.load_item_resources("res://shared_assets/items/")
		if classic_install != null:
			var campaign_items_path: String = (
				classic_install.campaign_directory.path_join("Items") + "/"
			)
			if resources != null \
					and FileAccess.file_exists(
						campaign_items_path.path_join("stuff_book.json")
					):
				resources.load_item_resources(campaign_items_path)
		var item_book: Dictionary = (
			resources.items_book
			if resources != null and resources.items_book is Dictionary
			else {}
		)
		var item_ids: Object = ItemIdDivinity
		var item_mapping: Dictionary = (
			item_ids.mapping
			if item_ids != null and item_ids.mapping is Dictionary
			else {}
		)
		var resource_result := (
			ClassicCharacterRulesScript.apply_character_creation_resources(
				new_character,
				item_book,
				item_mapping
			)
		)
		if str(resource_result.get("status", "")) != "ok":
			classicContextLabel.text = str(resource_result.get(
				"message",
				"Classic starting resources could not be applied."
			))
			classicContextLabel.visible = true
			okButton.disabled = true
			return
	new_character.stats["curHP"] = new_character.get_stat("maxHP")
	match new_character.used_resource :
		"SP" :
			new_character.stats["curSP"] = new_character.get_stat("maxSP")


	var path = Paths.profilesfolderpath+Paths.currentProfileFolderName+'/Characters/'+new_char_name
	print("new char path : ", path)
	DirAccess.make_dir_recursive_absolute(path)

	Utils.FileHandler.save_character(path, new_character)


	GameGlobal.load_character_to_profile(new_character.name)

#	save_char.open(path+'/data.json', File.WRITE)
#	save_char.store_line('{"name":"'+new_char_name+'", "free":1}')
#	save_char.close()
#
#
#	var classsource : String = new_char_class.get_source_code()
#	save_char.open(path+'/class.gd', File.WRITE)
#	save_char.store_string(classsource)
#	save_char.close()
#	var racesource : String = new_char_race.get_source_code()
#	save_char.open(path+'/race.gd', File.WRITE)
#	save_char.store_string(racesource)
#	save_char.close()
#
#	var _err_savepng_portrait = new_char_portrait.get_data().save_png(path+"/portrait.png")
#	var _err_savepng_icon = new_char_icon.get_data().save_png(path+"/icon.png")

	_on_CancelButton_pressed()

func _on_LineEdit_changed(newtext : String) -> void :
	new_char_name = newtext
	if new_character != null:
		new_character.name = new_char_name
		if spell_selection_prepared:
			abilities_rect.refresh_character_heading()
	if new_char_name == "" :
		characterstatrect.display_name("")
		_refresh_creation_ui()
		return
	var is_valid_filename : Array = Utils.FileHandler.is_valid_file_name(new_char_name)
	if is_valid_filename[0]!=1 :
		characterstatrect.display_name(is_valid_filename[1])
		_refresh_creation_ui()
		return
	if DirAccess.dir_exists_absolute(Paths.profilesfolderpath+Paths.currentProfileFolderName+"/Characters/"+new_char_name) :
		characterstatrect.display_name("NAME ALREADY USED")
	else :
		characterstatrect.display_name(new_char_name)
	_refresh_creation_ui()

func fill() -> void :
	lineEdit.text = ""
	new_char_name = ""
	classitemlist.deselect_all()
	raceitemlist.deselect_all()
	new_char_race = null
	new_char_class = null
	new_char_portrait = default_portrait
	new_char_icon = default_icon
	for button: Button in portraitButtons:
		button.button_pressed = false
	for button: Button in iconButtons:
		button.button_pressed = false
	portraitRect.texture = default_portrait
	iconRect.texture = default_icon
	new_character = null
	spell_selection_prepared = false
	classic_creation_active = false
	classic_race_id = 0
	classic_caste_id = 0
	newchar_level = 1
	classic_gender = 1
	genderOptionButton.select(0)
	_normalizing_level_input = true
	levelInput.text = "1"
	_normalizing_level_input = false
	characterstatrect.clear()
	characterstatrect.display_portrait(default_portrait)
	classDescriptionLabel.text = "Select a class to view its description."
	raceDescriptionLabel.text = "Select a race to view its description."
	_refresh_identity_legality()
	_update_mode_copy()
	_show_appearance_browser(true)
	_show_stage(CreationStage.IDENTITY, false)


func _on_gender_selected(index: int) -> void:
	classic_gender = index + 1
	if new_char_class != null and new_char_race != null:
		try_create_character()
	_refresh_creation_ui()
# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass


func _on_visibility_changed():
	if visible:
		# Panel is being shown - play character creation music
		print("Starting character creation music")
		# Store current music info so we can restore it later
		previous_music_info = MusicStreamPlayer.currently_playing.duplicate()
		MusicStreamPlayer.play_music_type("Create")
	else:
		# Panel is being hidden - restore previous music
		print("Stopping character creation music")
		if previous_music_info != null and previous_music_info.has("path") and previous_music_info["path"] != '':
			# Restore the previous music
			MusicStreamPlayer.play_music(previous_music_info)
		else:
			# No previous music was playing, so stop music
			MusicStreamPlayer.stop()
		previous_music_info = null
