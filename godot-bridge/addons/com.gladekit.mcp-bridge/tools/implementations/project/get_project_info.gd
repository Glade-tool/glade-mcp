extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns a single-call snapshot of "what is this Godot project?" — enough
# for an agent dropped into an unknown project to orient itself without
# 4-5 separate exploratory calls (get_scene_tree + find_nodes + find_scripts
# + ad-hoc resource searches). Read-only and safe in play mode.
#
# Two response modes via `response_format`:
#   "concise" (default) — project metadata + counts. ~150 tokens.
#   "detailed"           — adds bounded file listings, top-level dirs,
#                          and the input map. ~500 tokens for typical
#                          projects.
#
# All file scans are bounded: per-category caps (50 scenes / 50 scripts /
# 30 resources) and a hard global walk cap of 5000 entries to keep the
# tool fast on pathological projects. Truncation is reported via boolean
# flags so the agent knows when to follow up with a narrower search.
#
# Args:
#   response_format: "concise" (default) | "detailed"
#
# Response payload (concise):
#   project: {
#     name, description, godot_version, renderer,
#     main_scene, current_scene,
#     scene_count, script_count, resource_count,
#     enabled_addons: [String], supports_uid: bool,
#   }
#
# Response payload (detailed) adds:
#   project.scenes:        [{path, name}]
#   project.scripts:       [{path, name}]
#   project.resources:     [{path, format}]  format is "tres" (text) or "res" (binary)
#   project.top_level_dirs:[String]   res:// folders only
#   project.input_actions: [String]   custom (non-engine-builtin) input actions
#   project.*_truncated:   bool       per-category cap was hit

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Per-category caps. Generous enough to cover typical projects, tight
# enough to bound token cost on pathological ones.
const MAX_SCENES_LISTED := 50
const MAX_SCRIPTS_LISTED := 50
const MAX_RESOURCES_LISTED := 30
# Global walk cap. Even if all caps are unbounded, we stop after this many
# filesystem entries so the tool stays responsive on huge projects.
const MAX_WALK_ENTRIES := 5000





func _init() -> void:
	tool_name = "get_project_info"
	requires_edit_mode = false  # read-only — safe during play


func execute(args: Dictionary) -> Dictionary:
	var detailed: bool = ToolUtils.parse_string_arg(args, "response_format", "concise").to_lower() == "detailed"

	var info: Dictionary = _read_project_settings()
	info["supports_uid"] = ToolUtils.compare_versions(info["godot_version"], "4.4") >= 0

	var counts: Dictionary = {"scene": 0, "script": 0, "resource": 0}
	var listings: Dictionary = {}
	if detailed:
		listings = {"scenes": [], "scripts": [], "resources": []}
	_walk_project(counts, listings, detailed)
	info["scene_count"] = counts["scene"]
	info["script_count"] = counts["script"]
	info["resource_count"] = counts["resource"]

	if detailed:
		info["scenes"] = listings["scenes"]
		info["scripts"] = listings["scripts"]
		info["resources"] = listings["resources"]
		info["scenes_truncated"] = counts["scene"] > MAX_SCENES_LISTED
		info["scripts_truncated"] = counts["script"] > MAX_SCRIPTS_LISTED
		info["resources_truncated"] = counts["resource"] > MAX_RESOURCES_LISTED
		info["top_level_dirs"] = _list_top_level_dirs()
		info["input_actions"] = _list_custom_input_actions()

	return ToolUtils.success(
		"Project '%s' (Godot %s)" % [info.get("name", "<unnamed>"), info["godot_version"]],
		{"project": info},
	)


# ── Project metadata reads ───────────────────────────────────────────────

func _read_project_settings() -> Dictionary:
	var info: Dictionary = {
		"name": str(ProjectSettings.get_setting("application/config/name", "")),
		"description": str(ProjectSettings.get_setting("application/config/description", "")),
		"main_scene": str(ProjectSettings.get_setting("application/run/main_scene", "")),
		"godot_version": Engine.get_version_info().get("string", ""),
		"renderer": _detect_renderer(),
		"current_scene": _current_scene_path(),
		"enabled_addons": _enabled_addon_list(),
	}
	return info


func _current_scene_path() -> String:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ""
	# scene_file_path is the res:// URI of the scene currently being edited.
	# Empty for an unsaved/new scene.
	var p := root.scene_file_path
	return p if not p.is_empty() else ""


