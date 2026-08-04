class_name ClassicFidelityFallbackAudit
extends RefCounted

const DEFAULT_CATALOG_PATH := (
	"res://scripts/classic_runtime/fidelity_fallback_catalog.json"
)
const VALID_DISPOSITIONS := [
	"Remake runtime gap",
	"producer/import gap",
	"missing Classic resource",
	"source-research need",
	"intentional compatibility choice",
	"inactive content",
]
const VALID_PRIORITIES := ["P1", "P2", "P3"]


func inspect(report: Dictionary, catalog_path := DEFAULT_CATALOG_PATH) -> Dictionary:
	var catalog_result := _load_catalog(catalog_path)
	var catalog: Dictionary = catalog_result.get("catalog", {})
	var catalog_codes: Dictionary = catalog.get("codes", {})
	var invalid_entries := _validate_catalog_entries(catalog_codes)
	var by_code: Dictionary = {}
	var by_campaign: Dictionary = {}
	var observed_codes: Dictionary = {}
	for campaign_value: Variant in report.get("campaigns", []):
		if not (campaign_value is Dictionary):
			continue
		var campaign: Dictionary = campaign_value
		var campaign_name := str(campaign.get("directory", ""))
		for diagnostic_value: Variant in (
			campaign.get("readiness", {}).get("diagnostics", [])
		):
			if not (diagnostic_value is Dictionary):
				continue
			var diagnostic: Dictionary = diagnostic_value
			var code := str(diagnostic.get("code", "unknown"))
			observed_codes[code] = true
			if str(diagnostic.get("classification", "")) != "fidelity-fallback":
				continue
			var activity := str(diagnostic.get("activity", "active"))
			var code_row: Dictionary = by_code.get(code, {
				"diagnostics": 0,
				"active": 0,
				"inactive": 0,
				"representatives": [],
			})
			_increment_activity(code_row, activity)
			var representatives: Array = code_row["representatives"]
			if representatives.size() < 3:
				representatives.append(
					_representative(campaign_name, diagnostic)
				)
			by_code[code] = code_row
			var campaign_row: Dictionary = by_campaign.get(campaign_name, {
				"diagnostics": 0,
				"active": 0,
				"inactive": 0,
			})
			_increment_activity(campaign_row, activity)
			by_campaign[campaign_name] = campaign_row

	var uncataloged_active: Array[String] = []
	var uncataloged_observed: Array[String] = []
	var by_disposition: Dictionary = {}
	var by_priority: Dictionary = {}
	var user_help_needed: Array = []
	var code_names: Array = by_code.keys()
	code_names.sort()
	for code_value: Variant in code_names:
		var code := str(code_value)
		var code_row: Dictionary = by_code[code]
		var catalog_entry: Dictionary = catalog_codes.get(code, {})
		if catalog_entry.is_empty():
			if int(code_row.get("active", 0)) > 0:
				uncataloged_active.append(code)
			continue
		code_row.merge(catalog_entry, true)
		var disposition := str(catalog_entry.get("disposition", ""))
		var priority := str(catalog_entry.get("priority", ""))
		_add_count(by_disposition, disposition, int(code_row["diagnostics"]))
		_add_count(by_priority, priority, int(code_row["diagnostics"]))
		if (
			bool(catalog_entry.get("userAssistanceNeeded", false))
			and int(code_row.get("active", 0)) > 0
		):
			user_help_needed.append({
				"code": code,
				"campaign": str(
					code_row.get("representatives", [{}])[0].get("campaign", "")
				),
				"request": str(catalog_entry.get("userAssistanceRequest", "")),
				"representative": code_row.get("representatives", [{}])[0],
			})
		by_code[code] = code_row
	for observed_code_value: Variant in observed_codes:
		var observed_code := str(observed_code_value)
		if not catalog_codes.has(observed_code):
			uncataloged_observed.append(observed_code)
	uncataloged_active.sort()
	uncataloged_observed.sort()

	var baseline: Dictionary = catalog.get("baseline", {})
	var baseline_deviations := _baseline_deviations(report, baseline)
	var catalog_error := str(catalog_result.get("error", ""))
	return {
		"catalogPath": catalog_path,
		"catalogSchemaVersion": int(catalog.get("schemaVersion", 0)),
		"catalogError": catalog_error,
		"catalogComplete": (
			catalog_error.is_empty()
			and invalid_entries.is_empty()
			and uncataloged_active.is_empty()
		),
		"baselineMatches": baseline_deviations.is_empty(),
		"baselineDeviations": baseline_deviations,
		"invalidCatalogEntries": invalid_entries,
		"uncatalogedActiveFallbackCodes": uncataloged_active,
		"uncatalogedObservedCodes": uncataloged_observed,
		"byCode": by_code,
		"byCampaign": by_campaign,
		"byDisposition": by_disposition,
		"byPriority": by_priority,
		"userHelpNeeded": user_help_needed,
	}


