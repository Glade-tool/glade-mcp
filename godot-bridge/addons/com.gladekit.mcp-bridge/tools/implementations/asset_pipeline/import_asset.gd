extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Download, extract, and install an external asset into the project.
#
# The download URL is NOT supplied by the agent — it is resolved upstream from a
# trusted provider catalog and injected as `_resolvedUrl` (plus license /
# archive metadata). The agent only names a candidate from a prior find_asset
# result and confirms the license. This tool then, over HTTPS:
#   * downloads the asset (or pack archive) on a worker thread,
#   * extracts a .zip pack (or places a single file) under res://,
#   * triggers a filesystem rescan so Godot imports the new files, and
#   * writes a .gladekit-asset.json license sidecar for later auditing.
#
# Async: the download runs on a worker Thread so the editor never freezes. This
# tool follows the i_tool async protocol — execute() returns an "async_pending"
# marker and the bridge polls poll() until the job completes. See i_tool.gd.
#
# Args (post-normalization, snake_case):
#   candidate_id          (required) "<provider>/<slug>", e.g. "kenney/tiny-town"
#   asset_type            (required) sprite_2d | ui_sprite | model_3d |
#                                    audio_sfx | audio_music
#   license_acknowledged  (required) must be true — the license gate
#   target_path           (optional) res:// destination folder; sensible default
#                                    per asset_type
#   import_options        (optional) per-type overrides (accepted; minimal use
#                                    in v1 — Godot's import defaults are sane)
#
# Injected by the calling layer after it resolves the candidate against the
# provider catalog (the agent neither sets nor sees these):
#   _resolved_url, _resolved_license, _resolved_attribution,
#   _resolved_archive_format ("zip" | ""), _resolved_file_extension, _resolved_provider

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const HttpDownload = preload("res://addons/com.gladekit.mcp-bridge/bridge/http_download.gd")
const AssetPipelineGuard = preload("res://addons/com.gladekit.mcp-bridge/services/asset_pipeline_guard.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")

const MAX_DOWNLOAD_BYTES := 250 * 1024 * 1024
const DOWNLOAD_TIMEOUT_MSEC := 60_000
const SIDECAR_NAME := ".gladekit-asset.json"

# Default destination folder per asset type. The candidate slug is appended.
const _DEFAULT_DIRS := {
	"sprite_2d": "res://assets/sprites/",
	"ui_sprite": "res://assets/ui/",
	"model_3d": "res://assets/models/",
	"audio_sfx": "res://assets/audio/sfx/",
	"audio_music": "res://assets/audio/music/",
}

const _TEXTURE_EXTS := ["png", "jpg", "jpeg", "tga", "tiff", "bmp", "webp", "svg"]
const _MATERIAL_EXTS := ["tres", "material"]

var _thread: Thread = null
var _job: Dictionary = {}
var _final_result: Dictionary = {}
var _finalized := false


