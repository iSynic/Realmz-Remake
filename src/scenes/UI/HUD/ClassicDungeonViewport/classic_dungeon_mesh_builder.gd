class_name ClassicDungeonMeshBuilder
extends RefCounted

const ViewModelScript = preload(
	"res://scripts/classic_runtime/classic_dungeon_view_model.gd"
)

const ATLAS_SIZE := Vector2(512.0, 512.0)
const WALL_UV := Rect2(0.0, 0.0, 64.0, 64.0)
const DOOR_UV := Rect2(64.0, 0.0, 128.0, 144.0)
const STAIR_UV := Rect2(192.0, 0.0, 128.0, 128.0)
const ARCH_UV := Rect2(320.0, 0.0, 64.0, 64.0)
const FLOOR_UV := Rect2(384.0, 0.0, 64.0, 64.0)
const CEILING_UV := Rect2(448.0, 0.0, 64.0, 64.0)
const PILLAR_UV := Rect2(20.0, 20.0, 1.0, 1.0)
const ROOM_HEIGHT := 1.5

static var _shared_material: ShaderMaterial
static var _shared_atlas_id := 0


static func build(snapshot: Dictionary, atlas: Texture2D) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if not bool(snapshot.get("active", false)) or atlas == null:
		return {"mesh": null, "triangles": 0, "buildUsec": 0}

	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_material(_material_for_atlas(atlas))
	var triangle_count := 0
	var cells_by_offset: Dictionary = {}
	var opening_position: Variant = snapshot.get("openDoorPosition")
	for cell_value: Variant in snapshot.get("cells", []):
		if not (cell_value is Dictionary):
			continue
		var cell: Dictionary = cell_value
		cells_by_offset[cell.get("offset", Vector2i.ZERO)] = cell

	for cell_value: Variant in snapshot.get("cells", []):
		if not (cell_value is Dictionary):
			continue
		var cell: Dictionary = cell_value
		var offset: Vector2i = cell.get("offset", Vector2i.ZERO)
		var center := Vector3(float(offset.x), 0.0, float(offset.y))
		var field := int(cell.get("unsignedField", 0))
		var fade := _distance_fade(offset)
		var color := Color(fade, fade, fade, 1.0)
		var has_stair := (field & ViewModelScript.FIELD_STAIR) != 0
		var has_arch := (field & ViewModelScript.FIELD_REVEALED_ARCH) != 0
		var has_north_south_door := (
			field & ViewModelScript.FIELD_DOOR_NORTH_SOUTH
		) != 0
		var has_east_west_door := (
			field & ViewModelScript.FIELD_DOOR_EAST_WEST
		) != 0
		var has_door := has_north_south_door or has_east_west_door
		var door_open: bool = offset == Vector2i.ZERO \
			or (opening_position is Vector2i \
			and opening_position == cell.get("position"))
		var is_open := _is_open_cell(cell)

		if not is_open:
			continue
		if has_stair:
			triangle_count += _add_recessed_stair(surface, center, color)
		else:
			triangle_count += _add_floor_and_ceiling(surface, center, color)
		if has_arch:
			triangle_count += _add_arch_frames(surface, center, color)
		elif has_door:
			if has_north_south_door:
				triangle_count += _add_doorway(
					surface, center, false, door_open, color
				)
			if has_east_west_door:
				triangle_count += _add_doorway(
					surface, center, true, door_open, color
				)

		for direction: Vector2i in [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]:
			var neighbor: Variant = cells_by_offset.get(offset + direction)
			if not _is_open_cell(neighbor):
				triangle_count += _add_wall_boundary(
					surface, center, direction, color
				)

	var pillar_corners: Dictionary = {}
	for cell_value: Variant in snapshot.get("cells", []):
		if not (cell_value is Dictionary):
			continue
		var cell: Dictionary = cell_value
		if not bool(cell.get("pillar", false)) or not _is_open_cell(cell):
			continue
		var offset: Vector2i = cell.get("offset", Vector2i.ZERO)
		var fade := _distance_fade(offset)
		var color := Color(fade, fade, fade, 1.0)
		var center := Vector3(float(offset.x), 0.0, float(offset.y))
		for corner: Vector2i in [
			Vector2i(-1, -1),
			Vector2i(1, -1),
			Vector2i(1, 1),
			Vector2i(-1, 1),
		]:
			var corner_key := offset * 2 + corner
			if pillar_corners.has(corner_key):
				continue
			pillar_corners[corner_key] = true
			triangle_count += _add_corner_pillar(
				surface,
				center + Vector3(float(corner.x), 0.0, float(corner.y)) * 0.44,
				color
			)

	surface.index()
	var mesh := surface.commit()
	return {
		"mesh": mesh,
		"triangles": triangle_count,
		"surfaces": 1 if mesh != null else 0,
		"buildUsec": Time.get_ticks_usec() - started_usec,
	}


