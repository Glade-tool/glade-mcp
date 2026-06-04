extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Scaffolds and configures the scene's WorldEnvironment + Environment in one
# call. This is the "make my scene look atmospheric" tool — fog, ambient
# light, tonemap, glow, sky background.
#
# Godot's lighting model: a WorldEnvironment node holds an Environment
# resource that drives sky, ambient, fog, post-processing for the entire
# scene. This tool finds or creates the WorldEnvironment, finds or creates
# its Environment, then applies the property bag the agent passed. Missing
# args leave existing values untouched.
#
# Three operating modes:
#   1. Property bag (most common) — pass background_mode, fog_*, ambient_*,
#      tonemap_mode, etc. The tool ensures a WorldEnvironment + Environment
#      exist and applies the args. Procedural sky auto-scaffolded when
#      background_mode='sky' and no sky is currently assigned.
#   2. Environment.tres assignment — pass environment_path to load and
#      assign an existing Environment resource. Property args are still
#      applied AFTER the assignment.
#   3. Pure scaffold — no args creates a default WorldEnvironment + empty
#      Environment so the agent can iterate on it.
#
# Args (all optional unless noted):
#   environment_path:        String — res:// path to an Environment .tres.
#                                     Loaded and assigned before property args.
#   background_mode:         "clear_color" | "color" | "sky" | "canvas" | "keep"
#   background_color:        "r,g,b" | "#rrggbb"
#   ambient_light_source:    "background" | "disabled" | "color" | "sky"
#   ambient_light_color:     color
#   ambient_light_energy:    float
#   fog_enabled:             bool
#   fog_light_color:         color (note: Godot 4 uses fog_light_color, not fog_color)
#   fog_density:             float
#   tonemap_mode:            "linear" | "reinhardt" | "filmic" | "aces"
#                            ("reinhard" also accepted for back-compat)
#   tonemap_exposure:        float
#   glow_enabled:            bool
#   ssao_enabled:            bool
#   procedural_sky:          bool — when true AND no sky is currently assigned,
#                                   create a ProceduralSkyMaterial inline.
#                                   Implied when background_mode='sky'.
#
# Response payload:
#   world_environment_path: scene-relative path of the WorldEnvironment node
#   environment_path:       res:// path if loaded from disk, else "<inline>"
#   created_world_environment: bool — true if we added the node this call
#   created_environment:    bool — true if we attached a new Environment
#   applied_properties:     [String]
#   ignored_properties:     [{name, reason}]

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const _WORLD_ENV_NAME := "WorldEnvironment"

# Background / ambient / tonemap enum names accepted by this tool. The names
# are constants here for parse-time validation in the schema; the int mapping
# lives in _resolve_*_mode() match statements below.
#
# Why match instead of `const { "key": Environment.BG_FOO, ... }`: Godot 4's
# GDScript parser does NOT treat built-in-class enum members as constant
# expressions in `const` Dictionary literals. The script silently fails to
# parse, preload returns null, and the bridge's `_register_all()` dies on
# `.new()` partway through — taking down every tool registered after it.
# Match statements at function level dodge the const-evaluator entirely.
const _BACKGROUND_MODES: Array[String] = ["clear_color", "color", "sky", "canvas", "keep"]
const _AMBIENT_SOURCES: Array[String]  = ["background", "disabled", "color", "sky"]
const _TONEMAPS: Array[String]         = ["linear", "reinhardt", "filmic", "aces"]


