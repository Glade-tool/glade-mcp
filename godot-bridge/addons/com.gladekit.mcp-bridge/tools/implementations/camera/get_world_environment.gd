extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reads the scene's WorldEnvironment + Environment state — sky, ambient,
# fog, tonemap, glow, ssao. Pairs with set_world_environment for "make it
# slightly more X" workflows where the agent needs current values first.
#
# Read-only — safe during play mode.
#
# Response payload:
#   has_world_environment: bool — true if a WorldEnvironment node exists
#   world_environment_path: String — scene-relative path (empty if none)
#   has_environment: bool — true if a WorldEnvironment exists AND has an
#                           Environment resource assigned
#   environment_resource_path: String — res:// path if loaded from a .tres,
#                                       "<inline>" if attached inline, "" if none
#   has_sky: bool
#   background_mode, background_color
#   ambient_light_source, ambient_light_color, ambient_light_energy
#   fog_enabled, fog_light_color, fog_density
#   tonemap_mode, tonemap_exposure
#   glow_enabled, ssao_enabled

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Enum-int → name converters live in match-statement helpers below. Const
# dicts whose values are built-in-class enum constants (Environment.BG_*,
# Environment.TONE_MAPPER_*, …) silently fail to parse in Godot 4 — the
# parser does not treat them as constant expressions, the preload returns
# null, and the bridge's tool registry silently drops every tool registered
# after this one. See the matching note in set_world_environment.gd.


func _init() -> void:
	tool_name = "get_world_environment"
	requires_edit_mode = false


func execute(_args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene is currently open")

	var we: WorldEnvironment = _find_world_environment(root)
	if we == null:
		return ToolUtils.success("No WorldEnvironment in the edited scene", {
			"has_world_environment": false,
			"world_environment_path": "",
			"has_environment": false,
			"environment_resource_path": "",
			"has_sky": false,
		})

	var info: Dictionary = {
		"has_world_environment": true,
		"world_environment_path": ToolUtils.node_relative_path(we),
		"has_environment": we.environment != null,
		"environment_resource_path": "",
		"has_sky": false,
	}

	if we.environment == null:
		return ToolUtils.success("WorldEnvironment present but no Environment resource attached", info)

	var env: Environment = we.environment
	info["environment_resource_path"] = env.resource_path if not env.resource_path.is_empty() else "<inline>"
	info["has_sky"] = env.sky != null
	info["background_mode"] = _background_mode_name(env.background_mode)
	info["background_color"] = _color_to_hex(env.background_color)
	info["ambient_light_source"] = _ambient_source_name(env.ambient_light_source)
	info["ambient_light_color"] = _color_to_hex(env.ambient_light_color)
	info["ambient_light_energy"] = env.ambient_light_energy
	info["fog_enabled"] = env.fog_enabled
	info["fog_light_color"] = _color_to_hex(env.fog_light_color)
	info["fog_density"] = env.fog_density
	info["tonemap_mode"] = _tonemap_name(env.tonemap_mode)
	info["tonemap_exposure"] = env.tonemap_exposure
	info["glow_enabled"] = env.glow_enabled
	info["ssao_enabled"] = env.ssao_enabled

	return ToolUtils.success("Read WorldEnvironment state", info)


# ── Enum int → name resolvers (match in lieu of const dicts) ──────────────
func _background_mode_name(mode: int) -> String:
	match mode:
		Environment.BG_CLEAR_COLOR: return "clear_color"
		Environment.BG_COLOR:       return "color"
		Environment.BG_SKY:         return "sky"
		Environment.BG_CANVAS:      return "canvas"
		Environment.BG_KEEP:        return "keep"
		_:                          return str(mode)


func _ambient_source_name(source: int) -> String:
	match source:
		Environment.AMBIENT_SOURCE_BG:       return "background"
		Environment.AMBIENT_SOURCE_DISABLED: return "disabled"
		Environment.AMBIENT_SOURCE_COLOR:    return "color"
		Environment.AMBIENT_SOURCE_SKY:      return "sky"
		_:                                   return str(source)


func _tonemap_name(mode: int) -> String:
	# Returns Godot's authoritative spelling ("reinhardt"). set_world_environment
	# accepts both "reinhardt" and "reinhard" on the way in.
	match mode:
		Environment.TONE_MAPPER_LINEAR:    return "linear"
		Environment.TONE_MAPPER_REINHARDT: return "reinhardt"
		Environment.TONE_MAPPER_FILMIC:    return "filmic"
		Environment.TONE_MAPPER_ACES:      return "aces"
		_:                                 return str(mode)


func _find_world_environment(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root
	for child in root.get_children():
		var found := _find_world_environment(child)
		if found != null:
			return found
	return null


func _color_to_hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]
