extends Node

var _assertions := 0
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var resources: CampaignResources = $Resources
	if not UI.main_menu.initial_profile_ready:
		await UI.main_menu.initial_profile_loaded

	await resources.load_tile_resources_async("res://shared_assets/tiles/")
	_expect(not resources.tiles_book.is_empty(), "shared tiles load asynchronously")
	_expect(
		await resources.ensure_shared_item_catalog_loaded_async(),
		"shared item catalog loads asynchronously",
	)
	_expect(not resources.items_book.is_empty(), "shared item images are materialized")
	await resources.load_sound_resources_async("res://shared_assets/sounds/")
	_expect(not resources.sounds_book.is_empty(), "shared sounds remain available")
	await resources.load_bestiary_resources_async("res://shared_assets/Bestiary/")
	_expect(not resources.crea_book.is_empty(), "shared bestiary loads asynchronously")

	var city_map_path := "res://Campaigns/City of Bywater/Maps/map_0/"
	_expect(
		await resources.load_map_resources_async(city_map_path, "map_0"),
		"the City start map loads asynchronously",
	)
	_expect(resources.maps_book.has("map_0"), "the City start map is registered")

	if _failures.is_empty():
		print(
			"ASYNC_RESOURCE_LOADING PASS: %d assertions; " % _assertions,
			"threaded images, sounds, bestiary data, and maps are available.",
		)
		get_tree().quit(0)
		return
	printerr("ASYNC_RESOURCE_LOADING FAIL: %s" % "; ".join(_failures))
	get_tree().quit(1)


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(message)