func _init() -> void:
	tool_name = "set_world_environment"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	# Locate-or-create the WorldEnvironment node.
	var created_we := false
	var we: WorldEnvironment = _find_world_environment(root)
	if we == null:
		we = WorldEnvironment.new()
		we.name = _WORLD_ENV_NAME
		root.add_child(we)
		we.owner = root
		created_we = true

	# Locate-or-create the Environment resource, with optional .tres load.
	var created_env := false
	var loaded_env_path := ""
	if args.has("environment_path") and not String(args["environment_path"]).is_empty():
		var env_path: String = ToolUtils.parse_path_arg(args, "environment_path")
		if not FileAccess.file_exists(env_path):
			return ToolUtils.error_with_solutions(
				"Environment file not found at '%s'" % env_path,
				["Use create_resource(type='Environment', path='%s') to scaffold it" % env_path],
			)
		var loaded := load(env_path)
		if not (loaded is Environment):
			return ToolUtils.error("'%s' did not load as an Environment (got %s)" % [env_path, typeof(loaded)])
		we.environment = loaded
		loaded_env_path = env_path
	if we.environment == null:
		we.environment = Environment.new()
		created_env = true
	var env: Environment = we.environment

	var applied: Array = []
	var ignored: Array = []

	# ── Background ────────────────────────────────────────────────────────
	if args.has("background_mode"):
		var mode: String = ToolUtils.parse_string_arg(args, "background_mode").to_lower()
		var bg_id: int = _resolve_background_mode(mode)
		if bg_id >= 0:
			env.background_mode = bg_id
			applied.append("background_mode")
		else:
			ignored.append({"name": "background_mode", "reason": "unknown value '%s' (use one of: %s)" % [mode, ", ".join(_BACKGROUND_MODES)]})
	if args.has("background_color"):
		var c := ToolUtils.parse_color_arg(args["background_color"], _COLOR_SENTINEL)
		if c == _COLOR_SENTINEL:
			ignored.append({"name": "background_color", "reason": "could not parse '%s' as a color" % str(args["background_color"])})
		else:
			env.background_color = c
			applied.append("background_color")

	# ── Ambient ───────────────────────────────────────────────────────────
	if args.has("ambient_light_source"):
		var src: String = ToolUtils.parse_string_arg(args, "ambient_light_source").to_lower()
		var amb_id: int = _resolve_ambient_source(src)
		if amb_id >= 0:
			env.ambient_light_source = amb_id
			applied.append("ambient_light_source")
		else:
			ignored.append({"name": "ambient_light_source", "reason": "unknown value '%s' (use one of: %s)" % [src, ", ".join(_AMBIENT_SOURCES)]})
	if args.has("ambient_light_color"):
		var c := ToolUtils.parse_color_arg(args["ambient_light_color"], _COLOR_SENTINEL)
		if c == _COLOR_SENTINEL:
			ignored.append({"name": "ambient_light_color", "reason": "could not parse '%s' as a color" % str(args["ambient_light_color"])})
		else:
			env.ambient_light_color = c
			applied.append("ambient_light_color")
	if args.has("ambient_light_energy"):
		env.ambient_light_energy = ToolUtils.parse_float_arg(args, "ambient_light_energy", env.ambient_light_energy)
		applied.append("ambient_light_energy")

	# ── Fog ───────────────────────────────────────────────────────────────
	if args.has("fog_enabled"):
		env.fog_enabled = ToolUtils.parse_bool_arg(args, "fog_enabled", env.fog_enabled)
		applied.append("fog_enabled")
	if args.has("fog_light_color"):
		var c := ToolUtils.parse_color_arg(args["fog_light_color"], _COLOR_SENTINEL)
		if c == _COLOR_SENTINEL:
			ignored.append({"name": "fog_light_color", "reason": "could not parse '%s' as a color" % str(args["fog_light_color"])})
		else:
			env.fog_light_color = c
			applied.append("fog_light_color")
	if args.has("fog_density"):
		env.fog_density = ToolUtils.parse_float_arg(args, "fog_density", env.fog_density)
		applied.append("fog_density")

	# ── Post-processing ───────────────────────────────────────────────────
	if args.has("tonemap_mode"):
		var tm: String = ToolUtils.parse_string_arg(args, "tonemap_mode").to_lower()
		var tm_id: int = _resolve_tonemap(tm)
		if tm_id >= 0:
			env.tonemap_mode = tm_id
			applied.append("tonemap_mode")
		else:
			ignored.append({"name": "tonemap_mode", "reason": "unknown value '%s' (use one of: %s)" % [tm, ", ".join(_TONEMAPS)]})
	if args.has("tonemap_exposure"):
		env.tonemap_exposure = ToolUtils.parse_float_arg(args, "tonemap_exposure", env.tonemap_exposure)
		applied.append("tonemap_exposure")
	if args.has("glow_enabled"):
		env.glow_enabled = ToolUtils.parse_bool_arg(args, "glow_enabled", env.glow_enabled)
		applied.append("glow_enabled")
	if args.has("ssao_enabled"):
		env.ssao_enabled = ToolUtils.parse_bool_arg(args, "ssao_enabled", env.ssao_enabled)
		applied.append("ssao_enabled")

	# ── Sky scaffold ──────────────────────────────────────────────────────
	# Auto-create a procedural sky when (a) the agent asked for it, OR
	# (b) background_mode is now BG_SKY and no sky is currently assigned.
	# This is the "make it daytime" one-shot — without it, BG_SKY with a
	# null sky renders pitch black and the agent has to chain create_resource
	# calls to fix it.
	var auto_sky: bool = ToolUtils.parse_bool_arg(args, "procedural_sky", false)
	if not auto_sky and env.background_mode == _resolve_background_mode("sky") and env.sky == null:
		auto_sky = true
	if auto_sky and env.sky == null:
		var sky := Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky
		applied.append("procedural_sky")

	# Mark scene dirty so saves pick this up. EditorInterface.mark_scene_as_unsaved
	# would be ideal but isn't part of Godot 4's public API; the assignment
	# itself dirties via Resource.changed, but explicit notification keeps
	# the dock badge in sync on older builds.
	if Engine.is_editor_hint():
		EditorInterface.get_edited_scene_root().notify_property_list_changed()

	var msg := "WorldEnvironment %s; %d propert%s applied" % [
		"created" if created_we else "updated",
		applied.size(),
		"y" if applied.size() == 1 else "ies",
	]
	return ToolUtils.success(msg, {
		"world_environment_path": ToolUtils.node_relative_path(we),
		"environment_path": loaded_env_path if not loaded_env_path.is_empty() else "<inline>",
		"created_world_environment": created_we,
		"created_environment": created_env,
		"applied_properties": applied,
		"ignored_properties": ignored,
	})