func _detect_renderer() -> String:
	# project.godot stores the rendering method as a string. The same value
	# powers Godot's "Renderer" Project Settings dropdown:
	#   "forward_plus", "mobile", "gl_compatibility"
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	if method.is_empty():
		# Fall back to the features list (older projects).
		var features = ProjectSettings.get_setting("application/config/features", PackedStringArray())
		if features is PackedStringArray:
			for f in features:
				var s := String(f).to_lower()
				if s.contains("forward"):
					return "forward_plus"
				if s.contains("mobile"):
					return "mobile"
				if s.contains("compatibility"):
					return "gl_compatibility"
	return method


func _enabled_addon_list() -> Array:
	# editor_plugins/enabled is a PackedStringArray of plugin.cfg res:// paths.
	# Strip the trailing "/plugin.cfg" so the agent sees clean addon dirs.
	var raw = ProjectSettings.get_setting("editor_plugins/enabled", PackedStringArray())
	var out: Array = []
	if raw is PackedStringArray or raw is Array:
		for p in raw:
			var s := String(p)
			if s.ends_with("/plugin.cfg"):
				s = s.substr(0, s.length() - "/plugin.cfg".length())
			out.append(s)
	out.sort()
	return out


# ── File walk ────────────────────────────────────────────────────────────

# Recursive res:// walk. Updates `counts` for every matched file and (when
# detailed) appends bounded entries to `listings`. Skips .godot/ cache,
# the addon directory (the agent doesn't need to see our own plugin), and
# anything that looks like a hidden dir.
func _walk_project(counts: Dictionary, listings: Dictionary, detailed: bool) -> void:
	var visited: int = 0
	var stack: Array = ["res://"]
	while not stack.is_empty():
		if visited >= MAX_WALK_ENTRIES:
			return
		var dir_path: String = stack.pop_back()
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			if visited >= MAX_WALK_ENTRIES:
				dir.list_dir_end()
				return
			var entry := dir.get_next()
			if entry.is_empty():
				break
			visited += 1
			if entry.begins_with("."):
				continue
			var full: String = dir_path.path_join(entry) if dir_path.ends_with("/") else dir_path + "/" + entry
			if dir.current_is_dir():
				# Skip directories we don't want to traverse.
				if entry == "addons" or entry == ".godot":
					continue
				stack.append(full)
				continue
			# File: categorize by extension.
			var ext := entry.get_extension().to_lower()
			match ext:
				"tscn":
					counts["scene"] += 1
					if detailed and listings["scenes"].size() < MAX_SCENES_LISTED:
						listings["scenes"].append({
							"path": full,
							"name": entry.get_basename(),
						})
				"gd":
					counts["script"] += 1
					if detailed and listings["scripts"].size() < MAX_SCRIPTS_LISTED:
						listings["scripts"].append({
							"path": full,
							"name": entry.get_basename(),
						})
				"tres", "res":
					counts["resource"] += 1
					if detailed and listings["resources"].size() < MAX_RESOURCES_LISTED:
						# Resource format from extension only — Godot 4 has no
						# public static path-to-type API; loading the resource
						# just to discover its class is expensive (it triggers
						# imports as a side effect). The agent can follow up
						# with a load() call if it needs the exact type.
						listings["resources"].append({
							"path": full,
							"format": ext,  # "tres" (text) or "res" (binary)
						})
		dir.list_dir_end()


# ── Detailed-only helpers ────────────────────────────────────────────────

func _list_top_level_dirs() -> Array:
	var out: Array = []
	var dir := DirAccess.open("res://")
	if dir == null:
		return out
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with("."):
			continue
		if dir.current_is_dir() and entry != ".godot":
			out.append(entry)
	dir.list_dir_end()
	out.sort()
	return out


func _list_custom_input_actions() -> Array:
	# Read project.godot directly via ConfigFile and pull the keys from
	# the [input] section. This is the ONLY way to get just what the user
	# wrote into project.godot:
	#   - InputMap.get_actions() returns the LIVE map (engine ui_* defaults +
	#     in-editor shortcuts + runtime-registered actions).
	#   - ProjectSettings.get_property_list() with PROPERTY_USAGE_STORAGE
	#     also returns engine defaults — that flag means "stored in some
	#     project.godot somewhere", not "saved by this user". An empty
	#     [input] section still yielded 90+ ui_* entries in 4.6 testing.
	#   - ConfigFile.load("res://project.godot") only sees what's literally
	#     written in the file. No section, no actions. Project author
	#     configured `move_left={...}`, that's the one entry we return.
	var out: Array = []
	var cfg := ConfigFile.new()
	var err := cfg.load("res://project.godot")
	if err != OK:
		# Can't read the project file — return empty rather than fall back
		# to a less accurate source.
		return out
	if not cfg.has_section("input"):
		return out
	for key in cfg.get_section_keys("input"):
		out.append(String(key))
	out.sort()
	return out
