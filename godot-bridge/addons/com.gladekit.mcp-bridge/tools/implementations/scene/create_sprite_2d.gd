extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a Sprite2D and (optionally) assigns its texture in one call — the 2D
# analogue of create_primitive_3d. A Sprite2D is the workhorse node for static
# 2D images (player, props, backgrounds, tiles-as-sprites). This bundles node
# creation + texture assignment + framing so an agent doesn't have to chain
# create_node + set_node_resource and risk leaving an invisible empty sprite.
#
# Args:
#   texture:     String — res:// path to the image (png/webp/svg/…). Optional:
#                         an empty Sprite2D is valid (texture assigned later),
#                         but a sprite with no texture is invisible.
#   name:        String — node name. Default: derived from the texture filename,
#                         else "Sprite2D".
#   parent_path: String — scene-relative parent. Default: scene root.
#   position:    "x,y" — initial position in pixels. Default: 0,0.
#   centered:    bool  — whether the texture is centred on the node origin.
#                        Default: true (Godot's default).
#   modulate:    "r,g,b[,a]" | "#rrggbb[aa]" — tint color. Default: white.
#   hframes:     int — horizontal frames for a spritesheet. Default: 1.
#   vframes:     int — vertical frames for a spritesheet. Default: 1.
#   frame:       int — which frame to show (0-based) when h/vframes > 1.
#
# Response payload:
#   node_path, type ("Sprite2D"), texture (echoed path or "")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_sprite_2d"
	requires_edit_mode = true


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

	var sprite := Sprite2D.new()

	var tex_path: String = ToolUtils.parse_path_arg(args, "texture")
	var assigned_texture := ""
	if not tex_path.is_empty():
		if not ResourceLoader.exists(tex_path):
			sprite.free()
			return ToolUtils.error_with_solutions(
				"Texture '%s' not found" % tex_path,
				["Pass a res:// path to an imported image", "Or omit `texture` and assign it later with set_node_resource"]
			)
		var loaded = load(tex_path)
		if not (loaded is Texture2D):
			sprite.free()
			return ToolUtils.error("'%s' did not load as a Texture2D" % tex_path)
		sprite.texture = loaded
		assigned_texture = tex_path

	var default_name := tex_path.get_file().get_basename() if not tex_path.is_empty() else "Sprite2D"
	sprite.name = ToolUtils.parse_string_arg(args, "name", default_name)
	sprite.centered = ToolUtils.parse_bool_arg(args, "centered", true)

	var hframes: int = max(1, ToolUtils.parse_int_arg(args, "hframes", 1))
	var vframes: int = max(1, ToolUtils.parse_int_arg(args, "vframes", 1))
	sprite.hframes = hframes
	sprite.vframes = vframes
	if args.has("frame"):
		sprite.frame = clampi(ToolUtils.parse_int_arg(args, "frame", 0), 0, hframes * vframes - 1)

	if args.has("modulate"):
		sprite.modulate = ToolUtils.parse_color_arg(args.get("modulate"), Color.WHITE)

	parent.add_child(sprite)
	sprite.owner = root
	sprite.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	var extras := {
		"node_path": ToolUtils.node_relative_path(sprite),
		"type": "Sprite2D",
		"texture": assigned_texture,
	}
	var hint := ToolUtils.dimension_mismatch_note("2d", "create_primitive_3d (MeshInstance3D) for a 3D scene")
	if not hint.is_empty():
		extras["hint"] = hint

	return ToolUtils.success("Created Sprite2D '%s'" % sprite.name, extras)
