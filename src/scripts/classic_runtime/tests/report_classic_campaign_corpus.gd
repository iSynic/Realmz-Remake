extends SceneTree

const CorpusReportScript = preload(
	"res://scripts/classic_runtime/classic_campaign_corpus_report.gd"
)
const FallbackAuditScript = preload(
	"res://scripts/classic_runtime/classic_fidelity_fallback_audit.gd"
)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for child: Node in root.get_children():
		child.process_mode = Node.PROCESS_MODE_DISABLED
	var arguments := OS.get_cmdline_user_args()
	var json_output := arguments.has("--json")
	var readiness_only := arguments.has("--readiness-only")
	var include_compressed_estimate := not arguments.has("--no-compression")
	arguments.erase("--json")
	arguments.erase("--readiness-only")
	arguments.erase("--no-compression")
	var output_path := ""
	var summary_output_path := ""
	var catalog_path := FallbackAuditScript.DEFAULT_CATALOG_PATH
	var expected_campaigns := 13
	var positional: Array[String] = []
	for argument_value: Variant in arguments:
		var argument := str(argument_value)
		if argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--summary-output="):
			summary_output_path = argument.trim_prefix("--summary-output=")
		elif argument.begins_with("--fallback-catalog="):
			catalog_path = argument.trim_prefix("--fallback-catalog=")
		elif argument.begins_with("--expected-count="):
			var count_text := argument.trim_prefix("--expected-count=")
			if not count_text.is_valid_int():
				_print_usage()
				quit(2)
				return
			expected_campaigns = int(count_text)
		else:
			positional.append(argument)
	if positional.size() > 1:
		_print_usage()
		quit(2)
		return
	var campaigns_directory := (
		positional[0] if not positional.is_empty() else "res://Campaigns"
	)
	var report: Dictionary = CorpusReportScript.new().inspect(
		campaigns_directory,
		{
			"expectedCampaigns": expected_campaigns,
			"includeCompressedEstimate": include_compressed_estimate,
			"readinessOnly": readiness_only,
		}
	)
	var fallback_audit = FallbackAuditScript.new()
	var audit: Dictionary = fallback_audit.inspect(report, catalog_path)
	report["fallbackAudit"] = audit
	if not output_path.is_empty() and not _write_report(output_path, report):
		quit(2)
		return
	if not summary_output_path.is_empty() and not _write_text(
		summary_output_path,
		fallback_audit.render_markdown(report, audit),
	):
		quit(2)
		return
	if json_output:
		print(JSON.stringify(report))
	else:
		_print_report(report)
	var audit_ready := (
		bool(audit.get("catalogComplete", false))
		and bool(audit.get("baselineMatches", false))
	)
	quit(0 if bool(report.get("allReady", false)) and audit_ready else 1)


func _print_report(report: Dictionary) -> void:
	var totals: Dictionary = report.get("totals", {})
	var readiness_only := str(report.get("mode", "")) == "readiness-only"
	print(
		"Classic built-in campaign readiness"
		+ ("" if readiness_only else " and footprint")
	)
	print(
		"Campaigns: %d/%d; ready: %d; blocked: %d; install failures: %d"
		% [
			int(totals.get("campaigns", 0)),
			int(report.get("expectedCampaigns", 0)),
			int(totals.get("readyCampaigns", 0)),
			int(totals.get("blockedCampaigns", 0)),
			int(totals.get("installFailures", 0)),
		]
	)
	print(
		"Readiness: %d progression blockers; %d fidelity fallbacks"
		% [
			int(totals.get("progressionBlockers", 0)),
			int(totals.get("fidelityFallbacks", 0)),
		]
	)
	print(
		"Diagnostics: %d active; %d inactive; %d preparation errors"
		% [
			int(totals.get("activeDiagnostics", 0)),
			int(totals.get("inactiveDiagnostics", 0)),
			int(totals.get("preparationErrors", 0)),
		]
	)
	var audit: Dictionary = report.get("fallbackAudit", {})
	print(
		"Fallback catalog: %s; baseline: %s; uncataloged active codes: %d"
		% [
			"complete" if bool(audit.get("catalogComplete", false)) else "incomplete",
			"matched" if bool(audit.get("baselineMatches", false)) else "changed",
			audit.get("uncatalogedActiveFallbackCodes", []).size(),
		]
	)
	if not readiness_only:
		print(
			"Footprint: %.1f MiB installed; %.1f MiB compressed estimate; %.1f MiB JSON"
			% [
				_mib(totals.get("installedBytes", 0)),
				_mib(totals.get("compressedEstimateBytes", 0)),
				_mib(totals.get("jsonBytes", 0)),
			]
		)
		print(
			"Duplicate content: %.1f MiB total; %.1f MiB across campaign identities"
			% [
				_mib(totals.get("duplicateBytes", 0)),
				_mib(totals.get("crossCampaignDuplicateBytes", 0)),
			]
		)
	for campaign_value: Variant in report.get("campaigns", []):
		if not (campaign_value is Dictionary):
			continue
		var campaign: Dictionary = campaign_value
		var readiness: Dictionary = campaign.get("readiness", {})
		var campaign_totals: Dictionary = readiness.get("totals", {})
		var campaign_line := "- %s: %s; %d blocker(s); %d fallback(s)" % [
			str(campaign.get("directory", "")),
			str(campaign.get("install", {}).get("selectionState", "Invalid")),
			int(campaign_totals.get("progressionBlockers", 0)),
			int(campaign_totals.get("fidelityFallbacks", 0)),
		]
		if not readiness_only:
			campaign_line += "; %.1f MiB" % _mib(
				campaign.get("footprint", {}).get("installedBytes", 0)
			)
		print(campaign_line)


func _write_report(path: String, report: Dictionary) -> bool:
	return _write_text(path, JSON.stringify(report, "\t", true) + "\n")


func _write_text(path: String, contents: String) -> bool:
	var normalized := path.replace("\\", "/")
	if normalized.begins_with("res://") or normalized.begins_with("user://"):
		normalized = ProjectSettings.globalize_path(normalized)
	var parent := normalized.get_base_dir()
	if not parent.is_empty():
		var error := DirAccess.make_dir_recursive_absolute(parent)
		if error != OK:
			printerr("Could not create report directory: %s" % parent)
			return false
	var file := FileAccess.open(normalized, FileAccess.WRITE)
	if file == null:
		printerr("Could not write report: %s" % normalized)
		return false
	file.store_string(contents)
	file.close()
	return true


func _print_usage() -> void:
	print(
		"Usage: report_classic_campaign_corpus.gd [campaigns-directory] "
		+ "[--expected-count=13] [--output=<path>] [--summary-output=<path>] "
		+ "[--fallback-catalog=<path>] [--json] [--readiness-only] "
		+ "[--no-compression]"
	)


static func _mib(value: Variant) -> float:
	return float(value) / 1048576.0
