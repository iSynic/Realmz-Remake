class_name ScenarioCampaignInstall
extends RefCounted

const BundleScript = preload(
	"res://scripts/scenario_runtime/scenario_campaign_bundle.gd"
)
const ClassicInstallScript = preload(
	"res://scripts/classic_runtime/classic_campaign_install.gd"
)
const AdmissionScript = preload(
	"res://scripts/classic_runtime/classic_campaign_admission.gd"
)
const MapMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_map_materializer.gd"
)
const ItemMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_item_materializer.gd"
)
const BestiaryMaterializerScript = preload(
	"res://scripts/classic_runtime/classic_bestiary_materializer.gd"
)

var implementation: Object
var campaign_name := ""
var campaign_directory := ""
var bundle: Object
var last_error := ""


static func has_manifest(campaigns_directory: String, candidate_name: String) -> bool:
	return ClassicInstallScript.has_manifest(campaigns_directory, candidate_name)


static func is_safe_campaign_name(candidate_name: String) -> bool:
	return ClassicInstallScript.is_safe_campaign_name(candidate_name)


static func preview_from_campaigns_directory(
	campaigns_directory: String,
	candidate_name: String
) -> Dictionary:
	var manifest_path := campaigns_directory.path_join(
		candidate_name
	).path_join("campaign.json")
	var manifest := _read_json(manifest_path)
	if str(manifest.get("campaignKind", "")) != "remake-authored":
		return ClassicInstallScript.preview_from_campaigns_directory(
			campaigns_directory,
			candidate_name
		)
	var result := _authored_rules(manifest, {})
	result["preview"] = true
	result["valid"] = false
	result["readinessState"] = "Select to check"
	result["readinessSummary"] = "Remake Authored package; select it to validate."
	return result


func load_from_campaigns_directory(
	campaigns_directory: String,
	candidate_name: String,
	allow_materialized_runtime := true
) -> bool:
	_reset()
	if not is_safe_campaign_name(candidate_name):
		return _fail("Scenario campaign name is invalid")
	campaign_name = candidate_name
	campaign_directory = campaigns_directory.replace("\\", "/").trim_suffix(
		"/"
	).path_join(candidate_name)
	var manifest := _read_json(campaign_directory.path_join("campaign.json"))
	if manifest.is_empty():
		return _fail("Installed scenario campaign is missing campaign.json")
	if str(manifest.get("campaignKind", "")) != "remake-authored":
		implementation = ClassicInstallScript.new()
		if not implementation.load_from_campaigns_directory(
			campaigns_directory,
			candidate_name,
			allow_materialized_runtime
		):
			return _fail(str(implementation.last_error))
		bundle = implementation.bundle
		campaign_directory = str(implementation.campaign_directory)
		return true
	bundle = BundleScript.new()
	if not bundle.load_from_directory(campaign_directory):
		return _fail(bundle.last_error)
	if allow_materialized_runtime:
		for materializer: Object in [
			MapMaterializerScript.new(),
			ItemMaterializerScript.new(),
			BestiaryMaterializerScript.new(),
		]:
			var result: Dictionary = materializer.materialize(
				bundle,
				campaign_directory
			)
			if str(result.get("status", "")) != "ok":
				return _fail(str(result.get(
					"message",
					"Remake Authored runtime assets could not be generated"
				)))
	return true


func selection_rules() -> Dictionary:
	if implementation != null:
		return implementation.selection_rules()
	if bundle == null:
		return {
			"valid": false,
			"diagnostic": last_error,
			"readinessState": "Invalid",
		}
	return _authored_rules(
		bundle.manifest,
		bundle.documents.get("rules", {})
	)


static func _authored_rules(manifest: Dictionary, rules_document: Dictionary) -> Dictionary:
	var title := str(manifest.get("name", "Remake Authored Scenario")).strip_edges()
	var rules := {
		"title": title,
		"description": str(manifest.get(
			"description",
			"%s (Remake Authored scenario)" % title
		)),
		"restrictionsDescription": "Up to %d characters." % AdmissionScript.NATIVE_PARTY_LIMIT,
		"charactersLimit": AdmissionScript.NATIVE_PARTY_LIMIT,
		"recommendedPartyLevel": 0,
		"legacyRegistrationPartyLevelLimit": 0,
		"partyLevelLimit": 0,
		"characterLevelLimit": 0,
		"bannedRaceIds": [],
		"bannedCasteIds": [],
		"raceNames": rules_document.get("ruleNames", {}).get("raceNames", []),
		"casteNames": rules_document.get("ruleNames", {}).get("casteNames", []),
		"unsupportedRaceOverrideIds": [],
		"unsupportedCasteOverrideIds": [],
		"authoredRestrictionsDescription": "",
		"classic": true,
		"remakeAuthored": true,
		"preview": false,
		"valid": true,
		"readinessState": "Ready",
		"readinessSummary": "Semantic scenario logic is ready.",
		"diagnostic": "",
		"versionLabel": "Remake Authored v3",
	}
	return rules


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _reset() -> void:
	implementation = null
	campaign_name = ""
	campaign_directory = ""
	bundle = null
	last_error = ""


func _fail(message: String) -> bool:
	last_error = message
	return false