# ── Enum resolvers ────────────────────────────────────────────────────────
# Match-statement helpers in lieu of const dicts (see _BACKGROUND_MODES note).
# Return -1 for unknown names so callers can distinguish "unknown" from a
# legitimate enum value of 0.
func _resolve_background_mode(name: String) -> int:
	match name:
		"clear_color": return Environment.BG_CLEAR_COLOR
		"color":       return Environment.BG_COLOR
		"sky":         return Environment.BG_SKY
		"canvas":      return Environment.BG_CANVAS
		"keep":        return Environment.BG_KEEP
		_:             return -1


func _resolve_ambient_source(name: String) -> int:
	match name:
		"background": return Environment.AMBIENT_SOURCE_BG
		"disabled":   return Environment.AMBIENT_SOURCE_DISABLED
		"color":      return Environment.AMBIENT_SOURCE_COLOR
		"sky":        return Environment.AMBIENT_SOURCE_SKY
		_:            return -1


func _resolve_tonemap(name: String) -> int:
	# Accept both "reinhardt" (Godot's spelling — the engine's enum name is
	# TONE_MAPPER_REINHARDT) and "reinhard" (the actual mathematician's name,
	# which most CG references use). The Godot API is authoritative for the
	# enum but we forgive both inputs.
	match name:
		"linear":             return Environment.TONE_MAPPER_LINEAR
		"reinhardt", "reinhard": return Environment.TONE_MAPPER_REINHARDT
		"filmic":             return Environment.TONE_MAPPER_FILMIC
		"aces":               return Environment.TONE_MAPPER_ACES
		_:                    return -1


# Walks the edited scene for the first WorldEnvironment node. Most scenes
# have exactly one; if a project has multiple we take the first found in
# preorder (deterministic on subsequent calls).
func _find_world_environment(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root
	for child in root.get_children():
		var found := _find_world_environment(child)
		if found != null:
			return found
	return null


# Transparent-magenta sentinel used to distinguish "unparseable color" from
# a legitimate transparent or white value. No real caller would supply this.
const _COLOR_SENTINEL := Color(1.0, 0.0, 1.0, 0.0)
