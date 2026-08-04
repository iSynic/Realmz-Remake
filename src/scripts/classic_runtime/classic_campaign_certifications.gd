class_name ClassicCampaignCertifications
extends RefCounted

# These package hashes are produced by Providence and certified by Remake's
# checked Classic corpus run. They avoid repeating a semantic audit in the
# player's selection path; live package integrity is still verified first.
const SCHEMA_VERSION := 1
const READINESS_SCHEMA_VERSION := 1
const CERTIFIED_FALLBACKS := {
	"9ea5030bd41971cb4e3938f71eebe7ddd30f496d1df774c8c4d0c1a24f63f581": 84,
	"1f681ffcc7c90de8c5102e776b46d4f013f2a1cb23b7393c577d2a9c00928157": 75,
	"70fd28800e3c5ecf47ab79e67c05c3027cc2dbf1b4fe99b5b3cf64303bb81847": 19,
	"8a0b0746988e5f487eec1dcc50808fcb9e078a0af5e8cf144ab76b143ba29782": 128,
	"1a4f72554973cf6ee48ba9cde129572fee753bd5e8fc79da42bcb6e185cb8088": 103,
	"901889af5352de2b00a0d258dea2b983b3064d7130e0f1c49cf4dd6370e637c0": 184,
	"f5fc6c7cb096ca6e8c32887b268789f3174f62ea5b44fdf2ba8b68ec50fdec44": 320,
	"d489e9b4cfe61af666d41dd591cfc53e6ba949bc50f48e6955a7a3c9a1da81c4": 45,
	"71e4c65180614f61aab1d00f1ff1ca852ec1cbd1e41bb2b38d5a895742dbd0d6": 296,
	"7e3231bbfe293b8e6e20e310ba2e3841631a6aacb016fc7c1599895ac0de7a7f": 50,
	"988b1efe90030921b37ba6fa3b2e3e4a0ea3bef72b888e609e3f6763f2ae6d59": 576,
	"48e73dbc958aa4964d0bbbdca7cb087809692eed7a1b1f7cb464eea2970a9ee8": 162,
	"3104df3cdddd85956cb0ec89b066bcc91d19f90f2f1ee3f9c47297ace2e7fb26": 428,
}


static func readiness_for_package(
	package_hash: String,
	campaign_id: String,
	campaign_name: String
) -> Dictionary:
	var normalized_hash := package_hash.to_lower()
	if not CERTIFIED_FALLBACKS.has(normalized_hash):
		return {}
	var fallback_count := int(CERTIFIED_FALLBACKS[normalized_hash])
	return {
		"schemaVersion": READINESS_SCHEMA_VERSION,
		"campaign": {
			"id": campaign_id,
			"name": campaign_name,
		},
		"ready": true,
		"status": "ready",
		"summary": "Ready: no progression blockers; %d fidelity fallback%s." % [
			fallback_count,
			"" if fallback_count == 1 else "s",
		],
		"totals": {
			"progressionBlockers": 0,
			"fidelityFallbacks": fallback_count,
			"diagnostics": fallback_count,
		},
		# Detailed diagnostics remain the responsibility of the corpus audit.
		"diagnostics": [],
		"execution": {},
		"certification": {
			"schemaVersion": SCHEMA_VERSION,
			"packageHash": normalized_hash,
			"source": "checked-classic-corpus",
		},
	}