func _init() -> void:
	tool_name = "import_asset"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	# One import at a time per (singleton) tool instance.
	if _thread != null and _thread.is_alive():
		return ToolUtils.error("An asset import is already in progress; wait for it to finish before starting another.")

	# Fresh state for this call.
	_finalized = false
	_final_result = {}
	_job = {}

	var disabled := AssetPipelineGuard.reject_if_disabled()
	if not disabled.is_empty():
		return ToolUtils.error(disabled)

	var candidate_id := ToolUtils.parse_string_arg(args, "candidate_id")
	if candidate_id.is_empty():
		return ToolUtils.error("candidateId is required (e.g. 'kenney/tiny-town')")

	if not ToolUtils.parse_bool_arg(args, "license_acknowledged", false):
		return ToolUtils.error(
			"licenseAcknowledged must be true. Confirm the user accepts the license "
			+ "shown in the find_asset preview, then retry."
		)

	var asset_type := ToolUtils.parse_string_arg(args, "asset_type")
	if asset_type.is_empty():
		return ToolUtils.error("assetType is required (sprite_2d | ui_sprite | model_3d | audio_sfx | audio_music)")

	var resolved_url := ToolUtils.parse_string_arg(args, "_resolved_url")
	if resolved_url.is_empty():
		return ToolUtils.error(
			"No resolved download URL. The URL is resolved upstream from the provider "
			+ "catalog; import_asset cannot run without it. Re-run find_asset and retry."
		)

	# Defense in depth: the URL was resolved upstream, but re-check its host
	# against the provider allowlist before touching the network.
	var host_reject := AssetPipelineGuard.describe_url_host_rejection(candidate_id, resolved_url)
	if not host_reject.is_empty():
		return ToolUtils.error("Refusing to download — " + host_reject)

	# Resolve the destination folder.
	var target_path := ToolUtils.parse_string_arg(args, "target_path")
	if target_path.is_empty():
		var base_dir: String = _DEFAULT_DIRS.get(asset_type, "res://assets/imported/")
		target_path = base_dir + _slug(candidate_id) + "/"
	if not target_path.begins_with("res://"):
		return ToolUtils.error("targetPath must be under res:// (got '%s')" % target_path)
	if not target_path.ends_with("/"):
		target_path += "/"

	var demo_reject := DemoAssetsGuard.check_write(target_path)
	if not demo_reject.is_empty():
		return ToolUtils.error(demo_reject)

	var archive_format := ToolUtils.parse_string_arg(args, "_resolved_archive_format")
	var file_extension := ToolUtils.parse_string_arg(args, "_resolved_file_extension")
	var is_zip := archive_format == "zip"

	# Staging file (absolute path under user://) for the raw download.
	var stage_ext := ".zip" if is_zip else (file_extension if not file_extension.is_empty() else ".bin")
	var temp_abs := ProjectSettings.globalize_path("user://").path_join(
		"gladekit-asset-%d%s" % [Time.get_ticks_usec(), stage_ext]
	)

	# Build the full job BEFORE starting the worker. The worker reads these keys
	# and writes only "result"; the main thread reads "result" after join. No
	# field is mutated post-start, so no lock is needed.
	_job = {
		"url": resolved_url,
		"temp_abs": temp_abs,
		"is_zip": is_zip,
		"target_path": target_path,
		"target_abs_dir": ProjectSettings.globalize_path(target_path),
		"candidate_id": candidate_id,
		"file_extension": file_extension,
		"asset_type": asset_type,
		"license": ToolUtils.parse_string_arg(args, "_resolved_license", "UNKNOWN"),
		"attribution": ToolUtils.parse_string_arg(args, "_resolved_attribution", ""),
		"provider": ToolUtils.parse_string_arg(args, "_resolved_provider", _provider_of(candidate_id)),
		"source_url": resolved_url,
		"result": {},
	}

	_thread = Thread.new()
	_thread.start(_worker.bind(_job))

	return ToolUtils.success(
		"Downloading %s…" % candidate_id,
		{"async_pending": true, "candidateId": candidate_id},
	)


# Polled each editor tick by the bridge. {} while the download/extract worker
# is running; the final result once it has finished and the editor-side steps
# (rescan + sidecar) are done.
func poll() -> Dictionary:
	if _finalized:
		return _final_result
	if _thread == null:
		return {}
	if _thread.is_alive():
		return {}

	# Worker done — join on the main thread, then finalize.
	_thread.wait_to_finish()
	_thread = null

	var r: Dictionary = _job.get("result", {})
	if not bool(r.get("ok", false)):
		_final_result = ToolUtils.error(str(r.get("error", "asset import failed")))
		_finalized = true
		return _final_result

	var placed: Array = r.get("files", [])

	# Trigger a filesystem rescan so Godot imports the new files. Main-thread-only.
	var ei: Object = ToolUtils.get_editor_interface_safe()
	if ei != null:
		var fs = ei.get_resource_filesystem()
		if fs != null:
			fs.scan()

	var sidecar_path := _write_sidecar(_job, placed)

	_final_result = ToolUtils.success(
		"Imported %d file(s) from %s to %s" % [placed.size(), _job["candidate_id"], _job["target_path"]],
		{
			"candidateId": _job["candidate_id"],
			"targetPath": _job["target_path"],
			"license": _job["license"],
			"attribution": _job["attribution"],
			"downloadedBytes": int(r.get("bytes", 0)),
			"importedFileCount": placed.size(),
			"importedFiles": placed.slice(0, 50),
			"importedFilesTruncated": placed.size() > 50,
			"sidecarPath": sidecar_path,
		},
	)
	_finalized = true
	return _final_result