func render_markdown(report: Dictionary, audit: Dictionary) -> String:
	var totals: Dictionary = report.get("totals", {})
	var lines: Array[String] = [
		"# Classic fidelity-fallback audit",
		"",
		"This summary is generated from the readiness-only corpus audit. It records",
		"diagnostic ownership and priority; it does not include proprietary assets",
		"or the multi-megabyte raw readiness report.",
		"",
		"- Campaigns ready: %d/%d" % [
			int(totals.get("readyCampaigns", 0)),
			int(totals.get("campaigns", 0)),
		],
		"- Progression blockers: %d" % int(
			totals.get("progressionBlockers", 0)
		),
		"- Fidelity fallbacks: %d (%d active, %d inactive)" % [
			int(totals.get("fidelityFallbacks", 0)),
			_fallback_activity_total(audit, "active"),
			_fallback_activity_total(audit, "inactive"),
		],
		"- Catalog complete: %s" % str(
			audit.get("catalogComplete", false)
		).to_lower(),
		"- Baseline matches: %s" % str(
			audit.get("baselineMatches", false)
		).to_lower(),
		"",
		"## Ownership and priority totals",
		"",
		"| Group | Diagnostics |",
		"|---|---:|",
	]
	_append_count_rows(lines, "Disposition", audit.get("byDisposition", {}))
	_append_count_rows(lines, "Priority", audit.get("byPriority", {}))
	lines.append_array([
		"",
		"## Fallbacks by code",
		"",
		"| Code | Total | Active | Inactive | Priority | Disposition | Owner | Representative |",
		"|---|---:|---:|---:|---|---|---|---|",
	])
	var by_code: Dictionary = audit.get("byCode", {})
	var code_names: Array = by_code.keys()
	code_names.sort_custom(func(left: Variant, right: Variant) -> bool:
		var left_row: Dictionary = by_code[left]
		var right_row: Dictionary = by_code[right]
		var left_count := int(left_row.get("diagnostics", 0))
		var right_count := int(right_row.get("diagnostics", 0))
		return left_count > right_count if left_count != right_count else str(left) < str(right)
	)
	for code_value: Variant in code_names:
		var code := str(code_value)
		var row: Dictionary = by_code[code]
		var representatives: Array = row.get("representatives", [])
		var representative := ""
		if not representatives.is_empty():
			representative = _representative_text(representatives[0])
		lines.append(
			"| `%s` | %d | %d | %d | %s | %s | %s | %s |" % [
				code,
				int(row.get("diagnostics", 0)),
				int(row.get("active", 0)),
				int(row.get("inactive", 0)),
				_escape_cell(str(row.get("priority", "uncataloged"))),
				_escape_cell(str(row.get("disposition", "uncataloged"))),
				_escape_cell(str(row.get("owner", "unassigned"))),
				_escape_cell(representative),
			]
		)
	lines.append_array([
		"",
		"## Fallbacks by campaign",
		"",
		"| Campaign | Total | Active | Inactive |",
		"|---|---:|---:|---:|",
	])
	var by_campaign: Dictionary = audit.get("byCampaign", {})
	var campaign_names: Array = by_campaign.keys()
	campaign_names.sort()
	for campaign_value: Variant in campaign_names:
		var campaign := str(campaign_value)
		var row: Dictionary = by_campaign[campaign]
		lines.append("| %s | %d | %d | %d |" % [
			_escape_cell(campaign),
			int(row.get("diagnostics", 0)),
			int(row.get("active", 0)),
			int(row.get("inactive", 0)),
		])
	var user_help: Array = audit.get("userHelpNeeded", [])
	if not user_help.is_empty():
		lines.append_array(["", "## User help needed", ""])
		for request_value: Variant in user_help:
			if not (request_value is Dictionary):
				continue
			var request: Dictionary = request_value
			lines.append("- `%s` (%s): %s" % [
				str(request.get("code", "")),
				str(request.get("campaign", "")),
				str(request.get("request", "")),
			])
	return "\n".join(lines) + "\n"


