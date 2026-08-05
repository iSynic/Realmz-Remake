class_name ClassicDungeonViewModel
extends RefCounted

const FIELD_WALL := 0x0001
const FIELD_DOOR_NORTH_SOUTH := 0x0002
const FIELD_DOOR_EAST_WEST := 0x0004
const FIELD_STAIR := 0x0008
const FIELD_PILLAR := 0x0010
const FIELD_REVEALED_ARCH := 0x2000

const SURFACE_NONE := 0
const SURFACE_WALL := 1
const SURFACE_STAIR := 2
const SURFACE_ARCH := 3
const SURFACE_DOOR := 4

const HEADING_NORTH := 1
const HEADING_EAST := 2
const HEADING_SOUTH := 3
const HEADING_WEST := 4
const VIEW_MAP := -1
const VIEW_3D := 1


static func build_snapshot(bundle: Object, state: Object, radius: int = 6) -> Dictionary:
	if bundle == null or state == null:
		return _error("Classic dungeon view requires a campaign bundle and runtime state")
	if str(state.get("level_type")) != "dungeon":
		return {"status": "ok", "active": false}

	var level_index := int(state.get("level_index"))
	var map_record: Variant = bundle.call("get_map", "dungeon:%d" % level_index)
	if not (map_record is Dictionary) or map_record.is_empty():
		return _error("Classic dungeon level %d is unavailable" % level_index)
	var width := int(map_record.get("width", 0))
	var height := int(map_record.get("height", 0))
	var tiles: Variant = map_record.get("tiles", [])
	if width <= 0 or height <= 0 or not (tiles is Array):
		return _error("Classic dungeon level %d has invalid geometry" % level_index)
	if tiles.size() != width * height:
		return _error(
			"Classic dungeon level %d has %d fields, expected %d"
			% [level_index, tiles.size(), width * height]
		)

	var clamped_radius := clampi(radius, 1, 16)
	var origin := Vector2i(int(state.get("x")), int(state.get("y")))
	var heading := normalize_heading(int(state.get("heading")))
	var cells: Array[Dictionary] = []
	for map_y: int in range(origin.y - clamped_radius, origin.y + clamped_radius + 1):
		for map_x: int in range(origin.x - clamped_radius, origin.x + clamped_radius + 1):
			var in_bounds := map_x >= 0 and map_y >= 0 and map_x < width and map_y < height
			var field := FIELD_WALL
			if in_bounds:
				# Providence preserves dungeon fields in the row-major order used by Realmz.
				var fallback_field := int(tiles[map_y * width + map_x])
				field = int(state.call(
					"get_tile",
					"dungeon",
					level_index,
					map_x,
					map_y,
					fallback_field
				))
			var unsigned_field := field & 0xffff
			cells.append({
				"position": Vector2i(map_x, map_y),
				"offset": Vector2i(map_x - origin.x, map_y - origin.y),
				"inBounds": in_bounds,
				"field": field,
				"unsignedField": unsigned_field,
				"frontSurface": front_surface(unsigned_field, heading),
				"sideSurface": side_surface(unsigned_field, heading),
				"pillar": (unsigned_field & FIELD_PILLAR) != 0,
			})

	return {
		"status": "ok",
		"active": true,
		"levelType": "dungeon",
		"levelIndex": level_index,
		"origin": origin,
		"heading": heading,
		"multiView": bool(state.get("multi_view")),
		"viewType": int(state.get("view_type")),
		"compassEnabled": bool(state.get("compass_enabled")),
		"mapBounds": Rect2i(0, 0, width, height),
		"width": width,
		"height": height,
		"radius": clamped_radius,
		"cells": cells,
	}


static func normalize_heading(heading: int) -> int:
	if heading >= HEADING_NORTH and heading <= HEADING_WEST:
		return heading
	return HEADING_NORTH


static func rotated_heading(heading: int, delta: int) -> int:
	return posmod(normalize_heading(heading) - 1 + delta, 4) + 1


static func heading_vector(heading: int) -> Vector2i:
	match normalize_heading(heading):
		HEADING_EAST:
			return Vector2i.RIGHT
		HEADING_SOUTH:
			return Vector2i.DOWN
		HEADING_WEST:
			return Vector2i.LEFT
		_:
			return Vector2i.UP


static func front_surface(field: int, heading: int) -> int:
	var unsigned_field := field & 0xffff
	var result := SURFACE_WALL if (unsigned_field & FIELD_WALL) != 0 else SURFACE_NONE
	var door_mask := FIELD_DOOR_NORTH_SOUTH
	if normalize_heading(heading) in [HEADING_EAST, HEADING_WEST]:
		door_mask = FIELD_DOOR_EAST_WEST
	if (unsigned_field & door_mask) != 0:
		result = SURFACE_DOOR
	if (unsigned_field & FIELD_REVEALED_ARCH) != 0:
		result = SURFACE_ARCH
	if (unsigned_field & FIELD_STAIR) != 0:
		result = SURFACE_STAIR
	return result


static func side_surface(field: int, heading: int) -> int:
	var unsigned_field := field & 0xffff
	var result := SURFACE_WALL if (unsigned_field & FIELD_WALL) != 0 else SURFACE_NONE
	var door_mask := FIELD_DOOR_EAST_WEST
	if normalize_heading(heading) in [HEADING_EAST, HEADING_WEST]:
		door_mask = FIELD_DOOR_NORTH_SOUTH
	if (unsigned_field & door_mask) != 0:
		result = SURFACE_ARCH
	if (unsigned_field & (FIELD_REVEALED_ARCH | FIELD_STAIR)) != 0:
		result = SURFACE_STAIR
	return result


static func _error(message: String) -> Dictionary:
	return {"status": "error", "active": false, "message": message}
