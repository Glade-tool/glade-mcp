extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a physics body (StaticBody | RigidBody | CharacterBody) in either 3D
# or 2D and optionally attaches a matching CollisionShape child. Folds the
# original `add_collision_shape` tool into this one per the Phase 3 catalog
# dedupe (devs almost always want a body with a shape; making the user call two
# tools is friction). The `space` arg picks the dimension — one tool covers both
# 3D level geometry/props and 2D platformer/top-down bodies.
#
# Args:
#   space:           "3d" (default) | "2d" — picks Node3D vs Node2D node family.
#   body_type:       "static" | "rigid" | "character". Default: "static".
#   name:            String — node name. Default: derived from body_type + space.
#   parent_path:     String — scene-relative parent. Default: scene root.
#   position:        "x,y,z" (3D) / "x,y" (2D) — initial position. Default: 0.
#   auto_shape:      bool — when true, adds a CollisionShape child with a default
#                          shape. Default: true.
#   shape_type:      3D: "box" | "sphere" | "capsule" | "cylinder".
#                    2D: "box"/"rect" | "circle" | "capsule".
#                    Default: "box".
#   shape_size:      3D: "x,y,z" — box extents; sphere/capsule/cylinder use
#                        x=radius, y=height. Default: 1,1,1 (metres).
#                    2D: "x,y" — rect size; circle/capsule use x=radius,
#                        y=height. Default: 32,32 (pixels).
#   mass:            float (rigid only) — default 1.0.
#
# Response payload:
#   node_path, type (body class), space ("2d"|"3d"),
#   collision_shape_path (if auto_shape)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# 2D collision shapes default to 32px (a common sprite/tile size) — a 1px shape
# (the 3D default of 1 unit) would be invisible and useless in a 2D scene.
const _DEFAULT_2D_SIZE := Vector2(32, 32)


func _init() -> void:
	tool_name = "create_physics_body"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene currently open")

	var space: String = ToolUtils.parse_string_arg(args, "space", "3d").to_lower()
	var is_2d: bool = space == "2d" or space == "2"
	if not is_2d and space != "3d" and space != "3" and not space.is_empty():
		return ToolUtils.error_with_solutions(
			"Unknown space '%s'" % space,
			["Use space='3d' (default) for Node3D bodies", "Use space='2d' for Node2D bodies (platformers, top-down)"]
		)

	var body_type: String = ToolUtils.parse_string_arg(args, "body_type", "static").to_lower()
	var body: Node = _make_body_2d(body_type) if is_2d else _make_body_3d(body_type)
	if body == null:
		return ToolUtils.error_with_solutions(
			"Unknown body_type '%s'" % body_type,
			["Use body_type='static' for unmoving level geometry", "Use body_type='rigid' for physics-simulated objects", "Use body_type='character' for player-controlled bodies"]
		)

	body.name = ToolUtils.parse_string_arg(args, "name", _default_name(body_type, is_2d))

	if body is RigidBody3D:
		(body as RigidBody3D).mass = ToolUtils.parse_float_arg(args, "mass", 1.0)
	elif body is RigidBody2D:
		(body as RigidBody2D).mass = ToolUtils.parse_float_arg(args, "mass", 1.0)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)
	parent.add_child(body)
	body.owner = root

	if is_2d:
		(body as Node2D).position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
	else:
		(body as Node3D).position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	var collision_shape_path := ""
	var auto_shape: bool = ToolUtils.parse_bool_arg(args, "auto_shape", true)
	if auto_shape:
		var shape_node: Node = _make_collision_shape_2d(args) if is_2d else _make_collision_shape_3d(args)
		if shape_node == null:
			var valid := "'box' | 'circle' | 'capsule'" if is_2d else "'box' | 'sphere' | 'capsule' | 'cylinder'"
			return ToolUtils.error_with_solutions(
				"Unknown shape_type '%s'" % ToolUtils.parse_string_arg(args, "shape_type", "box"),
				["Use shape_type=%s" % valid, "Or pass auto_shape=false to skip and add shapes manually later"]
			)
		body.add_child(shape_node)
		shape_node.owner = root
		collision_shape_path = ToolUtils.node_relative_path(shape_node)

	return ToolUtils.success("Created %s '%s'" % [body.get_class(), body.name], {
		"node_path": ToolUtils.node_relative_path(body),
		"type": body.get_class(),
		"space": "2d" if is_2d else "3d",
		"collision_shape_path": collision_shape_path,
	})


func _make_body_3d(t: String) -> Node3D:
	match t:
		"static":
			return StaticBody3D.new()
		"rigid", "rigidbody", "dynamic":
			return RigidBody3D.new()
		"character", "characterbody":
			return CharacterBody3D.new()
		_:
			return null


func _make_body_2d(t: String) -> Node2D:
	match t:
		"static":
			return StaticBody2D.new()
		"rigid", "rigidbody", "dynamic":
			return RigidBody2D.new()
		"character", "characterbody":
			return CharacterBody2D.new()
		_:
			return null


func _default_name(t: String, is_2d: bool) -> String:
	var suffix := "2D" if is_2d else "3D"
	match t:
		"static":
			return "StaticBody" + suffix
		"rigid", "rigidbody", "dynamic":
			return "RigidBody" + suffix
		"character", "characterbody":
			return "CharacterBody" + suffix
		_:
			return "PhysicsBody" + suffix


func _make_collision_shape_3d(args: Dictionary) -> CollisionShape3D:
	var shape_type: String = ToolUtils.parse_string_arg(args, "shape_type", "box").to_lower()
	var size: Vector3 = ToolUtils.parse_vector3_arg(args, "shape_size", Vector3.ONE)
	var shape: Shape3D = null
	match shape_type:
		"box":
			var box := BoxShape3D.new()
			box.size = size
			shape = box
		"sphere":
			var sph := SphereShape3D.new()
			sph.radius = max(size.x, 0.1)
			shape = sph
		"capsule":
			var cap := CapsuleShape3D.new()
			cap.radius = max(size.x, 0.1)
			cap.height = max(size.y, cap.radius * 2 + 0.1)
			shape = cap
		"cylinder":
			var cyl := CylinderShape3D.new()
			cyl.radius = max(size.x, 0.1)
			cyl.height = max(size.y, 0.1)
			shape = cyl
		_:
			return null
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.name = "CollisionShape3D"
	return cs


func _make_collision_shape_2d(args: Dictionary) -> CollisionShape2D:
	var shape_type: String = ToolUtils.parse_string_arg(args, "shape_type", "box").to_lower()
	var size: Vector2 = ToolUtils.parse_vector2_arg(args, "shape_size", _DEFAULT_2D_SIZE)
	var shape: Shape2D = null
	match shape_type:
		"box", "rect", "rectangle":
			var rect := RectangleShape2D.new()
			rect.size = size
			shape = rect
		"circle", "sphere":
			var circ := CircleShape2D.new()
			circ.radius = max(size.x, 0.5)
			shape = circ
		"capsule":
			var cap := CapsuleShape2D.new()
			cap.radius = max(size.x, 0.5)
			cap.height = max(size.y, cap.radius * 2 + 0.5)
			shape = cap
		_:
			return null
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.name = "CollisionShape2D"
	return cs
