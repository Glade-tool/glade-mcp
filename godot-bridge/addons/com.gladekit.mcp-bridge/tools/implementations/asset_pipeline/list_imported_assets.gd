extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Walk res:// for .gladekit-asset.json sidecars and return their license +
# attribution metadata. Read-only — useful before commercial release to audit
# what's been imported and which assets require attribution (CC-BY does, CC0
# does not). Mirrors the Unity bridge's list_imported_assets, including the
# sidecar schema, so an auditor sees one shape regardless of engine.
#
# Args:
#   license_filter: String (optional) — restrict to one license code
#       ("CC0-1.0", "CC-BY-4.0", "CC-BY-SA-4.0", "MIT"). "any" or empty
#       returns every imported bundle.
#
# Response payload:
#   count:                    int — bundles returned (after filtering)
#   truncated:                bool — the MAX_ENTRIES cap was hit
#   additionalNotShown:       int — bundles beyond the cap
#   licenseCounts:            { <license>: int } — per-license tally
#   attributionRequiredCount: int — bundles whose license needs credit
#   entries: [{ candidate_id, provider, license, attribution_text, source_url,
#               imported_at, asset_type, target_path, imported_file_count,
#               sidecar_path }]

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const AssetPipelineGuard = preload("res://addons/com.gladekit.mcp-bridge/services/asset_pipeline_guard.gd")

const SIDECAR_NAME := ".gladekit-asset.json"
# Bound the response so a project with hundreds of imports doesn't blow context.
const MAX_ENTRIES := 200
# Backstop the filesystem walk on pathological projects.
const MAX_WALK_ENTRIES := 20000

const _SIDECAR_FIELDS := [
	"candidate_id", "provider", "license", "attribution_text",
	"source_url", "imported_at", "asset_type", "target_path",
]


func _init() -> void:
	tool_name = "list_imported_assets"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var disabled := AssetPipelineGuard.reject_if_disabled()
	if not disabled.is_empty():
		return ToolUtils.error(disabled)

	var license_filter := ToolUtils.parse_string_arg(args, "license_filter")
	if license_filter.to_lower() == "any":
		license_filter = ""

	var sidecars: Array = []
	_walk("res://", sidecars, {"n": 0})

	var entries: Array = []
	var truncated := 0
	for sidecar_path in sidecars:
		if entries.size() >= MAX_ENTRIES:
			truncated += 1
			continue
		var meta := _parse_sidecar(sidecar_path)
		if meta.is_empty():
			continue
		if not license_filter.is_empty():
			if String(meta.get("license", "")).to_lower() != license_filter.to_lower():
				continue
		meta["sidecar_path"] = sidecar_path
		entries.append(meta)

	var license_counts: Dictionary = {}
	var attribution_required := 0
	for e in entries:
		var lic := String(e.get("license", "UNKNOWN"))
		license_counts[lic] = int(license_counts.get(lic, 0)) + 1
		if _requires_attribution(lic):
			attribution_required += 1

	var msg: String
	if entries.is_empty():
		msg = "No assets imported via the pipeline yet."
	else:
		var extra := " (+%d not shown)" % truncated if truncated > 0 else ""
		msg = "Found %d imported asset bundle(s)%s." % [entries.size(), extra]

	return ToolUtils.success(msg, {
		"count": entries.size(),
		"truncated": truncated > 0,
		"additionalNotShown": truncated,
		"licenseCounts": license_counts,
		"attributionRequiredCount": attribution_required,
		"entries": entries,
	})


# Recursive res:// walk. Skips hidden engine dirs (.godot, .import) and
# res://addons/ — no user-imported sidecars live there, and the import cache is
# large. include_hidden is required because sidecars are dot-files.
func _walk(dir_path: String, out: Array, walked: Dictionary) -> void:
	if int(walked["n"]) > MAX_WALK_ENTRIES:
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.include_hidden = true
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		walked["n"] = int(walked["n"]) + 1
		if int(walked["n"]) > MAX_WALK_ENTRIES:
			break
		var full := dir_path.path_join(entry)
		if d.current_is_dir():
			if not entry.begins_with(".") and full != "res://addons":
				_walk(full, out, walked)
		elif entry == SIDECAR_NAME:
			out.append(full)
		entry = d.get_next()
	d.list_dir_end()


func _parse_sidecar(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(txt) != OK or not (json.data is Dictionary):
		return {}
	var data: Dictionary = json.data
	var meta: Dictionary = {}
	for field in _SIDECAR_FIELDS:
		if data.has(field):
			meta[field] = str(data[field])
	# Surface the imported-file count rather than the full list — the audit
	# consumer rarely needs every path inline, and the sidecar still has them.
	var files = data.get("imported_files", [])
	if files is Array:
		meta["imported_file_count"] = files.size()
	return meta


func _requires_attribution(license: String) -> bool:
	var l := license.to_upper()
	return l.contains("CC-BY") or l == "MIT"
