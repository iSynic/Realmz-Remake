extends Node

const PreparationCoordinatorScript = preload(
	"res://scripts/classic_runtime/classic_campaign_preparation_coordinator.gd"
)

const CITY := "City of Bywater (Classic)"
const WAR := "War in the Sword Lands (Classic)"

var _assertions := 0
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var resources: CampaignResources = $Resources
	if not UI.main_menu.initial_profile_ready:
		await UI.main_menu.initial_profile_loaded
	var coordinator: ClassicCampaignPreparationCoordinator = (
		PreparationCoordinatorScript.new()
	)
	add_child(coordinator)

	var city_install := await _prepare(coordinator, CITY)
	if city_install != null:
		UI.begin_loading("Testing City resources")
		_expect(
			await resources.activate_campaign_resources_async(CITY),
			"City campaign resources activate",
		)
		UI.end_loading()
		_expect_equal(
			resources.item_catalog.active_campaign_id(),
			"scenario-city-of-bywater",
			"City owns the active campaign item view",
		)
		_expect_equal(
			resources.item_catalog.resolve_active_catalog_key("Classic Item 807"),
			"classic:scenario-city-of-bywater:807",
			"City exposes its campaign-local item 807 definition",
		)

	var war_install := await _prepare(coordinator, WAR)
	if war_install != null:
		UI.begin_loading("Testing War resources")
		_expect(
			await resources.activate_campaign_resources_async(WAR),
			"War campaign resources activate",
		)
		UI.end_loading()
		_expect_equal(
			resources.item_catalog.active_campaign_id(),
			"scenario-war-in-the-sword-lands",
			"War replaces the active campaign item view",
		)
		_expect(
			not str(
				resources.item_catalog.resolve_active_catalog_key("Classic Item 807")
			).begins_with("classic:scenario-city-of-bywater:"),
			"City's campaign-local item does not bleed into War",
		)

	if city_install != null:
		UI.begin_loading("Testing City resource reuse")
		_expect(
			await resources.activate_campaign_resources_async(CITY),
			"City campaign resources reactivate after War",
		)
		UI.end_loading()
		_expect_equal(
			resources.item_catalog.active_campaign_id(),
			"scenario-city-of-bywater",
			"City regains its active campaign item view",
		)

	resources.deactivate_campaign_resources()
	_expect_equal(
		resources.item_catalog.active_campaign_id(),
		"",
		"returning to the menu leaves only shared item definitions active",
	)
	_finish()


func _prepare(
	coordinator: ClassicCampaignPreparationCoordinator,
	campaign_name: String,
) -> Object:
	var preview: Dictionary = GameGlobal.get_campaign_selection_preview(campaign_name)
	var generation := coordinator.request(campaign_name, preview)
	var response: Array = await coordinator.preparation_finished
	var success := (
		int(response[0]) == generation
		and str(response[1]) == campaign_name
		and bool(response[2])
	)
	_expect(success, "%s prepares successfully" % campaign_name)
	if not success:
		return null
	var install: Object = response[3]
	GameGlobal.classic_campaign_install_cache[campaign_name] = install
	return install


func _expect(condition: bool, message: String) -> void:
	_assertions += 1
	if not condition:
		_failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s (expected %s, got %s)" % [
		message,
		str(expected),
		str(actual),
	])


func _finish() -> void:
	if _failures.is_empty():
		print(
			"CAMPAIGN_RESOURCE_ISOLATION PASS: %d assertions; " % _assertions,
			"City, War, and shared resources remain isolated.",
		)
		get_tree().quit(0)
		return
	printerr("CAMPAIGN_RESOURCE_ISOLATION FAIL: %s" % "; ".join(_failures))
	get_tree().quit(1)
