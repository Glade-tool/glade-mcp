extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a Parallax2D (Godot 4.3+, the node that replaced ParallaxBackground +
# ParallaxLayer) for depth-scrolling 2D backgrounds. A `scroll_scale` below 1
# makes the layer move slower than the camera — the classic distant-background
# effect. Optionally drops a Sprite2D child with your background image and sets
# `repeat_size` so it tiles seamlessly as the camera moves.
#
# Args:
#   name:        String — node name. Default: "Parallax2D".
#   parent_path: String — scene-relative parent. Default: scene root.
#   scroll_scale: float | "x,y" — how fast the layer scrolls relative to the
#                         camera. <1 = further away / slower. Default: 0.5.
#   texture:     String — res:// background image. Optional; when given, a
#                         centered Sprite2D child is added.
#   repeat_size: "x,y" — size in pixels at which the layer repeats (seamless
#                         tiling). Default: the texture's size when a texture is
#                         given (so it tiles), else "0,0" (no repeat).
#   position:    "x,y" — initial position. Default: 0,0.
#
# Response payload:
#   node_path, type ("Parallax2D"), scroll_scale ("x,y"), sprite_path (the
#   child Sprite2D path, or "" when no texture was given)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_parallax_2d"
	requires_edit_mode = true
	min_godot_version = "4.3"


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var layer := Parallax2D.new()
	layer.name = ToolUtils.parse_string_arg(args, "name", "Parallax2D")
	layer.scroll_scale = _parse_scale(args)

	# Optional background sprite child.
	var sprite: Sprite2D = null
	var tex_path: String = ToolUtils.parse_path_arg(args, "texture")
	if not tex_path.is_empty():
		if not ResourceLoader.exists(tex_path):
			layer.free()
			return ToolUtils.error_with_solutions(
				"Texture '%s' not found" % tex_path,
				["Pass a res:// path to an imported background image", "Or omit `texture` and add the Sprite2D child later"]
			)
		var loaded = load(tex_path)
		if not (loaded is Texture2D):
			layer.free()
			return ToolUtils.error("'%s' did not load as a Texture2D" % tex_path)
		sprite = Sprite2D.new()
		sprite.texture = loaded
		sprite.name = "Background"
		sprite.centered = false

	parent.add_child(layer)
	layer.owner = root
	layer.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	if sprite != null:
		layer.add_child(sprite)
		sprite.owner = root

	# repeat_size: explicit arg wins; otherwise default to the texture size so a
	# single image tiles seamlessly across the viewport.
	if args.has("repeat_size"):
		layer.repeat_size = ToolUtils.parse_vector2_arg(args, "repeat_size", Vector2.ZERO)
	elif sprite != null and sprite.texture != null:
		layer.repeat_size = sprite.texture.get_size()

	return ToolUtils.success("Created Parallax2D '%s'" % layer.name, {
		"node_path": ToolUtils.node_relative_path(layer),
		"type": "Parallax2D",
		"scroll_scale": "%s,%s" % [layer.scroll_scale.x, layer.scroll_scale.y],
		"sprite_path": ToolUtils.node_relative_path(sprite) if sprite != null else "",
	})


# scroll_scale accepts a scalar (uniform) or an "x,y" pair.
func _parse_scale(args: Dictionary) -> Vector2:
	if not args.has("scroll_scale"):
		return Vector2(0.5, 0.5)
	var v = args["scroll_scale"]
	if v is int or v is float:
		var f := float(v)
		return Vector2(f, f)
	if v is String and (v as String).strip_edges().is_valid_float():
		var f2 := float(v)
		return Vector2(f2, f2)
	return ToolUtils.parse_vector2_arg(args, "scroll_scale", Vector2(0.5, 0.5))
