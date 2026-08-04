class_name ClassicCampaignPreparationCoordinator
extends Node

const CampaignInstallScript = preload(
	"res://scripts/classic_runtime/classic_campaign_install.gd"
)
const CertificationsScript = preload(
	"res://scripts/classic_runtime/classic_campaign_certifications.gd"
)

const CACHE_SCHEMA_VERSION := 1
const CACHE_DIRECTORY := "user://cache/classic_campaign_preparation/v1"

signal advisory_ready(generation: int, campaign_name: String, selection: Dictionary)
signal preparation_finished(
	generation: int,
	campaign_name: String,
	success: bool,
	install: Object,
	selection: Dictionary,
	cache_status: String,
	error: String
)

var _generation := 0
var _thread: Thread
var _running_request: Dictionary = {}
var _latest_request: Dictionary = {}
var _validated_by_hash: Dictionary = {}


func _ready() -> void:
	set_process(true)


func request(campaign_name: String, preview: Dictionary) -> int:
	_generation += 1
	var generation := _generation
	_latest_request.clear()
	var package_hash := str(preview.get("packageHash", "")).to_lower()
	var validated: Variant = _validated_by_hash.get(package_hash)
	if validated is Dictionary:
		call_deferred(
			"_emit_memory_result",
			generation,
			campaign_name,
			validated
		)
		return generation
	var cached := _read_cache(package_hash)
	if not cached.is_empty():
		call_deferred(
			"_emit_advisory",
			generation,
			campaign_name,
			cached.get("selection", {}).duplicate(true)
		)
	_latest_request = {
		"generation": generation,
		"campaign": campaign_name,
		"campaignsDirectory": Paths.campaignsfolderpath,
		"preview": preview.duplicate(true),
		"cached": cached,
	}
	if _thread == null:
		_start_latest_request()
	return generation


func _emit_memory_result(
	generation: int,
	campaign_name: String,
	validated: Dictionary
) -> void:
	if generation != _generation:
		return
	preparation_finished.emit(
		generation,
		campaign_name,
		true,
		validated.get("install"),
		validated.get("selection", {}).duplicate(true),
		"memory",
		""
	)


func _emit_advisory(
	generation: int,
	campaign_name: String,
	selection: Dictionary
) -> void:
	if generation != _generation:
		return
	advisory_ready.emit(generation, campaign_name, selection)


func invalidate() -> void:
	_generation += 1
	_latest_request.clear()


func _process(_delta: float) -> void:
	if _thread == null or _thread.is_alive():
		return
	var result: Variant = _thread.wait_to_finish()
	_thread = null
	var completed := _running_request
	_running_request = {}
	_finalize_result(completed, result if result is Dictionary else {})
	if not _latest_request.is_empty():
		_start_latest_request()


func _start_latest_request() -> void:
	if _latest_request.is_empty() or _thread != null:
		return
	_running_request = _latest_request
	_latest_request = {}
	_thread = Thread.new()
	var error := _thread.start(
		_run_worker.bind(_running_request.duplicate(true)),
		Thread.PRIORITY_LOW
	)
	if error != OK:
		var failed := _running_request
		_running_request = {}
		_thread = null
		preparation_finished.emit(
			int(failed.get("generation", 0)),
			str(failed.get("campaign", "")),
			false,
			null,
			{},
			"miss",
			"Campaign preparation worker could not start: %s" % error_string(error)
		)


func _run_worker(request_data: Dictionary) -> Dictionary:
	var install = CampaignInstallScript.new()
	var loaded := install.load_worker_phase_from_campaigns_directory(
		str(request_data.get("campaignsDirectory", "")),
		str(request_data.get("campaign", "")),
		true,
		true
	)
	return {
		"loaded": loaded,
		"install": install,
		"error": install.last_error,
	}


func _finalize_result(request_data: Dictionary, worker_result: Dictionary) -> void:
	var generation := int(request_data.get("generation", 0))
	var campaign_name := str(request_data.get("campaign", ""))
	var install: ClassicCampaignInstall = (
		worker_result.get("install") as ClassicCampaignInstall
	)
	var loaded := bool(worker_result.get("loaded", false)) and install != null
	var selection: Dictionary = {}
	var cache_status := "miss"
	var error := str(worker_result.get("error", ""))
	if generation != _generation:
		preparation_finished.emit(
			generation,
			campaign_name,
			false,
			install,
			{},
			"stale",
			"Selection was replaced"
		)
		return
	if loaded:
		var finalize_trace := LoadPerformanceTrace.begin_phase(
			&"campaign.prepare.finalize",
			{"campaign": campaign_name}
		)
		var package_hash := str(install.bundle.package_hash()).to_lower()
		var readiness := CertificationsScript.readiness_for_package(
			package_hash,
			str(install.bundle.manifest.get("id", "")),
			str(install.bundle.manifest.get("name", campaign_name))
		)
		if not readiness.is_empty():
			cache_status = "certified"
		else:
			var cached: Dictionary = request_data.get("cached", {})
			if str(cached.get("packageHash", "")).to_lower() == package_hash:
				readiness = cached.get("readiness", {}).duplicate(true)
				cache_status = "hit"
		loaded = install.finalize_worker_preparation(readiness)
		error = install.last_error
		selection = install.selection_rules()
		LoadPerformanceTrace.end_phase(finalize_trace, loaded, {
			"campaign": campaign_name,
			"cache_status": cache_status,
		})
		if loaded and generation == _generation:
			_validated_by_hash[package_hash] = {
				"install": install,
				"selection": selection.duplicate(true),
			}
			_write_cache(package_hash, selection, install.readiness_report)
	call_deferred("_emit_finished", {
		"generation": generation,
		"campaign": campaign_name,
		"success": loaded and bool(selection.get("valid", false)),
		"install": install,
		"selection": selection,
		"cacheStatus": cache_status,
		"error": error,
	})


func _emit_finished(payload: Dictionary) -> void:
	preparation_finished.emit(
		int(payload.get("generation", 0)),
		str(payload.get("campaign", "")),
		bool(payload.get("success", false)),
		payload.get("install"),
		payload.get("selection", {}),
		str(payload.get("cacheStatus", "miss")),
		str(payload.get("error", ""))
	)


func _read_cache(package_hash: String) -> Dictionary:
	if package_hash.length() != 64:
		return {}
	var path := _cache_path(package_hash)
	if not FileAccess.file_exists(path):
		return {}
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (value is Dictionary):
		return {}
	if (
		int(value.get("schemaVersion", 0)) != CACHE_SCHEMA_VERSION
		or int(value.get("readinessSchemaVersion", 0))
			!= CertificationsScript.READINESS_SCHEMA_VERSION
		or str(value.get("packageHash", "")).to_lower() != package_hash
		or not (value.get("selection") is Dictionary)
		or not (value.get("readiness") is Dictionary)
	):
		return {}
	return value


func _write_cache(
	package_hash: String,
	selection: Dictionary,
	readiness: Dictionary
) -> void:
	if package_hash.length() != 64:
		return
	var absolute_directory := ProjectSettings.globalize_path(CACHE_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return
	var file := FileAccess.open(_cache_path(package_hash), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion": CACHE_SCHEMA_VERSION,
		"readinessSchemaVersion": CertificationsScript.READINESS_SCHEMA_VERSION,
		"packageHash": package_hash,
		"selection": selection,
		"readiness": readiness,
	}))
	file.close()


func _cache_path(package_hash: String) -> String:
	return CACHE_DIRECTORY.path_join("%s.json" % package_hash)


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
