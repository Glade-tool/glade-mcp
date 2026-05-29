extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a Camera3D node and adds it to the edited scene.
#
# Args:
#   name:        String — node name. Default: "Camera3D".
#   parent_path: String — scene-relative path to parent. Default: scene root.
#   current:     bool   — if true, makes this the active camera. Default: false.
#   fov:         float  — field of view in degrees (perspective only). Default: 75.
#   position:    "x,y,z" | array | dict — initial position. Default: 0,0,5.
#   look_at:     "x,y,z" | array | dict — optional point to orient toward.
#
# Response payload:
#   node_path, type ("Camera3D"), current (echoed)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_camera_3d"
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

	var cam := Camera3D.new()
	cam.name = ToolUtils.parse_string_arg(args, "name", "Camera3D")
	cam.fov = ToolUtils.parse_float_arg(args, "fov", 75.0)

	parent.add_child(cam)
	cam.owner = root

	var pos: Vector3 = ToolUtils.parse_vector3_arg(args, "position", Vector3(0, 0, 5))
	cam.position = pos

	if args.has("look_at"):
		var target: Vector3 = ToolUtils.parse_vector3_arg(args, "look_at", Vector3.ZERO)
		# look_at requires the node to be in the tree (it is) and the
		# target to be non-coincident with our position.
		if not target.is_equal_approx(cam.global_position):
			cam.look_at(target, Vector3.UP)

	var make_current: bool = ToolUtils.parse_bool_arg(args, "current", false)
	if make_current:
		cam.current = true

	return ToolUtils.success("Created Camera3D '%s'" % cam.name, {
		"node_path": ToolUtils.node_relative_path(cam),
		"type": "Camera3D",
		"current": cam.current,
	})
