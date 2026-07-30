class_name ScenarioCampaignSession
extends ClassicCampaignSession

# This is the campaign-agnostic session boundary. Classic and Classic Enhanced
# currently share the proven ClassicCampaignSession implementation; Remake
# Authored will enter through this class when its semantic trigger loader lands.
const SUPPORTED_CLASSIC_KINDS := [
	"classic-interpreted",
	"classic-enhanced",
]


func load_installed_campaign(
	campaigns_directory: String,
	campaign_name: String,
	command_adapter: Object,
	prepared_install: Object = null,
	gameplay_rule_selection := {}
) -> Dictionary:
	var result := super.load_installed_campaign(
		campaigns_directory,
		campaign_name,
		command_adapter,
		prepared_install,
		gameplay_rule_selection
	)
	if str(result.get("status", "")) != "ok":
		return result
	var loaded_kind := _campaign_kind()
	if loaded_kind not in SUPPORTED_CLASSIC_KINDS:
		clear()
		return {
			"status": "error",
			"message": "Campaign kind '%s' has no registered session implementation" % loaded_kind,
		}
	result["campaignKind"] = loaded_kind
	result["implementationKind"] = IMPLEMENTATION_KIND
	return result