static func _is_open_cell(cell_value: Variant) -> bool:
	if not (cell_value is Dictionary):
		return false
	var field := int((cell_value as Dictionary).get("unsignedField", 0))
	return (
		(field & ViewModelScript.FIELD_WALL) == 0
		or (field & ViewModelScript.FIELD_DOOR_NORTH_SOUTH) != 0
		or (field & ViewModelScript.FIELD_DOOR_EAST_WEST) != 0
		or (field & ViewModelScript.FIELD_STAIR) != 0
		or (field & ViewModelScript.FIELD_REVEALED_ARCH) != 0
	)


static func _create_material(atlas: Texture2D) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
uniform sampler2D atlas : source_color, filter_nearest, repeat_disable;
void fragment() {
	vec4 texel = texture(atlas, UV);
	vec3 stepped = texel.rgb * COLOR.rgb;
	ALBEDO = floor(stepped * 15.0 + 0.5) / 15.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("atlas", atlas)
	return material


static func _material_for_atlas(atlas: Texture2D) -> ShaderMaterial:
	var atlas_id := atlas.get_instance_id()
	if _shared_material == null or _shared_atlas_id != atlas_id:
		_shared_material = _create_material(atlas)
		_shared_atlas_id = atlas_id
	return _shared_material


static func _add_floor_and_ceiling(
	surface: SurfaceTool,
	center: Vector3,
	color: Color
) -> int:
	var count := _add_quad(
		surface,
		center + Vector3(-0.5, 0.0, -0.5),
		center + Vector3(-0.5, 0.0, 0.5),
		center + Vector3(0.5, 0.0, 0.5),
		center + Vector3(0.5, 0.0, -0.5),
		FLOOR_UV,
		color
	)
	count += _add_quad(
		surface,
		center + Vector3(-0.5, ROOM_HEIGHT, 0.5),
		center + Vector3(-0.5, ROOM_HEIGHT, -0.5),
		center + Vector3(0.5, ROOM_HEIGHT, -0.5),
		center + Vector3(0.5, ROOM_HEIGHT, 0.5),
		CEILING_UV,
		color
	)
	return count


static func _add_wall_boundary(
	surface: SurfaceTool,
	center: Vector3,
	direction: Vector2i,
	color: Color
) -> int:
	if direction == Vector2i.UP:
		return _add_quad(
			surface,
			center + Vector3(-0.5, 0.0, -0.5),
			center + Vector3(0.5, 0.0, -0.5),
			center + Vector3(0.5, ROOM_HEIGHT, -0.5),
			center + Vector3(-0.5, ROOM_HEIGHT, -0.5),
			WALL_UV,
			color
		)
	if direction == Vector2i.DOWN:
		return _add_quad(
			surface,
			center + Vector3(0.5, 0.0, 0.5),
			center + Vector3(-0.5, 0.0, 0.5),
			center + Vector3(-0.5, ROOM_HEIGHT, 0.5),
			center + Vector3(0.5, ROOM_HEIGHT, 0.5),
			WALL_UV,
			color
		)
	if direction == Vector2i.LEFT:
		return _add_quad(
			surface,
			center + Vector3(-0.5, 0.0, 0.5),
			center + Vector3(-0.5, 0.0, -0.5),
			center + Vector3(-0.5, ROOM_HEIGHT, -0.5),
			center + Vector3(-0.5, ROOM_HEIGHT, 0.5),
			WALL_UV,
			color
		)
	return _add_quad(
		surface,
		center + Vector3(0.5, 0.0, -0.5),
		center + Vector3(0.5, 0.0, 0.5),
		center + Vector3(0.5, ROOM_HEIGHT, 0.5),
		center + Vector3(0.5, ROOM_HEIGHT, -0.5),
		WALL_UV,
		color
	)


static func _add_corner_pillar(
	surface: SurfaceTool,
	corner_position: Vector3,
	color: Color
) -> int:
	var shaft_size := Vector3(0.10, ROOM_HEIGHT, 0.10)
	var cap_size := Vector3(0.14, 0.07, 0.14)
	var count := _add_box(
		surface,
		corner_position + Vector3(0.0, ROOM_HEIGHT * 0.5, 0.0),
		shaft_size,
		PILLAR_UV,
		color
	)
	for height: float in [0.035, ROOM_HEIGHT - 0.035]:
		count += _add_box(
			surface,
			corner_position + Vector3(0.0, height, 0.0),
			cap_size,
			PILLAR_UV,
			color
		)
	return count


static func _add_door(
	surface: SurfaceTool,
	center: Vector3,
	east_west: bool,
	color: Color
) -> int:
	if east_west:
		return _add_quad(
			surface,
			center + Vector3(0.0, 0.0, -0.36),
			center + Vector3(0.0, 0.0, 0.36),
			center + Vector3(0.0, 1.23, 0.36),
			center + Vector3(0.0, 1.23, -0.36),
			DOOR_UV,
			color
		)
	return _add_quad(
		surface,
		center + Vector3(-0.36, 0.0, 0.0),
		center + Vector3(0.36, 0.0, 0.0),
		center + Vector3(0.36, 1.23, 0.0),
		center + Vector3(-0.36, 1.23, 0.0),
		DOOR_UV,
		color
	)


static func _add_doorway(
	surface: SurfaceTool,
	center: Vector3,
	east_west: bool,
	door_open: bool,
	color: Color
) -> int:
	var count := 0
	var wing_size := Vector3(0.14, ROOM_HEIGHT, 0.16)
	var wing_a := center + Vector3(-0.43, ROOM_HEIGHT * 0.5, 0.0)
	var wing_b := center + Vector3(0.43, ROOM_HEIGHT * 0.5, 0.0)
	var header_size := Vector3(0.72, ROOM_HEIGHT - 1.23, 0.16)
	if east_west:
		wing_size = Vector3(0.16, ROOM_HEIGHT, 0.14)
		wing_a = center + Vector3(0.0, ROOM_HEIGHT * 0.5, -0.43)
		wing_b = center + Vector3(0.0, ROOM_HEIGHT * 0.5, 0.43)
		header_size = Vector3(0.16, ROOM_HEIGHT - 1.23, 0.72)
	count += _add_box(surface, wing_a, wing_size, WALL_UV, color)
	count += _add_box(surface, wing_b, wing_size, WALL_UV, color)
	count += _add_box(
		surface,
		center + Vector3(0.0, (ROOM_HEIGHT + 1.23) * 0.5, 0.0),
		header_size,
		WALL_UV,
		color
	)
	if not door_open:
		count += _add_door(surface, center, east_west, color)
	return count


static func _add_arch_frames(surface: SurfaceTool, center: Vector3, color: Color) -> int:
	var count := 0
	for east_west: bool in [false, true]:
		for side: float in [-0.41, 0.41]:
			var post_center := center + Vector3(side, 0.63, 0.0)
			var post_size := Vector3(0.18, 1.26, 0.12)
			if east_west:
				post_center = center + Vector3(0.0, 0.63, side)
				post_size = Vector3(0.12, 1.26, 0.18)
			count += _add_box(surface, post_center, post_size, ARCH_UV, color)
		var lintel_size := Vector3(1.0, 0.24, 0.12)
		if east_west:
			lintel_size = Vector3(0.12, 0.24, 1.0)
		count += _add_box(
			surface,
			center + Vector3(0.0, 1.38, 0.0),
			lintel_size,
			ARCH_UV,
			color
		)
	return count


static func _add_recessed_stair(
	surface: SurfaceTool,
	center: Vector3,
	color: Color
) -> int:
	var count := _add_quad(
		surface,
		center + Vector3(-0.5, -0.28, -0.5),
		center + Vector3(-0.5, -0.28, 0.5),
		center + Vector3(0.5, -0.28, 0.5),
		center + Vector3(0.5, -0.28, -0.5),
		STAIR_UV,
		color
	)
	count += _add_quad(
		surface,
		center + Vector3(-0.5, ROOM_HEIGHT, 0.5),
		center + Vector3(-0.5, ROOM_HEIGHT, -0.5),
		center + Vector3(0.5, ROOM_HEIGHT, -0.5),
		center + Vector3(0.5, ROOM_HEIGHT, 0.5),
		CEILING_UV,
		color
	)
	for direction: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		var tangent := Vector3(1.0, 0.0, 0.0) if direction.x == 0.0 \
			else Vector3(0.0, 0.0, 1.0)
		var wall_center := center + Vector3(direction.x, 0.0, direction.y) * 0.5
		count += _add_quad(
			surface,
			wall_center - tangent * 0.5 + Vector3(0.0, -0.28, 0.0),
			wall_center + tangent * 0.5 + Vector3(0.0, -0.28, 0.0),
			wall_center + tangent * 0.5,
			wall_center - tangent * 0.5,
			STAIR_UV,
			color
		)
	return count


static func _add_box(
	surface: SurfaceTool,
	center: Vector3,
	size: Vector3,
	uv_rect: Rect2,
	color: Color
) -> int:
	var half := size * 0.5
	var x0 := center.x - half.x
	var x1 := center.x + half.x
	var y0 := center.y - half.y
	var y1 := center.y + half.y
	var z0 := center.z - half.z
	var z1 := center.z + half.z
	var count := 0
	count += _add_quad(surface, Vector3(x0, y0, z0), Vector3(x1, y0, z0), Vector3(x1, y1, z0), Vector3(x0, y1, z0), uv_rect, color)
	count += _add_quad(surface, Vector3(x1, y0, z1), Vector3(x0, y0, z1), Vector3(x0, y1, z1), Vector3(x1, y1, z1), uv_rect, color)
	count += _add_quad(surface, Vector3(x0, y0, z1), Vector3(x0, y0, z0), Vector3(x0, y1, z0), Vector3(x0, y1, z1), uv_rect, color)
	count += _add_quad(surface, Vector3(x1, y0, z0), Vector3(x1, y0, z1), Vector3(x1, y1, z1), Vector3(x1, y1, z0), uv_rect, color)
	count += _add_quad(surface, Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x0, y1, z1), uv_rect, color)
	count += _add_quad(surface, Vector3(x0, y0, z1), Vector3(x1, y0, z1), Vector3(x1, y0, z0), Vector3(x0, y0, z0), uv_rect, color)
	return count


static func _add_quad(
	surface: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	uv_rect: Rect2,
	color: Color
) -> int:
	var u0 := uv_rect.position.x / ATLAS_SIZE.x
	var v0 := uv_rect.position.y / ATLAS_SIZE.y
	var u1 := uv_rect.end.x / ATLAS_SIZE.x
	var v1 := uv_rect.end.y / ATLAS_SIZE.y
	var vertices := [a, b, c, a, c, d]
	var uvs := [
		Vector2(u0, v1), Vector2(u1, v1), Vector2(u1, v0),
		Vector2(u0, v1), Vector2(u1, v0), Vector2(u0, v0),
	]
	for index: int in range(vertices.size()):
		surface.set_color(color)
		surface.set_uv(uvs[index])
		surface.add_vertex(vertices[index])
	return 2


static func _distance_fade(offset: Vector2i) -> float:
	var distance := maxi(absi(offset.x), absi(offset.y))
	match distance:
		0, 1:
			return 1.0
		2:
			return 0.78
		3:
			return 0.55
		4:
			return 0.34
		5:
			return 0.20
		_:
			return 0.10
