extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a light node in either 3D or 2D, picked by the `space` arg — one tool
# covers both light families the same way create_physics_body covers both body
# families.
#
#   space="3d" (default):
#     type "directional" → DirectionalLight3D (sun)
#     type "omni"        → OmniLight3D (point)
#     type "spot"        → SpotLight3D (cone)
#   space="2d":
#     type "point"       → PointLight2D
#     type "directional" → DirectionalLight2D
#     type "ambient"     → CanvasModulate (scene-wide tint; the 2D analogue of
#                          an ambient/environment color)
#
# 2D gotcha handled here: a PointLight2D with no `texture` emits NOTHING — the
# texture defines the light's falloff shape. We generate a soft radial
# GradientTexture2D by default so the light works out of the box; pass a
# `texture` res:// path to override. CanvasModulate has no position/energy/
# shadow — it just tints; only `color` applies.
#
# Args:
#   space:       "2d" | "3d". When omitted, inferred from the open scene's root
#                node (Node2D → "2d", Node3D → "3d"); falls back to "3d".
#   type:        see table above. Default: "directional".
#   name:        String — node name. Default: derived from the class.
#   parent_path: String — scene-relative parent path. Default: scene root.
#   energy:      float  — light energy multiplier (3D + Light2D). Default: 1.0.
#   color:       "r,g,b" (0-1) or "#rrggbb". Default: white.
#   position:    "x,y,z" (3D) / "x,y" (2D) — initial position. Default: sensible
#                per space. Ignored for CanvasModulate.
#   shadow:      bool   — enable shadow casting (3D + Light2D). Default: true 3D,
#                         false 2D (2D shadows need LightOccluder2D geometry to
#                         do anything, so we don't enable them blindly).
#   texture:     String — res:// path to a PointLight2D texture (2D point only);
#                         overrides the generated radial gradient.
#
# Response payload:
#   node_path, type (actual Godot class), space ("2d"|"3d"), energy, color (hex)

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

	# Inferred from the scene root when not passed, so 2D lights are created
	# automatically in a 2D scene.
	var space: String = ToolUtils.resolve_space(args)
	if space != "2d" and space != "3d":
		return ToolUtils.error_with_solutions(
			"Unknown space '%s'" % space,
			["Use space='3d' for Light3D nodes", "Use space='2d' for 2D lights (PointLight2D / DirectionalLight2D / CanvasModulate)"]
		)
	var is_2d: bool = space == "2d"

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	return _execute_2d(args, root, parent) if is_2d else _execute_3d(args, root, parent)


# ── 3D ─────────────────────────────────────────────────────────────────────

func _execute_3d(args: Dictionary, root: Node, parent: Node) -> Dictionary:
	var light_type: String = ToolUtils.parse_string_arg(args, "type", "directional").to_lower()
	var light: Light3D = _make_light_3d(light_type)
	if light == null:
		return ToolUtils.error_with_solutions(
			"Unknown 3D light type '%s'" % light_type,
			["Use type='directional' for sun-like lighting", "Use type='omni' for point lights", "Use type='spot' for cone lights"]
		)

	light.name = ToolUtils.parse_string_arg(args, "name", _default_name_3d(light_type))
	light.light_energy = ToolUtils.parse_float_arg(args, "energy", 1.0)
	light.shadow_enabled = ToolUtils.parse_bool_arg(args, "shadow", true)

	var color := ToolUtils.parse_color_arg(args.get("color"), light.light_color) if args.has("color") else light.light_color
	light.light_color = color

	parent.add_child(light)
	light.owner = root
	light.position = ToolUtils.parse_vector3_arg(args, "position", Vector3(0, 3, 0))

	# Directional lights default to pointing straight down (Godot default faces
	# -Z); rotate to a sensible "sun at 45°" unless the user set a rotation.
	if light_type == "directional" and not args.has("rotation"):
		light.rotation_degrees = Vector3(-45, -30, 0)

	return ToolUtils.success("Created %s '%s'" % [light.get_class(), light.name], {
		"node_path": ToolUtils.node_relative_path(light),
		"type": light.get_class(),
		"space": "3d",
		"energy": light.light_energy,
		"color": _hex(light.light_color),
	})