func _load_catalog(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Could not open fallback catalog: %s" % path}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {"error": "Fallback catalog root must be a JSON object"}
	if int(parsed.get("schemaVersion", 0)) != 1:
		return {"error": "Unsupported fallback catalog schema"}
	if not (parsed.get("codes", null) is Dictionary):
		return {"error": "Fallback catalog codes must be a JSON object"}
	return {"catalog": parsed, "error": ""}


func _validate_catalog_entries(codes: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for code_value: Variant in codes:
		var code := str(code_value)
		var entry_value: Variant = codes[code_value]
		if not (entry_value is Dictionary):
			errors.append("%s: entry must be an object" % code)
			continue
		var entry: Dictionary = entry_value
		if str(entry.get("disposition", "")) not in VALID_DISPOSITIONS:
			errors.append("%s: invalid disposition" % code)
		if str(entry.get("priority", "")) not in VALID_PRIORITIES:
			errors.append("%s: invalid priority" % code)
		if str(entry.get("owner", "")).strip_edges().is_empty():
			errors.append("%s: owner is required" % code)
		if str(entry.get("requiredEvidence", "")).strip_edges().is_empty():
			errors.append("%s: requiredEvidence is required" % code)
		if not (entry.get("userAssistanceNeeded", null) is bool):
			errors.append("%s: userAssistanceNeeded must be boolean" % code)
		elif bool(entry.get("userAssistanceNeeded", false)) and str(
			entry.get("userAssistanceRequest", "")
		).strip_edges().is_empty():
			errors.append("%s: userAssistanceRequest is required" % code)
	errors.sort()
	return errors


static func _increment_activity(row: Dictionary, activity: String) -> void:
	row["diagnostics"] = int(row.get("diagnostics", 0)) + 1
	var key := "inactive" if activity == "inactive" else "active"
	row[key] = int(row.get(key, 0)) + 1


static func _add_count(destination: Dictionary, key: String, count: int) -> void:
	destination[key] = int(destination.get(key, 0)) + count


static func _representative(campaign: String, diagnostic: Dictionary) -> Dictionary:
	var representative := {
		"campaign": campaign,
		"source": str(diagnostic.get("source", "")),
		"record": str(
			diagnostic.get(
				"recordId",
				diagnostic.get("definitionStableId", diagnostic.get("recordIndex", ""))
			)
		),
		"slot": str(diagnostic.get("slot", "")),
		"reference": str(
			diagnostic.get("referenceId", diagnostic.get("resourceId", ""))
		),
	}
	for detail_key: String in ["fallbackFields", "unsupportedFields", "target"]:
		if diagnostic.has(detail_key):
			representative[detail_key] = diagnostic[detail_key]
	return representative


static func _baseline_deviations(
	report: Dictionary,
	baseline: Dictionary,
) -> Array[String]:
	var deviations: Array[String] = []
	var totals: Dictionary = report.get("totals", {})
	for field: String in [
		"campaigns",
		"readyCampaigns",
		"progressionBlockers",
		"fidelityFallbacks",
	]:
		if not baseline.has(field):
			deviations.append("baseline.%s is missing" % field)
			continue
		var actual := int(totals.get(field, -1))
		var expected := int(baseline[field])
		if actual != expected:
			deviations.append("%s expected %d, got %d" % [field, expected, actual])
	return deviations


static func _fallback_activity_total(audit: Dictionary, activity: String) -> int:
	var total := 0
	for row_value: Variant in audit.get("byCode", {}).values():
		if row_value is Dictionary:
			total += int(row_value.get(activity, 0))
	return total


static func _append_count_rows(
	lines: Array[String],
	label: String,
	counts: Dictionary,
) -> void:
	var keys: Array = counts.keys()
	keys.sort()
	for key_value: Variant in keys:
		lines.append("| %s: %s | %d |" % [
			label,
			_escape_cell(str(key_value)),
			int(counts[key_value]),
		])


static func _representative_text(representative: Dictionary) -> String:
	var parts: Array[String] = [str(representative.get("campaign", ""))]
	for field: String in ["source", "record", "slot", "reference"]:
		var value := str(representative.get(field, ""))
		if not value.is_empty():
			parts.append("%s %s" % [field, value])
	for field: String in ["fallbackFields", "unsupportedFields", "target"]:
		if representative.has(field):
			parts.append("%s %s" % [field, str(representative[field])])
	return "; ".join(parts)


static func _escape_cell(value: String) -> String:
	return value.replace("|", "\\|").replace("\n", " ")
