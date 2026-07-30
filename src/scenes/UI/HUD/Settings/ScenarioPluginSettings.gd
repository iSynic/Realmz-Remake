extends NinePatchRect

const PluginStoreScript = preload(
	"res://scripts/scenario_runtime/scenario_engine_plugin_store.gd"
)

@onready var plugin_list: ItemList = %PluginList
@onready var detail_title: Label = %PluginDetailTitle
@onready var detail_body: RichTextLabel = %PluginDetailBody
@onready var status_label: Label = %PluginStatus
@onready var approve_button: Button = %ApprovePluginButton
@onready var revoke_button: Button = %RevokePluginButton
@onready var remove_button: Button = %RemovePluginButton
@onready var manifest_dialog: FileDialog = %PluginManifestDialog
@onready var install_dialog: ConfirmationDialog = %InstallPluginDialog
@onready var approval_dialog: ConfirmationDialog = %ApprovePluginDialog
@onready var removal_dialog: ConfirmationDialog = %RemovePluginDialog

var store := PluginStoreScript.new()
var plugins: Array = []
var selected_plugin_id := ""
var pending_manifest_path := ""
var pending_update := false


func _ready() -> void:
	%InstallPluginButton.pressed.connect(_on_install_pressed)
	%RefreshPluginsButton.pressed.connect(_refresh)
	plugin_list.item_selected.connect(_on_plugin_selected)
	manifest_dialog.file_selected.connect(_on_manifest_selected)
	install_dialog.confirmed.connect(_on_install_confirmed)
	approve_button.pressed.connect(_on_approve_pressed)
	approval_dialog.confirmed.connect(_on_approve_confirmed)
	revoke_button.pressed.connect(_on_revoke_pressed)
	remove_button.pressed.connect(_on_remove_pressed)
	removal_dialog.confirmed.connect(_on_remove_confirmed)
	_show_no_selection()


func _initialize() -> void:
	_refresh()


func _refresh(preferred_id := "") -> void:
	if not preferred_id.is_empty():
		selected_plugin_id = preferred_id
	plugins = store.plugin_descriptors()
	plugin_list.clear()
	if not store.last_error.is_empty():
		_set_status(store.last_error, true)
		_show_no_selection()
		return
	for plugin_value: Variant in plugins:
		if not (plugin_value is Dictionary):
			continue
		var plugin: Dictionary = plugin_value
		var plugin_id := str(plugin.get("id", ""))
		var display_name := str(
			plugin.get("displayName", plugin_id)
		).strip_edges()
		var approval := (
			"Approved" if bool(plugin.get("approved", false)) else "Not approved"
		)
		var row := plugin_list.add_item("%s\n%s" % [display_name, approval])
		plugin_list.set_item_metadata(row, plugin_id)
		if plugin_id == selected_plugin_id:
			plugin_list.select(row)
	if plugins.is_empty():
		selected_plugin_id = ""
		_show_no_selection()
		_set_status("No scenario engine plug-ins are installed.")
		return
	var selected_index := _index_for_id(selected_plugin_id)
	if selected_index < 0:
		selected_index = 0
		selected_plugin_id = str(
			plugin_list.get_item_metadata(selected_index)
		)
		plugin_list.select(selected_index)
	_show_selected()
	_set_status("")


func _on_install_pressed() -> void:
	manifest_dialog.popup_centered_ratio(0.72)


func _on_manifest_selected(path: String) -> void:
	var inspection: Dictionary = store.inspect_manifest(path)
	if inspection.get("status") != "ok":
		_set_status(str(inspection.get("message", "Plug-in package is invalid")), true)
		return
	var descriptor: Dictionary = inspection.get("descriptor", {})
	var plugin_id := str(descriptor.get("id", ""))
	pending_manifest_path = path
	pending_update = _plugin_is_installed(plugin_id)
	install_dialog.title = (
		"Update Scenario Engine Plug-in"
		if pending_update
		else "Install Scenario Engine Plug-in"
	)
	install_dialog.ok_button_text = "Update" if pending_update else "Install"
	install_dialog.dialog_text = "%s\n\n%s\n\n%s" % [
		_package_summary(descriptor),
		(
			"Updating replaces the installed package and revokes its approval."
			if pending_update
			else "Installation does not execute the plug-in. It remains disabled until you approve it."
		),
		"Only install plug-ins from authors you trust.",
	]
	install_dialog.popup_centered()


func _on_install_confirmed() -> void:
	if pending_manifest_path.is_empty():
		return
	var result: Dictionary = store.install_from_manifest(
		pending_manifest_path,
		pending_update
	)
	pending_manifest_path = ""
	pending_update = false
	if result.get("status") != "ok":
		_set_status(str(result.get("message", "Could not install plug-in")), true)
		return
	var plugin_id := str(result.get("id", ""))
	_refresh(plugin_id)
	_set_status(str(result.get("message", "Plug-in installed.")))


func _on_plugin_selected(index: int) -> void:
	selected_plugin_id = str(plugin_list.get_item_metadata(index))
	_show_selected()


func _on_approve_pressed() -> void:
	var plugin := _selected_descriptor()
	if plugin.is_empty():
		return
	approval_dialog.dialog_text = (
		"%s\n\n"
		+ "This plug-in runs in Remake with your account privileges and may "
		+ "access Godot, files, the network, or other operating-system services.\n\n"
		+ "Approval applies only to this exact package and metadata hash:\n%s"
	) % [
		str(plugin.get("displayName", plugin.get("id", ""))),
		str(plugin.get("contentHash", "")),
	]
	approval_dialog.popup_centered()