func _make_light_3d(t: String) -> Light3D:
	match t:
		"directional", "sun":
			return DirectionalLight3D.new()
		"omni", "point":
			return OmniLight3D.new()
		"spot":
			return SpotLight3D.new()
		_:
			return null


func _default_name_3d(t: String) -> String:
	match t:
		"directional", "sun":
			return "DirectionalLight3D"
		"omni", "point":
			return "OmniLight3D"
		"spot":
			return "SpotLight3D"
		_:
			return "Light3D"


# ── 2D ─────────────────────────────────────────────────────────────────────

func _execute_2d(args: Dictionary, root: Node, parent: Node) -> Dictionary:
	var light_type: String = ToolUtils.parse_string_arg(args, "type", "point").to_lower()

	# CanvasModulate is not a Light2D — it's a scene-wide tint node. Handle it
	# on its own path: only `color` applies.
	if light_type == "ambient" or light_type == "canvas_modulate" or light_type == "modulate":
		var cm := CanvasModulate.new()
		cm.name = ToolUtils.parse_string_arg(args, "name", "CanvasModulate")
		cm.color = ToolUtils.parse_color_arg(args.get("color"), Color.WHITE) if args.has("color") else Color.WHITE
		parent.add_child(cm)
		cm.owner = root
		return ToolUtils.success("Created CanvasModulate '%s'" % cm.name, {
			"node_path": ToolUtils.node_relative_path(cm),
			"type": "CanvasModulate",
			"space": "2d",
			"energy": 1.0,
			"color": _hex(cm.color),
		})

	var light: Light2D = _make_light_2d(light_type)
	if light == null:
		return ToolUtils.error_with_solutions(
			"Unknown 2D light type '%s'" % light_type,
			["Use type='point' for a PointLight2D", "Use type='directional' for a DirectionalLight2D", "Use type='ambient' for a scene-wide CanvasModulate tint"]
		)

	light.name = ToolUtils.parse_string_arg(args, "name", _default_name_2d(light_type))
	light.energy = ToolUtils.parse_float_arg(args, "energy", 1.0)
	# 2D shadows do nothing without LightOccluder2D geometry, so default off.
	light.shadow_enabled = ToolUtils.parse_bool_arg(args, "shadow", false)
	light.color = ToolUtils.parse_color_arg(args.get("color"), Color.WHITE) if args.has("color") else Color.WHITE

	# A PointLight2D needs a texture to emit anything. Use a caller-supplied
	# texture if given, otherwise generate a soft radial gradient so the light
	# is visible immediately.
	if light is PointLight2D:
		var pl := light as PointLight2D
		var tex_path: String = ToolUtils.parse_path_arg(args, "texture")
		if not tex_path.is_empty():
			var loaded = load(tex_path)
			if loaded is Texture2D:
				pl.texture = loaded
			else:
				return ToolUtils.error("texture '%s' did not load as a Texture2D" % tex_path)
		else:
			pl.texture = _default_radial_texture()

	parent.add_child(light)
	light.owner = root
	light.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	return ToolUtils.success("Created %s '%s'" % [light.get_class(), light.name], {
		"node_path": ToolUtils.node_relative_path(light),
		"type": light.get_class(),
		"space": "2d",
		"energy": light.energy,
		"color": _hex(light.color),
	})


func _make_light_2d(t: String) -> Light2D:
	match t:
		"point", "omni":
			return PointLight2D.new()
		"directional", "sun":
			return DirectionalLight2D.new()
		_:
			return null


func _default_name_2d(t: String) -> String:
	match t:
		"point", "omni":
			return "PointLight2D"
		"directional", "sun":
			return "DirectionalLight2D"
		_:
			return "Light2D"


# Build a soft white radial GradientTexture2D for PointLight2D — opaque at the
# centre, fully transparent at the edge. Without a texture a PointLight2D is a
# silent no-op, so this is the difference between "light works" and "nothing
# happened" for the default call.
func _default_radial_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_offset(0, 0.0)
	grad.set_color(0, Color(1, 1, 1, 1))
	grad.set_offset(1, 1.0)
	grad.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


# ── Shared ─────────────────────────────────────────────────────────────────

func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(c.r * 255), int(c.g * 255), int(c.b * 255)]
