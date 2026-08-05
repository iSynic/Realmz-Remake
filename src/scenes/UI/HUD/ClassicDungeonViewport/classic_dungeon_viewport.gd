class_name ClassicDungeonViewport
extends Control

const MeshBuilderScript = preload(
	"res://scenes/UI/HUD/ClassicDungeonViewport/classic_dungeon_mesh_builder.gd"
)
const INTERNAL_SIZE := Vector2i(320, 180)
const MOVE_TWEEN_SECONDS := 0.14
const TURN_TWEEN_SECONDS := 0.11

const ATLAS := preload(
	"res://assets/classic_dungeon_3d/classic_dungeon_atlas.png"
)

@onready var _display: TextureRect = $Display
@onready var _navigation_overlay: ClassicDungeonNavigationOverlay = $NavigationOverlay
@onready var _subviewport: SubViewport = $SubViewport
@onready var _camera: Camera3D = $SubViewport/World/Camera3D
@onready var _geometry: MeshInstance3D = $SubViewport/World/Geometry

var _snapshot: Dictionary = {}
var _pending_step: Dictionary = {}
var _pending_command := &""
var _buffered_action := &""
var _navigation_locked := false
var _active_tween: Tween
var _display_scale := 1.0
var _geometry_signature := 0


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.texture = _subviewport.get_texture()
	_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not GameGlobal.classic_dungeon_view_changed.is_connected(_on_snapshot_changed):
		GameGlobal.classic_dungeon_view_changed.connect(_on_snapshot_changed)
	if not GameGlobal.exploration_step_resolved.is_connected(_on_step_resolved):
		GameGlobal.exploration_step_resolved.connect(_on_step_resolved)
	if not StateMachine.state_changed.is_connected(_on_game_state_changed):
		StateMachine.state_changed.connect(_on_game_state_changed)
	_navigation_overlay.navigation_requested.connect(_on_navigation_requested)
	resized.connect(_layout_internal_view)
	call_deferred(&"refresh_from_runtime")
	call_deferred(&"_layout_internal_view")


func _exit_tree() -> void:
	_set_native_map_visible(true)


func refresh_from_runtime() -> void:
	_on_snapshot_changed(GameGlobal.get_dungeon_view_snapshot())


func is_navigation_active() -> bool:
	return (
		is_presentation_active()
		and bool(_snapshot.get("active", false))
		and int(_snapshot.get("viewType", -1)) == 1
		and StateMachine._state_name == "Exploration"
		and not _hud_has_blocking_overlay()
	)


func is_presentation_active() -> bool:
	return (
		visible
		and _snapshot_requests_3d()
		and bool(StateMachine.is_exploration_state())
	)


func begin_navigation(action: StringName) -> Dictionary:
	if not is_navigation_active():
		return {"handled": false, "accepted": false}
	if action in [&"move_upleft", &"move_upright", &"move_downleft", &"move_downright"]:
		return {"handled": true, "accepted": false, "reason": "diagonal"}
	if _navigation_locked:
		_buffered_action = action
		return {"handled": true, "accepted": false, "buffered": true}
	_navigation_locked = true
	_pending_command = action
	return {"handled": true, "accepted": true}


func cancel_navigation() -> void:
	_pending_step.clear()
	_pending_command = &""
	_buffered_action = &""
	_navigation_locked = false
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_snap_camera_to_snapshot()


