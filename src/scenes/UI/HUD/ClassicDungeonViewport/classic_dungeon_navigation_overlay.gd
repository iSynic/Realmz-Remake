class_name ClassicDungeonNavigationOverlay
extends Control

signal navigation_requested(action: StringName)

const ACTION_FORWARD := &"move_up"
const ACTION_BACK := &"move_down"
const ACTION_TURN_LEFT := &"move_left"
const ACTION_TURN_RIGHT := &"move_right"

const CURSOR_FORWARD := preload("res://shared_assets/cursors/forward.png")
const CURSOR_BACK := preload("res://shared_assets/cursors/reverse.png")
const CURSOR_TURN_LEFT := preload("res://shared_assets/cursors/left.png")
const CURSOR_TURN_RIGHT := preload("res://shared_assets/cursors/right.png")


func _ready() -> void:
	mouse_exited.connect(_on_mouse_exited)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_preview_cursor(_action_at_position(event.position))
		return
	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	var action := _action_at_position(mouse_event.position)
	if action.is_empty():
		return
	accept_event()
	navigation_requested.emit(action)


func _action_at_position(local_position: Vector2) -> StringName:
	if (
		size.x <= 0.0
		or size.y <= 0.0
		or not Rect2(Vector2.ZERO, size).has_point(local_position)
	):
		return &""
	var horizontal_third := size.x / 3.0
	if local_position.x < horizontal_third:
		return ACTION_TURN_LEFT
	if local_position.x >= horizontal_third * 2.0:
		return ACTION_TURN_RIGHT
	if local_position.y < size.y * (2.0 / 3.0):
		return ACTION_FORWARD
	return ACTION_BACK


func _set_preview_cursor(action: StringName) -> void:
	var cursor_spec := _cursor_spec(action)
	if cursor_spec.is_empty():
		return
	Input.set_custom_mouse_cursor(
		cursor_spec["texture"],
		Input.CURSOR_ARROW,
		cursor_spec["hotspot"]
	)


func _cursor_spec(action: StringName) -> Dictionary:
	match action:
		ACTION_FORWARD:
			return {"texture": CURSOR_FORWARD, "hotspot": Vector2(8.0, 0.0)}
		ACTION_BACK:
			return {"texture": CURSOR_BACK, "hotspot": Vector2(8.0, 15.0)}
		ACTION_TURN_LEFT:
			return {"texture": CURSOR_TURN_LEFT, "hotspot": Vector2(0.0, 8.0)}
		ACTION_TURN_RIGHT:
			return {"texture": CURSOR_TURN_RIGHT, "hotspot": Vector2(15.0, 8.0)}
		_:
			return {}


func _on_mouse_exited() -> void:
	Input.set_custom_mouse_cursor(UI.cursor_sword)
