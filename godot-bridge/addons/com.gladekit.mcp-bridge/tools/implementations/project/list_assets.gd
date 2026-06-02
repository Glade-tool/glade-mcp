extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Walks the project filesystem for referenceable assets — textures, audio,
# models, scenes, Godot resources, fonts, and shaders — and returns them with
# a coarse `type` so a client (or the agent) can filter by kind. Complements
# get_project_info, whose project walk only counts scenes/scripts/resources
# and never enumerates raw media (textures/audio/models). Scripts are
# deliberately excluded — they have their own discovery via find_scripts.
# Read-only; safe in play mode.
#
# Args:
#   type_filter:    String — restrict to one category. One of "texture",
#                            "audio", "model", "scene", "resource", "font",
#                            "shader". Empty (default) returns all kinds.
#   name_contains:  String — case-insensitive substring on the filename.
#                            Empty matches all.
#   max_results:    int (default 200, clamped 1..1000)
#   include_addons: bool (default false) — include assets under res://addons/.
#
# Response payload:
#   assets:    [{path: String, type: String}] — res:// paths, sorted by path
#   count:     int
#   truncated: bool — a cap (max_results or the global walk cap) was hit

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX := 200
const HARD_CAP := 1000
# Even with a generous max_results, stop walking after this many filesystem
# entries so the tool stays responsive on pathological projects.
const MAX_WALK_ENTRIES := 10000

# Extension → coarse asset category. Lowercase, no leading dot. Scripts (.gd,
# .cs), import sidecars (.import), and UID files (.uid) are intentionally
# absent so they never show up as "assets".
const EXT_TYPE := {
	"png": "texture", "jpg": "texture", "jpeg": "texture", "webp": "texture",
	"svg": "texture", "bmp": "texture", "tga": "texture", "exr": "texture",
	"hdr": "texture", "dds": "texture", "ktx": "texture",
	"wav": "audio", "ogg": "audio", "mp3": "audio",
	"glb": "model", "gltf": "model", "obj": "model", "fbx": "model",
	"dae": "model", "blend": "model",
	"tscn": "scene", "scn": "scene",
	"tres": "resource", "res": "resource",
	"ttf": "font", "otf": "font", "woff": "font", "woff2": "font",
	"gdshader": "shader", "gdshaderinc": "shader",
}


func _init() -> void:
	tool_name = "list_assets"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var type_filter: String = ToolUtils.parse_string_arg(args, "type_filter").strip_edges().to_lower()
	var name_contains: String = ToolUtils.parse_string_arg(args, "name_contains").to_lower()
	var max_results: int = clamp(ToolUtils.parse_int_arg(args, "max_results", DEFAULT_MAX), 1, HARD_CAP)
	var include_addons: bool = ToolUtils.parse_bool_arg(args, "include_addons", false)

	var results: Array = []
	var truncated := false
	var visited := 0

	# Manual stack instead of recursion so very deep project trees don't blow
	# the GDScript call stack (mirrors find_scripts / get_project_info).
	var stack: Array = ["res://"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		if not include_addons and dir_path.begins_with("res://addons"):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			if visited >= MAX_WALK_ENTRIES:
				truncated = true
				break
			var entry := dir.get_next()
			if entry.is_empty():
				break
			visited += 1
			if entry.begins_with("."):
				continue
			var entry_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				# Skip the engine cache outright; addons handled above.
				if entry == ".godot":
					continue
				stack.push_back(entry_path)
				continue
			var ext := entry.get_extension().to_lower()
			if not EXT_TYPE.has(ext):
				continue
			var asset_type: String = EXT_TYPE[ext]
			if not type_filter.is_empty() and asset_type != type_filter:
				continue
			if not name_contains.is_empty() and not entry.to_lower().contains(name_contains):
				continue
			results.append({"path": entry_path, "type": asset_type})
			if results.size() >= max_results:
				truncated = true
				break
		dir.list_dir_end()
		if truncated:
			break

	results.sort_custom(func(a, b): return a["path"] < b["path"])
	return ToolUtils.success("Found %d asset(s)" % results.size(), {
		"assets": results,
		"count": results.size(),
		"truncated": truncated,
	})
