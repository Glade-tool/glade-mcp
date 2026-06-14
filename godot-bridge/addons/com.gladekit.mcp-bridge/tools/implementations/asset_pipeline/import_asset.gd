extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Download, extract, and install an external asset into the project.
#
# The download URL is NOT supplied by the agent — it is resolved upstream from a
# trusted provider catalog and injected as `_resolvedUrl` (plus license /
# archive metadata). The agent only names a candidate from a prior find_asset
# result and confirms the license. This tool then, over HTTPS:
#   * downloads the asset (or pack archive) on a worker thread,
#   * extracts a .zip pack (or places a single file) under res://,
#   * applies per-type import quality (sprite filter via import_options;
#     audio_music auto-configured to loop — Godot defaults audio to no-loop),
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
#   import_options        (optional) per-type overrides. Supported keys:
#                            filter: "nearest" | "linear" — for sprite_2d /
#                              ui_sprite, sets the project-wide canvas texture
#                              filter. "nearest" keeps pixel art crisp; Godot's
#                              "linear" default blurs it. (Godot 4 has no
#                              per-texture filter import setting, so this is a
#                              project-default change, reported in the result.)
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

# ── Texture filtering (pixel-art quality bar) ───────────────────────────────
# Godot 4 has NO per-texture filter import setting (unlike Godot 3's
# flags/filter). 2D texture filtering is resolved at draw time from either the
# project-wide default or a per-node CanvasItem.texture_filter override. Since
# import_asset only places files (it doesn't author scenes), the one lever it
# can pull at import time is the project default. We pull it ONLY when the
# caller explicitly asks via import_options.filter — the agent knows the user's
# stated style ("pixel art" → "nearest"), so the intent is supplied with
# context rather than guessed from the asset_type alone. Reported in the result
# so the global change is never silent.
const _FILTER_SETTING := "rendering/textures/canvas_textures/default_texture_filter"
# CanvasItem.TextureFilter enum: 0 = NEAREST (crisp pixels), 1 = LINEAR (smooth).
const _FILTER_VALUES := {"nearest": 0, "linear": 1}
const _FILTER_DEFAULT_LINEAR := 1
# Filtering only meaningfully applies to 2D sprite imports. model_3d textures
# are PBR and want linear+mipmaps; audio has no textures.
const _FILTER_APPLICABLE_TYPES := ["sprite_2d", "ui_sprite"]

# ── Audio looping (music quality bar) ───────────────────────────────────────
# Every Godot 4 audio importer defaults to NO loop (verified 4.6.3: ogg/mp3
# loop=false). Background music that plays once and stops reads as broken, so
# audio_music imports are configured to loop. SFX keep the no-loop default.
# Per format: the importer id + the bool `loop` param.
#
# WAV is deliberately omitted: its `edit/loop_mode` enum is NOT applied to the
# imported AudioStreamWAV through a pre-written .import (verified 4.6.3 — the
# loaded resource stays loop_mode=0 regardless of edit/loop_mode / loop_end).
# ogg/mp3's bool `loop` round-trips correctly, and Kenney music ships as ogg,
# so .wav music simply keeps the no-loop default (no regression — it never
# looped before). Revisit if a WAV-music provider is added.
const _AUDIO_LOOP_SPECS := {
	"ogg": {"importer": "oggvorbisstr", "param": "loop", "value": "true"},
	"mp3": {"importer": "mp3", "param": "loop", "value": "true"},
}

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

	# Parse import_options.filter early so a typo'd value fails fast — before any
	# network work — rather than silently doing nothing (input-resolution audit
	# pattern). import_options is a nested dict; normalize_args only touches
	# top-level keys, so read the inner key case-insensitively.
	var import_options: Dictionary = args["import_options"] if (args.has("import_options") and args["import_options"] is Dictionary) else {}
	var filter_parse := parse_filter_option(import_options)
	if not bool(filter_parse.get("ok", false)):
		return ToolUtils.error(str(filter_parse.get("error", "invalid import_options.filter")))
	var filter := str(filter_parse.get("filter", ""))

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
		"filter": filter,
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

	# Pre-write .import sidecars so audio_music files import as looping. This
	# MUST happen before scan() picks the files up — Godot honors a partial
	# .import (importer + params) on first import and fills the rest, which
	# sidesteps the async "reimport after scan" round-trip. Music is the only
	# type that needs it: every audio importer defaults to no-loop (verified
	# against 4.6.3), so imported background music would otherwise play once and
	# stop. SFX are left at the no-loop default (correct).
	var looped: Array = []
	if _job.get("asset_type", "") == "audio_music":
		looped = _prewrite_loop_imports(placed)

	# Trigger a filesystem rescan so Godot imports the new files. Main-thread-only.
	var ei: Object = ToolUtils.get_editor_interface_safe()
	if ei != null:
		var fs = ei.get_resource_filesystem()
		if fs != null:
			fs.scan()

	var sidecar_path := _write_sidecar(_job, placed)

	# Apply the requested texture filter (pixel-art crispness). Only for 2D
	# sprite types — see _FILTER_APPLICABLE_TYPES. Main-thread only (poll runs
	# on the main thread), as ProjectSettings.save() must.
	var filter_result: Dictionary = _apply_texture_filter(_job.get("filter", ""), _job.get("asset_type", ""))

	var extras := {
		"candidateId": _job["candidate_id"],
		"targetPath": _job["target_path"],
		"license": _job["license"],
		"attribution": _job["attribution"],
		"downloadedBytes": int(r.get("bytes", 0)),
		"importedFileCount": placed.size(),
		"importedFiles": placed.slice(0, 50),
		"importedFilesTruncated": placed.size() > 50,
		"sidecarPath": sidecar_path,
	}
	var message := "Imported %d file(s) from %s to %s" % [placed.size(), _job["candidate_id"], _job["target_path"]]
	if not filter_result.is_empty():
		extras["textureFilter"] = filter_result
		if bool(filter_result.get("applied", false)):
			message += " (texture filter → %s)" % filter_result.get("value", "")
	if not looped.is_empty():
		extras["audioLooping"] = {"configuredCount": looped.size(), "files": looped.slice(0, 50)}
		message += " (music set to loop)"

	_final_result = ToolUtils.success(message, extras)
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


