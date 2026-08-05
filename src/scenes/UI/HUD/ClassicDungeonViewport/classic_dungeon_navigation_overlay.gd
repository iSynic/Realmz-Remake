class_name ClassicDungeonNavigationOverlay
extends Control

signal navigation_requested(action: StringName)

const ACTION_FORWARD := &"move_up"
const ACTION_BACK := &"move_down"
const ACTION_TURN_LEFT := &"move_left"
const ACTION_TURN_RIGHT := &"move_right"

func _ready() -> void:
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _gui_input(event: InputEvent) -> void:
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


func _get_tooltip(at_position: Vector2) -> String:
	match _action_at_position(at_position):
		ACTION_FORWARD:
			return "Move forward (Up / 8)"
		ACTION_BACK:
			return "Move backward (Down / 2)"
		ACTION_TURN_LEFT:
			return "Turn left (Left / 4)"
		ACTION_TURN_RIGHT:
			return "Turn right (Right / 6)"
		_:
			return ""


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
