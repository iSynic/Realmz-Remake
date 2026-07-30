class_name ScenarioCampaignBundle
extends RefCounted

const ClassicBundleScript = preload(
	"res://scripts/classic_runtime/classic_campaign_bundle.gd"
)

const FORMAT := "realmz-remake-scenario"
const FORMAT_VERSION := 3
const CAMPAIGN_KINDS := [
	"classic-interpreted",
	"classic-enhanced",
	"remake-authored",
]

var implementation: Object
var manifest: Dictionary = {}
var documents: Dictionary = {}
var last_error := ""


func load_from_directory(directory: String) -> bool:
	_reset()
	var manifest_path := directory.path_join("campaign.json")
	if not FileAccess.file_exists(manifest_path):
		return _fail("campaign.json is missing")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not (parsed is Dictionary):
		return _fail("campaign.json must contain a JSON object")
	var candidate: Dictionary = parsed
	if str(candidate.get("format", "")) != FORMAT \
			or int(candidate.get("formatVersion", 0)) != FORMAT_VERSION:
		return _fail("Unsupported pre-release scenario package; re-export it from Providence")
	var campaign_kind := str(candidate.get("campaignKind", ""))
	if campaign_kind not in CAMPAIGN_KINDS:
		return _fail("Unsupported scenario campaign kind '%s'" % campaign_kind)
	if campaign_kind == "remake-authored":
		return _fail(
			"Remake Authored campaign contracts are recognized, but their semantic "
			+ "trigger session is not available in this delivery slice"
		)
	implementation = ClassicBundleScript.new()
	if not implementation.load_from_directory(directory):
		return _fail(str(implementation.last_error))
	manifest = implementation.manifest
	documents = implementation.documents
	return true


func package_hash() -> String:
	return implementation.package_hash() if implementation != null else ""


func _reset() -> void:
	implementation = null
	manifest.clear()
	documents.clear()
	last_error = ""


func _fail(message: String) -> bool:
	last_error = message
	return false
