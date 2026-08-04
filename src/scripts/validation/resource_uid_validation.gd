extends ValidationManager.Validation

const RESOURCE_EXTENSIONS := ["tscn", "tres"]
const EXCLUDED_DIRECTORIES := [
	"res://.godot",
	"res://addons",
	"/fixtures/",
]

var _uid_pattern := RegEx.new()
var _path_pattern := RegEx.new()


func get_name() -> String:
	return "resource UID references"


func run_validations() -> bool:
	_uid_pattern.compile('uid="(uid://[^"]+)"')
	_path_pattern.compile('path="(res://[^"]+)"')

	var owners: Array[String] = []
	var valid := _collect_resource_owners("res://", owners)
	owners.sort()

	for owner_path: String in owners:
		valid = _validate_owner(owner_path) and valid
	return valid


func _collect_resource_owners(
	directory_path: String,
	owners: Array[String],
) -> bool:
	if _is_excluded_directory(directory_path):
		return true

	var directory := DirAccess.open(directory_path)
	if directory == null:
		push_error("Unable to scan resource directory: %s" % directory_path)
		return false

	var valid := true
	for file_name: String in directory.get_files():
		if file_name.get_extension().to_lower() in RESOURCE_EXTENSIONS:
			owners.append(directory_path.path_join(file_name))
	for child_name: String in directory.get_directories():
		valid = _collect_resource_owners(
			directory_path.path_join(child_name),
			owners,
		) and valid
	return valid


func _is_excluded_directory(directory_path: String) -> bool:
	if directory_path in EXCLUDED_DIRECTORIES:
		return true
	for marker: String in EXCLUDED_DIRECTORIES:
		if marker.begins_with("/") and directory_path.contains(marker):
			return true
	return false


func _validate_owner(owner_path: String) -> bool:
	var file := FileAccess.open(owner_path, FileAccess.READ)
	if file == null:
		push_error("Unable to read resource owner: %s" % owner_path)
		return false

	var valid := true
	var line_number := 0
	while not file.eof_reached():
		line_number += 1
		var line := file.get_line()
		if not line.begins_with("[ext_resource "):
			continue

		var uid_match := _uid_pattern.search(line)
		var path_match := _path_pattern.search(line)
		if uid_match == null or path_match == null:
			continue

		var declared_uid := uid_match.get_string(1)
		var resource_path := path_match.get_string(1)
		var registered_uid := ResourceUID.path_to_uid(resource_path)
		if registered_uid == declared_uid:
			continue

		push_error(
			"%s:%d declares %s for %s; registered UID is %s" % [
				owner_path,
				line_number,
				declared_uid,
				resource_path,
				registered_uid,
			]
		)
		valid = false
	return valid