# ── Worker thread (no editor API — pure network + file I/O) ────────────────
func _worker(job: Dictionary) -> void:
	var dl: Dictionary = HttpDownload.download_to_file(
		job["url"], job["temp_abs"], MAX_DOWNLOAD_BYTES, DOWNLOAD_TIMEOUT_MSEC
	)
	if not bool(dl.get("success", false)):
		job["result"] = {"ok": false, "error": "download failed: " + str(dl.get("error", "?"))}
		_safe_remove(job["temp_abs"])
		return

	var bytes := int(dl.get("bytes", 0))
	DirAccess.make_dir_recursive_absolute(job["target_abs_dir"])

	var placed: Array = []
	if job["is_zip"]:
		var ex := _extract_zip(job["temp_abs"], job["target_abs_dir"], job["target_path"])
		_safe_remove(job["temp_abs"])
		if not bool(ex.get("ok", false)):
			job["result"] = {"ok": false, "error": str(ex.get("error", "extract failed"))}
			return
		placed = ex["files"]
	else:
		var fext: String = job["file_extension"] if not String(job["file_extension"]).is_empty() else ".bin"
		var fname: String = _slug(job["candidate_id"]) + fext
		var dest_abs: String = String(job["target_abs_dir"]).path_join(fname)
		if not _move_file(job["temp_abs"], dest_abs):
			job["result"] = {"ok": false, "error": "could not place downloaded file at " + dest_abs}
			return
		placed = [String(job["target_path"]) + fname]

	if placed.is_empty():
		job["result"] = {"ok": false, "error": "nothing was extracted from the download"}
		return
	job["result"] = {"ok": true, "bytes": bytes, "files": placed}


func _extract_zip(zip_abs: String, target_abs_dir: String, target_res: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_abs) != OK:
		return {"ok": false, "error": "downloaded archive could not be opened as a zip"}
	# Normalize the dir to a trailing-slash form for a robust zip-slip check.
	var guard_root := target_abs_dir if target_abs_dir.ends_with("/") else target_abs_dir + "/"
	var files: Array = []
	for entry in reader.get_files():
		var ename := String(entry)
		if ename.ends_with("/"):
			continue
		var dest_abs := guard_root.path_join(ename).simplify_path()
		# Zip-slip guard: reject any entry that escapes the target directory.
		if not dest_abs.begins_with(guard_root):
			push_warning("[GladeKit MCP Bridge] import_asset skipped suspicious archive entry: %s" % ename)
			continue
		var data := reader.read_file(ename)
		DirAccess.make_dir_recursive_absolute(dest_abs.get_base_dir())
		var f := FileAccess.open(dest_abs, FileAccess.WRITE)
		if f == null:
			continue
		f.store_buffer(data)
		f.close()
		files.append(target_res + ename)
	reader.close()
	if files.is_empty():
		return {"ok": false, "error": "archive contained no extractable files"}
	return {"ok": true, "files": files}


# ── Sidecar ────────────────────────────────────────────────────────────────
# Field names match the Unity bridge's .gladekit-asset.json so list_imported_assets
# (and any cross-engine auditing) reads one schema regardless of engine.
func _write_sidecar(job: Dictionary, placed: Array) -> String:
	var texture_files: Array = []
	var material_files: Array = []
	for p in placed:
		var ext := String(p).get_extension().to_lower()
		if ext in _TEXTURE_EXTS:
			texture_files.append(p)
		elif ext in _MATERIAL_EXTS:
			material_files.append(p)

	var data := {
		"candidate_id": job["candidate_id"],
		"provider": job["provider"],
		"license": job["license"],
		"attribution_text": job["attribution"],
		"source_url": job["source_url"],
		"imported_at": Time.get_datetime_string_from_system(true),
		"asset_type": job["asset_type"],
		"target_path": job["target_path"],
		"imported_files": placed,
		"texture_files": texture_files,
		"material_files": material_files,
	}

	var sidecar_res: String = String(job["target_path"]) + SIDECAR_NAME
	var sidecar_abs := ProjectSettings.globalize_path(sidecar_res)
	DirAccess.make_dir_recursive_absolute(sidecar_abs.get_base_dir())
	var f := FileAccess.open(sidecar_abs, FileAccess.WRITE)
	if f == null:
		push_warning("[GladeKit MCP Bridge] import_asset could not write license sidecar at %s" % sidecar_res)
		return ""
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return sidecar_res


# ── Small helpers ──────────────────────────────────────────────────────────
func _provider_of(candidate_id: String) -> String:
	var slash := candidate_id.find("/")
	return candidate_id.substr(0, slash) if slash > 0 else ""


func _slug(candidate_id: String) -> String:
	var slash := candidate_id.find("/")
	var raw := candidate_id.substr(slash + 1) if slash >= 0 else candidate_id
	var out := ""
	for i in raw.length():
		var c := raw[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_":
			out += c
		else:
			out += "-"
	return out if not out.is_empty() else "asset"


func _move_file(from_abs: String, to_abs: String) -> bool:
	if DirAccess.rename_absolute(from_abs, to_abs) == OK:
		return true
	# Cross-filesystem fallback: copy then remove.
	if DirAccess.copy_absolute(from_abs, to_abs) == OK:
		_safe_remove(from_abs)
		return true
	return false


func _safe_remove(abs_path: String) -> void:
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