func _on_approve_confirmed() -> void:
	if selected_plugin_id.is_empty():
		return
	if not store.approve(selected_plugin_id):
		_set_status(store.last_error, true)
		return
	var approved_id := selected_plugin_id
	_refresh(approved_id)
	_set_status("Approved '%s' for this exact package." % approved_id)


func _on_revoke_pressed() -> void:
	if selected_plugin_id.is_empty():
		return
	if not store.revoke(selected_plugin_id):
		_set_status(store.last_error, true)
		return
	var revoked_id := selected_plugin_id
	_refresh(revoked_id)
	_set_status("Revoked approval for '%s'." % revoked_id)


func _on_remove_pressed() -> void:
	var plugin := _selected_descriptor()
	if plugin.is_empty():
		return
	removal_dialog.dialog_text = (
		"Remove '%s'?\n\nCampaigns requiring this plug-in will not be ready "
		+ "until it is installed and approved again."
	) % str(plugin.get("displayName", plugin.get("id", "")))
	removal_dialog.popup_centered()


func _on_remove_confirmed() -> void:
	if selected_plugin_id.is_empty():
		return
	var removed_id := selected_plugin_id
	if not store.remove(removed_id):
		_set_status(store.last_error, true)
		return
	selected_plugin_id = ""
	_refresh()
	_set_status("Removed '%s'." % removed_id)


func _show_selected() -> void:
	var plugin := _selected_descriptor()
	if plugin.is_empty():
		_show_no_selection()
		return
	var plugin_id := str(plugin.get("id", ""))
	var approved := bool(plugin.get("approved", false))
	detail_title.text = str(plugin.get("displayName", plugin_id))
	detail_body.text = _descriptor_details(plugin)
	approve_button.disabled = approved
	revoke_button.disabled = not approved
	remove_button.disabled = false


func _show_no_selection() -> void:
	detail_title.text = "Scenario Engine Plug-ins"
	detail_body.text = (
		"Install a plugin.json package to inspect its identity, files, and "
		+ "capabilities. Installed plug-ins do not run until explicitly approved."
	)
	approve_button.disabled = true
	revoke_button.disabled = true
	remove_button.disabled = true


func _selected_descriptor() -> Dictionary:
	for plugin_value: Variant in plugins:
		if plugin_value is Dictionary \
				and str(plugin_value.get("id", "")) == selected_plugin_id:
			return plugin_value
	return {}


func _plugin_is_installed(plugin_id: String) -> bool:
	for plugin_value: Variant in plugins:
		if plugin_value is Dictionary \
				and str(plugin_value.get("id", "")) == plugin_id:
			return true
	return false


func _index_for_id(plugin_id: String) -> int:
	for index: int in range(plugin_list.item_count):
		if str(plugin_list.get_item_metadata(index)) == plugin_id:
			return index
	return -1


func _descriptor_details(plugin: Dictionary) -> String:
	var operation_ids: Array[String] = []
	for operation_value: Variant in plugin.get("operations", []):
		if operation_value is Dictionary:
			operation_ids.append(str(operation_value.get("id", "")))
	var provider_ids: Array[String] = []
	for provider_value: Variant in plugin.get("providers", []):
		if provider_value is Dictionary:
			provider_ids.append(str(provider_value.get("id", "")))
	var file_names: Array[String] = []
	for file_value: Variant in plugin.get("files", []):
		if file_value is Dictionary:
			file_names.append(str(file_value.get("path", "")))
	return "\n".join([
		str(plugin.get("description", "")).strip_edges(),
		"",
		"Stable ID: %s" % plugin.get("id", ""),
		"API version: %d" % int(plugin.get("apiVersion", 0)),
		"Status: %s" % (
			"Approved for this exact package"
			if bool(plugin.get("approved", false))
			else "Installed, not approved"
		),
		"Package hash: %s" % plugin.get("contentHash", ""),
		"Entry point: %s" % plugin.get("entryPoint", ""),
		"",
		"Declared files (%d):\n%s" % [
			file_names.size(),
			"\n".join(file_names) if not file_names.is_empty() else "None",
		],
		"",
		"Scenario operations (%d):\n%s" % [
			operation_ids.size(),
			"\n".join(operation_ids) if not operation_ids.is_empty() else "None",
		],
		"",
		"Providers (%d):\n%s" % [
			provider_ids.size(),
			"\n".join(provider_ids) if not provider_ids.is_empty() else "None",
		],
	])


func _package_summary(plugin: Dictionary) -> String:
	return "%s\nID: %s\nAPI: %d\nFiles: %d\nPackage hash: %s" % [
		str(plugin.get("displayName", plugin.get("id", ""))),
		plugin.get("id", ""),
		int(plugin.get("apiVersion", 0)),
		plugin.get("files", []).size(),
		plugin.get("contentHash", ""),
	]


func _set_status(message: String, is_error := false) -> void:
	status_label.text = message
	status_label.modulate = (
		Color(1.0, 0.35, 0.25)
		if is_error
		else Color(0.35, 1.0, 0.75)
	)
