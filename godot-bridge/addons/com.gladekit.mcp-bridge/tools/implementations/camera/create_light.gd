extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a Light3D node (DirectionalLight3D, OmniLight3D, or SpotLight3D)
# based on the `type` argument. Replaces the original plan's three
# separate tools per the Phase 3 catalog dedupe.
#
# Args:
#   type:        String — "directional" | "omni" | "spot". Default: "directional".
#   name:        String — node name. Default: derived from type.
#   parent_path: String — scene-relative parent path. Default: scene root.
#   energy:      float  — light energy multiplier. Default: 1.0.
#   color:       String "r,g,b" (0-1) or hex "#rrggbb". Default: white.
#   position:    "x,y,z" — initial position. Default: 0,3,0.
#   shadow:      bool   — enable shadow casting. Default: true.
#
# Response payload:
#   node_path, type (the actual Godot class), energy, color (echoed hex)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_light"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open",
			["Call open_scene first", "Or create_scene to scaffold a new one"]
		)

	var light_type: String = ToolUtils.parse_string_arg(args, "type", "directional").to_lower()
	var light: Light3D = _make_light(light_type)
	if light == null:
		return ToolUtils.error_with_solutions(
			"Unknown light type '%s'" % light_type,
			["Use type='directional' for sun-like lighting", "Use type='omni' for point lights", "Use type='spot' for cone lights"]
		)

	light.name = ToolUtils.parse_string_arg(args, "name", _default_name(light_type))
	light.light_energy = ToolUtils.parse_float_arg(args, "energy", 1.0)
	light.shadow_enabled = ToolUtils.parse_bool_arg(args, "shadow", true)

	var color = _parse_color(args)  # untyped: _parse_color returns Color or null
	if color != null:
		light.light_color = color

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)
	parent.add_child(light)
	light.owner = root

	var pos: Vector3 = ToolUtils.parse_vector3_arg(args, "position", Vector3(0, 3, 0))
	light.position = pos

	# Directional lights default to pointing straight down (Godot default
	# faces -Z); rotate to a sensible "sun at 45°" by default if user
	# didn't pass an explicit position.
	if light_type == "directional" and not args.has("rotation"):
		light.rotation_degrees = Vector3(-45, -30, 0)

	return ToolUtils.success("Created %s '%s'" % [light.get_class(), light.name], {
		"node_path": ToolUtils.node_relative_path(light),
		"type": light.get_class(),
		"energy": light.light_energy,
		"color": "#%02x%02x%02x" % [int(light.light_color.r * 255), int(light.light_color.g * 255), int(light.light_color.b * 255)],
	})


func _make_light(t: String) -> Light3D:
	match t:
		"directional", "sun":
			return DirectionalLight3D.new()
		"omni", "point":
			return OmniLight3D.new()
		"spot":
			return SpotLight3D.new()
		_:
			return null


func _default_name(t: String) -> String:
	match t:
		"directional", "sun":
			return "DirectionalLight3D"
		"omni", "point":
			return "OmniLight3D"
		"spot":
			return "SpotLight3D"
		_:
			return "Light3D"


# Returns a Color or null (caller leaves default if null).
func _parse_color(args: Dictionary):
	if not args.has("color"):
		return null
	var v = args["color"]
	if v == null:
		return null
	if v is Color:
		return v
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_empty():
			return null
		if s.begins_with("#"):
			return Color.html(s) if Color.html_is_valid(s) else null
		var parts: PackedStringArray = s.split(",", false)
		if parts.size() < 3:
			return null
		var r := float(parts[0]) if parts[0].is_valid_float() else 1.0
		var g := float(parts[1]) if parts[1].is_valid_float() else 1.0
		var b := float(parts[2]) if parts[2].is_valid_float() else 1.0
		return Color(r, g, b)
	return null