# ── Texture filter ──────────────────────────────────────────────────────────
# Pure validation of import_options.filter. Static + side-effect-free so it's
# unit-testable without an editor or ProjectSettings. Returns:
#   {"ok": true,  "filter": "nearest"|"linear"|""}  (empty = not requested)
#   {"ok": false, "error": "<message>"}              (unrecognized value)
static func parse_filter_option(import_options: Dictionary) -> Dictionary:
	var raw = _ci_get(import_options, "filter")
	if raw == null:
		return {"ok": true, "filter": ""}
	var f := str(raw).strip_edges().to_lower()
	if f.is_empty():
		return {"ok": true, "filter": ""}
	if not _FILTER_VALUES.has(f):
		return {
			"ok": false,
			"error": "import_options.filter must be 'nearest' or 'linear' (got '%s')" % f,
		}
	return {"ok": true, "filter": f}


# Case-insensitive lookup into a dict. normalize_args only normalizes top-level
# keys, so a nested import_options may carry "filter", "Filter", etc.
static func _ci_get(d: Dictionary, key: String):
	if d.has(key):
		return d[key]
	var lower := key.to_lower()
	for k in d.keys():
		if str(k).to_lower() == lower:
			return d[k]
	return null


# Pure decision: given the requested filter, the asset type, and the project's
# CURRENT filter value, what should happen? Side-effect-free and static so it's
# exhaustively unit-testable without touching ProjectSettings. Returns one of:
#   {"action": "none"}                                   filter not requested / invalid
#   {"action": "skip", "value", "reason"}                requested but shouldn't apply
#   {"action": "apply", "value", "target", "previousValue"}  flip the project default
static func resolve_filter_change(filter: String, asset_type: String, current: int) -> Dictionary:
	if filter.is_empty() or not _FILTER_VALUES.has(filter):
		return {"action": "none"}
	if not (asset_type in _FILTER_APPLICABLE_TYPES):
		return {
			"action": "skip",
			"value": filter,
			"reason": "filter only applies to 2D sprite imports (sprite_2d, ui_sprite); asset_type was '%s'" % asset_type,
		}
	var target: int = _FILTER_VALUES[filter]
	if current == target:
		return {"action": "skip", "value": filter, "reason": "project default already %s" % filter}
	return {"action": "apply", "value": filter, "target": target, "previousValue": current}


# Apply the requested filter to the project-wide canvas default. No-op (returns
# {}) when no filter was requested. When the asset type isn't a 2D sprite type,
# records a skip rather than touching a global the user can't have meant for PBR
# / audio. Reports previous→new so the global mutation is transparent. The pure
# decision lives in resolve_filter_change; this thin wrapper performs the
# ProjectSettings side effects (the only part that can't be unit-tested safely).
func _apply_texture_filter(filter: String, asset_type: String) -> Dictionary:
	var current: int = int(ProjectSettings.get_setting(_FILTER_SETTING, _FILTER_DEFAULT_LINEAR))
	var decision := resolve_filter_change(filter, asset_type, current)
	match decision.get("action", "none"):
		"skip":
			return {"setting": _FILTER_SETTING, "value": decision["value"], "applied": false, "reason": decision["reason"]}
		"apply":
			ProjectSettings.set_setting(_FILTER_SETTING, decision["target"])
			var err := ProjectSettings.save()
			if err != OK:
				return {"setting": _FILTER_SETTING, "value": decision["value"], "applied": false, "reason": "ProjectSettings.save() failed (err %d)" % err}
			return {"setting": _FILTER_SETTING, "value": decision["value"], "applied": true, "previousValue": decision["previousValue"]}
		_:
			return {}


# ── Audio looping ────────────────────────────────────────────────────────────
# Build the partial .import text that makes an audio file loop. Empty string for
# any non-audio extension. Static + pure → unit-testable without an editor.
# Godot honors a partial .import (importer + params) on first import and fills
# in type/uid/deps + remaining param defaults — verified against 4.6.3.
static func build_loop_import_text(ext: String) -> String:
	var spec = _AUDIO_LOOP_SPECS.get(ext.to_lower(), null)
	if spec == null:
		return ""
	return "[remap]\n\nimporter=\"%s\"\n\n[params]\n\n%s=%s\n" % [spec["importer"], spec["param"], spec["value"]]


# Pre-write loop-enabling .import sidecars for the audio files in `placed`.
# Must run BEFORE the scan() that imports them. Skips non-audio files and any
# file that already has an .import (don't clobber a pre-existing config).
# Returns the res:// paths configured, for the result extra.
func _prewrite_loop_imports(placed: Array) -> Array:
	var done: Array = []
	for p in placed:
		var ext := String(p).get_extension()
		var text := build_loop_import_text(ext)
		if text.is_empty():
			continue
		var import_abs := ProjectSettings.globalize_path(String(p) + ".import")
		if FileAccess.file_exists(import_abs):
			continue
		var f := FileAccess.open(import_abs, FileAccess.WRITE)
		if f == null:
			push_warning("[GladeKit MCP Bridge] import_asset could not pre-write loop import for %s" % p)
			continue
		f.store_string(text)
		f.close()
		done.append(p)
	return done


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
