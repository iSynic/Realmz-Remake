extends ValidationManager.Validation

const STONE_TEXTURE_PATH := "res://shared_assets/UI/StonePatternRect9.png"
const EXCLUDED_DIRECTORIES := [
	"res://.godot",
	"res://addons",
	"/fixtures/",
]

var _resource_id_pattern := RegEx.new()
var _node_name_pattern := RegEx.new()


func get_name() -> String:
	return "Classic stone nine-patch texture filtering"


func run_validations() -> bool:
	_resource_id_pattern.compile('id="([^"]+)"')
	_node_name_pattern.compile('^\\[node name="([^"]+)"')

	var scene_paths: Array[String] = []
	var valid := _collect_scenes("res://", scene_paths)
	scene_paths.sort()
	for scene_path: String in scene_paths:
		valid = _validate_scene(scene_path) and valid
	return valid


func _collect_scenes(
	directory_path: String,
	scene_paths: Array[String],
) -> bool:
	if _is_excluded_directory(directory_path):
		return true

	var directory := DirAccess.open(directory_path)
	if directory == null:
		push_error("Unable to scan scene directory: %s" % directory_path)
		return false

	var valid := true
	for file_name: String in directory.get_files():
		if file_name.get_extension().to_lower() == "tscn":
			scene_paths.append(directory_path.path_join(file_name))
	for child_name: String in directory.get_directories():
		valid = _collect_scenes(
			directory_path.path_join(child_name),
			scene_paths,
		) and valid
	return valid


func _is_excluded_directory(directory_path: String) -> bool:
	if directory_path in EXCLUDED_DIRECTORIES:
		return true
	for marker: String in EXCLUDED_DIRECTORIES:
		if marker.begins_with("/") and directory_path.contains(marker):
			return true
	return false


func _validate_scene(scene_path: String) -> bool:
	var file := FileAccess.open(scene_path, FileAccess.READ)
	if file == null:
		push_error("Unable to read scene: %s" % scene_path)
		return false

	var lines: Array[String] = []
	var stone_resource_ids: Dictionary = {}
	while not file.eof_reached():
		var line := file.get_line()
		lines.append(line)
		if not line.begins_with("[ext_resource ") \
				or not line.contains('path="%s"' % STONE_TEXTURE_PATH):
			continue
		var resource_id_match := _resource_id_pattern.search(line)
		if resource_id_match != null:
			stone_resource_ids[resource_id_match.get_string(1)] = true

	if stone_resource_ids.is_empty():
		return true

	var valid := true
	var node_name := "<unknown>"
	var node_line := 0
	var node_filter := CanvasItem.TEXTURE_FILTER_PARENT_NODE
	var node_uses_stone := false
	for line_index: int in range(lines.size() + 1):
		var line := lines[line_index] if line_index < lines.size() else "[node end]"
		if line.begins_with("[node ") or line_index == lines.size():
			if node_uses_stone and node_filter != CanvasItem.TEXTURE_FILTER_NEAREST:
				push_error(
					"%s:%d node %s renders %s without nearest filtering" % [
						scene_path,
						node_line,
						node_name,
						STONE_TEXTURE_PATH,
					]
				)
				valid = false
			node_name = "<unknown>"
			node_line = line_index + 1
			node_filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
			node_uses_stone = false
			var node_name_match := _node_name_pattern.search(line)
			if node_name_match != null:
				node_name = node_name_match.get_string(1)
			continue

		if line.begins_with("texture_filter = "):
			node_filter = int(line.trim_prefix("texture_filter = "))
		elif line.begins_with('texture = ExtResource("'):
			for resource_id: String in stone_resource_ids:
				if line == 'texture = ExtResource("%s")' % resource_id:
					node_uses_stone = true
					break
	return valid
