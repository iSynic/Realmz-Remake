extends SceneTree

const BundleScript = preload(
	"res://scripts/classic_runtime/classic_campaign_bundle.gd"
)
const MapMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_map_materializer.gd"
)
const ItemMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_item_materializer.gd"
)
const BestiaryMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_bestiary_materializer.gd"
)
const GENERATED_DIRECTORIES := ["Bestiary", "Items", "Maps", "Tilesets"]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	var root := "res://Campaigns"
	var expected_count := 13
	var replace_generated := false
	for argument: String in arguments:
		if argument.begins_with("--expected-count="):
			expected_count = int(argument.trim_prefix("--expected-count="))
		elif argument == "--replace-generated":
			replace_generated = true
		elif not argument.begins_with("--"):
			root = argument
	var directories := _campaign_directories(root)
	if expected_count > 0 and directories.size() != expected_count:
		printerr(
			"Expected %d built-in Classic campaigns, found %d"
			% [expected_count, directories.size()]
		)
		quit(1)
		return
	for directory: String in directories:
		if replace_generated:
			var cleanup_error := _remove_generated_directories(root, directory)
			if cleanup_error != OK:
				printerr(
					"%s: could not replace generated campaign data: %s"
					% [directory.get_file(), error_string(cleanup_error)]
				)
				quit(1)
				return
		var bundle = BundleScript.new()
		if not bundle.load_from_directory(directory):
			printerr("%s: %s" % [directory.get_file(), bundle.last_error])
			quit(1)
			return
		for materializer in [
			MapMaterializerScript.new(),
			ItemMaterializerScript.new(),
			BestiaryMaterializerScript.new(),
		]:
			var result: Dictionary = materializer.materialize(bundle, directory)
			if str(result.get("status", "")) != "ok":
				printerr("%s: %s" % [directory.get_file(), materializer.last_error])
				quit(1)
				return
		print("Materialized %s" % directory.get_file())
	quit(0)


func _campaign_directories(root: String) -> Array[String]:
	var result: Array[String] = []
	var access := DirAccess.open(root)
	if access == null:
		return result
	access.list_dir_begin()
	var entry := access.get_next()
	while not entry.is_empty():
		if (
			access.current_is_dir()
			and entry.ends_with(" (Classic)")
			and FileAccess.file_exists(root.path_join(entry).path_join("campaign.json"))
		):
			result.append(root.path_join(entry))
		entry = access.get_next()
	access.list_dir_end()
	result.sort()
	return result


func _remove_generated_directories(root: String, campaign_directory: String) -> Error:
	var normalized_root := root.trim_suffix("/")
	var normalized_campaign := campaign_directory.trim_suffix("/")
	if (
		not normalized_campaign.begins_with(normalized_root + "/")
		or not normalized_campaign.get_file().ends_with(" (Classic)")
	):
		return ERR_INVALID_PARAMETER
	for directory_name: String in GENERATED_DIRECTORIES:
		var generated_directory := normalized_campaign.path_join(directory_name)
		if DirAccess.dir_exists_absolute(generated_directory):
			var remove_error := _remove_directory_tree(generated_directory)
			if remove_error != OK:
				return remove_error
	return OK


func _remove_directory_tree(directory: String) -> Error:
	var access := DirAccess.open(directory)
	if access == null:
		return DirAccess.get_open_error()
	access.list_dir_begin()
	var entry := access.get_next()
	while not entry.is_empty():
		var child := directory.path_join(entry)
		var remove_error := OK
		if access.current_is_dir():
			remove_error = _remove_directory_tree(child)
		else:
			remove_error = DirAccess.remove_absolute(child)
		if remove_error != OK:
			access.list_dir_end()
			return remove_error
		entry = access.get_next()
	access.list_dir_end()
	return DirAccess.remove_absolute(directory)
