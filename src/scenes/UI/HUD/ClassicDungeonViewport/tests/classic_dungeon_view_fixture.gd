extends Control

@onready var dungeon_view: ClassicDungeonViewport = $ClassicDungeonViewport


func _ready() -> void:
	StateMachine._state_name = "Exploration"
	await get_tree().process_frame
	if UI.main_menu != null:
		UI.main_menu.hide()
	# Keep this visual fixture isolated from the asynchronously loading main-menu
	# autoloads, which may otherwise replace its deliberately synthetic snapshot.
	if GameGlobal.classic_dungeon_view_changed.is_connected(
		dungeon_view._on_snapshot_changed
	):
		GameGlobal.classic_dungeon_view_changed.disconnect(
			dungeon_view._on_snapshot_changed
		)
	if StateMachine.state_changed.is_connected(dungeon_view._on_game_state_changed):
		StateMachine.state_changed.disconnect(dungeon_view._on_game_state_changed)
	var cells: Array[Dictionary] = []
	for y: int in range(-6, 7):
		for x: int in range(-6, 7):
			var field := 0
			if absi(x) >= 2 or y == -6 or y == 6:
				field = 0x0001
			# A door belongs in a wall run. Keeping its neighboring squares open
			# makes a valid one-square door look like a freestanding prop.
			if y == -2 and absi(x) == 1:
				field = 0x0001
			if Vector2i(x, y) == Vector2i(0, -2):
				field = 0x0002
			elif Vector2i(x, y) == Vector2i(-1, -3):
				field = 0x2001
			elif Vector2i(x, y) == Vector2i(1, -4):
				field = 0x0008
			elif Vector2i(x, y) == Vector2i(1, -3):
				field = 0x0010
			cells.append({
				"position": Vector2i(x, y),
				"offset": Vector2i(x, y),
				"inBounds": true,
				"field": field,
				"unsignedField": field,
				"pillar": (field & 0x0010) != 0,
			})
	dungeon_view._on_snapshot_changed({
		"status": "ok",
		"active": true,
		"levelType": "dungeon",
		"levelIndex": 0,
		"origin": Vector2i.ZERO,
		"heading": 1,
		"multiView": true,
		"viewType": 1,
		"compassEnabled": false,
		"mapBounds": Rect2i(-6, -6, 13, 13),
		"width": 13,
		"height": 13,
		"radius": 6,
		"cells": cells,
	})