func _on_snapshot_changed(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	var show_3d: bool = (
		_snapshot_requests_3d()
		and bool(StateMachine.is_exploration_state())
	)
	visible = show_3d
	_subviewport.render_target_update_mode = (
		SubViewport.UPDATE_ALWAYS if show_3d else SubViewport.UPDATE_DISABLED
	)
	if StateMachine.is_exploration_state():
		_set_native_map_visible(not show_3d)
	if not show_3d:
		return
	if bool(_pending_step.get("success", false)):
		_snapshot["openDoorPosition"] = _pending_step.get("finalPosition")
	var geometry_signature := _snapshot_geometry_signature(_snapshot)
	if geometry_signature != _geometry_signature or _geometry.mesh == null:
		_geometry_signature = geometry_signature
		var build_result: Dictionary = MeshBuilderScript.build(_snapshot, ATLAS)
		_geometry.mesh = build_result.get("mesh")
		if int(build_result.get("buildUsec", 0)) > 8000:
			push_warning(
				"Classic dungeon geometry rebuild took %.2f ms"
				% (float(build_result.get("buildUsec", 0)) / 1000.0)
			)
	_animate_authoritative_change()


func _on_step_resolved(result: Dictionary) -> void:
	_pending_step = result.duplicate(true)
	if not bool(result.get("success", false)):
		call_deferred(&"_finish_transition")


func _animate_authoritative_change() -> void:
	if not _pending_step.is_empty() and bool(_pending_step.get("success", false)):
		var original: Vector2i = _pending_step.get("originalPosition", Vector2i.ZERO)
		var final: Vector2i = _pending_step.get("finalPosition", original)
		var same_map := (
			str(_pending_step.get("originalMapIdentity", ""))
			== str(_pending_step.get("mapIdentity", ""))
		)
		var offset := final - original
		var ordinary_step := absi(offset.x) + absi(offset.y) == 1
		if same_map and ordinary_step:
			_camera.position = Vector3(
				float(original.x - final.x),
				0.72,
				float(original.y - final.y)
			)
			_camera.rotation.y = _heading_yaw(int(_snapshot.get("heading", 1)))
			_start_camera_tween(&"position", Vector3(0.0, 0.72, 0.0), MOVE_TWEEN_SECONDS)
			return
	if _pending_command in [&"move_left", &"move_right"]:
		var target_yaw := _heading_yaw(int(_snapshot.get("heading", 1)))
		var current_yaw := _camera.rotation.y
		var delta := wrapf(target_yaw - current_yaw, -PI, PI)
		_start_camera_tween(&"rotation:y", current_yaw + delta, TURN_TWEEN_SECONDS)
		return
	_snap_camera_to_snapshot()
	_finish_transition()


func _start_camera_tween(property: StringName, target: Variant, duration: float) -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_QUAD)
	_active_tween.set_ease(Tween.EASE_IN_OUT)
	_active_tween.tween_property(_camera, NodePath(property), target, duration)
	_active_tween.finished.connect(_finish_transition, CONNECT_ONE_SHOT)


func _finish_transition() -> void:
	_pending_step.clear()
	_pending_command = &""
	_navigation_locked = false
	var buffered := _buffered_action
	_buffered_action = &""
	if not buffered.is_empty() and is_navigation_active():
		StateMachine.call_deferred(&"request_classic_dungeon_navigation", buffered)


func _snap_camera_to_snapshot() -> void:
	_camera.position = Vector3(0.0, 0.72, 0.0)
	_camera.rotation = Vector3(0.0, _heading_yaw(int(_snapshot.get("heading", 1))), 0.0)


func _layout_internal_view() -> void:
	if not is_node_ready():
		return
	var available_scale := minf(
		size.x / float(INTERNAL_SIZE.x),
		size.y / float(INTERNAL_SIZE.y)
	)
	if available_scale >= 1.0:
		_display_scale = float(floori(available_scale))
	elif available_scale >= 0.5:
		# HD mode halves logical space while doubling physical pixels. A reciprocal
		# integer keeps the 320x180 source pixel grid exact instead of clipping it.
		_display_scale = 0.5
	else:
		_display_scale = 0.25
	var display_size := Vector2(INTERNAL_SIZE) * _display_scale
	_display.size = display_size
	_display.position = (size - display_size) * 0.5
	_navigation_overlay.size = display_size
	_navigation_overlay.position = _display.position


func _on_navigation_requested(action: StringName) -> void:
	if not is_navigation_active():
		return
	StateMachine.request_classic_dungeon_navigation(action)


func _on_game_state_changed(_previous: String, _current: String) -> void:
	if not StateMachine.is_exploration_state():
		visible = false
		_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_set_native_map_visible(true)
		cancel_navigation()
		return
	refresh_from_runtime()


func _snapshot_requests_3d() -> bool:
	return (
		bool(_snapshot.get("active", false))
		and int(_snapshot.get("viewType", -1)) == 1
	)


func _hud_has_blocking_overlay() -> bool:
	var hud := get_parent()
	while hud != null and not hud.has_method("has_blocking_overlay_visible"):
		hud = hud.get_parent()
	return hud != null and bool(hud.call("has_blocking_overlay_visible"))


func _set_native_map_visible(map_visible: bool) -> void:
	var native_map: Variant = GameGlobal.map
	if native_map is CanvasItem and is_instance_valid(native_map):
		native_map.visible = map_visible


static func _heading_yaw(heading: int) -> float:
	match heading:
		2:
			return -PI * 0.5
		3:
			return PI
		4:
			return PI * 0.5
		_:
			return 0.0


static func _snapshot_geometry_signature(snapshot: Dictionary) -> int:
	var values: Array = [
		int(snapshot.get("levelIndex", -1)),
		snapshot.get("origin", Vector2i.ZERO),
		snapshot.get("openDoorPosition"),
	]
	for cell_value: Variant in snapshot.get("cells", []):
		if cell_value is Dictionary:
			values.append(int(cell_value.get("unsignedField", 0)))
	return hash(values)
