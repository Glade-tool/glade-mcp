extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a camera node in either 3D or 2D, picked by the `space` arg — one
# tool covers both, matching the create_physics_body / create_light convention.
# (Formerly create_camera_3d; that name still dispatches here as a registry
# alias for backward compatibility.)
#
#   space="3d" (default) → Camera3D (perspective, fov)
#   space="2d"           → Camera2D (zoom, viewport follow)
#
# Args:
#   space:       "2d" | "3d". When omitted, inferred from the open scene's root
#                node (Node2D root → "2d", Node3D root → "3d"); falls back to
#                "3d" for an ambiguous/empty scene. Pass explicitly to override.
#   name:        String — node name. Default: "Camera3D" / "Camera2D".
#   parent_path: String — scene-relative parent. Default: scene root.
#   current:     bool — make this the active camera. Default: false. In 2D this
#                       enables the camera and calls make_current(); current=false
#                       leaves it disabled (present but not driving the viewport),
#                       mirroring the 3D "created but not active" default.
#   position:    "x,y,z" (3D, default 0,0,5) / "x,y" (2D, default 0,0).
#   fov:         float — field of view in degrees (3D only). Default: 75.
#   look_at:     "x,y,z" — optional point to orient toward (3D only).
#   zoom:        float | "x,y" — Camera2D zoom (2D only). >1 zooms IN. Default: 1.
#
# Response payload:
#   node_path, type ("Camera2D"|"Camera3D"), space ("2d"|"3d"), current (bool)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_camera"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	# space is inferred from the open scene's root when not passed explicitly,
	# so a Camera2D is created automatically in a 2D scene.
	var space: String = ToolUtils.resolve_space(args)
	if space != "2d" and space != "3d":
		return ToolUtils.error_with_solutions(
			"Unknown space '%s'" % space,
			["Use space='3d' for a Camera3D", "Use space='2d' for a Camera2D (platformers, top-down)"]
		)
	var is_2d: bool = space == "2d"

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var make_current: bool = ToolUtils.parse_bool_arg(args, "current", false)
	return _execute_2d(args, root, parent, make_current) if is_2d else _execute_3d(args, root, parent, make_current)


func _execute_3d(args: Dictionary, root: Node, parent: Node, make_current: bool) -> Dictionary:
	var cam := Camera3D.new()
	cam.name = ToolUtils.parse_string_arg(args, "name", "Camera3D")
	cam.fov = ToolUtils.parse_float_arg(args, "fov", 75.0)

	parent.add_child(cam)
	cam.owner = root
	cam.position = ToolUtils.parse_vector3_arg(args, "position", Vector3(0, 0, 5))

	if args.has("look_at"):
		var target: Vector3 = ToolUtils.parse_vector3_arg(args, "look_at", Vector3.ZERO)
		# look_at requires the node in-tree (it is) and a non-coincident target.
		if not target.is_equal_approx(cam.global_position):
			cam.look_at(target, Vector3.UP)

	if make_current:
		cam.current = true

	return ToolUtils.success("Created Camera3D '%s'" % cam.name, {
		"node_path": ToolUtils.node_relative_path(cam),
		"type": "Camera3D",
		"space": "3d",
		"current": cam.current,
	})


func _execute_2d(args: Dictionary, root: Node, parent: Node, make_current: bool) -> Dictionary:
	var cam := Camera2D.new()
	cam.name = ToolUtils.parse_string_arg(args, "name", "Camera2D")
	cam.zoom = _parse_zoom(args)

	parent.add_child(cam)
	cam.owner = root
	cam.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	# Camera2D drives the viewport via `enabled` (+ make_current to win over any
	# other enabled cameras). Leave it disabled when not requested current, so
	# it matches the 3D "created but not active" default rather than silently
	# hijacking the view.
	cam.enabled = make_current
	if make_current:
		cam.make_current()

	return ToolUtils.success("Created Camera2D '%s'" % cam.name, {
		"node_path": ToolUtils.node_relative_path(cam),
		"type": "Camera2D",
		"space": "2d",
		"current": cam.enabled,
	})


# Camera2D.zoom is a Vector2. Accept a scalar (uniform zoom) or an "x,y" pair.
func _parse_zoom(args: Dictionary) -> Vector2:
	if not args.has("zoom"):
		return Vector2.ONE
	var v = args["zoom"]
	if v is int or v is float:
		var f := float(v)
		return Vector2(f, f) if f > 0.0 else Vector2.ONE
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_valid_float():
			var f2 := float(s)
			return Vector2(f2, f2) if f2 > 0.0 else Vector2.ONE
	var z := ToolUtils.parse_vector2_arg(args, "zoom", Vector2.ONE)
	# Guard against a 0,0 zoom (renders nothing).
	if z.x <= 0.0 or z.y <= 0.0:
		return Vector2.ONE
	return z
