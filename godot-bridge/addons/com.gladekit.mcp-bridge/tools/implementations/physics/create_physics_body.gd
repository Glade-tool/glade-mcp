extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a 3D physics body (StaticBody3D | RigidBody3D | CharacterBody3D)
# and optionally attaches a CollisionShape3D child. Folds the original
# `add_collision_shape` tool into this one per the Phase 3 catalog dedupe
# (Godot devs almost always want a body with a shape; making the user call
# two tools is friction).
#
# Args:
#   body_type:       "static" | "rigid" | "character". Default: "static".
#   name:            String — node name. Default: derived from body_type.
#   parent_path:     String — scene-relative parent. Default: scene root.
#   position:        "x,y,z" — initial position. Default: 0,0,0.
#   auto_shape:      bool — when true, adds a CollisionShape3D child with
#                          a default shape. Default: true.
#   shape_type:      "box" | "sphere" | "capsule" | "cylinder". Default: "box".
#   shape_size:      "x,y,z" — for box: extents. For sphere/capsule: x=radius,
#                              y=height. Default: 1,1,1.
#   mass:            float (rigid only) — default 1.0.
#
# Response payload:
#   node_path, type (body class), collision_shape_path (if auto_shape)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_physics_body"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene currently open")

	var body_type: String = ToolUtils.parse_string_arg(args, "body_type", "static").to_lower()
	var body: Node3D = _make_body(body_type)
	if body == null:
		return ToolUtils.error_with_solutions(
			"Unknown body_type '%s'" % body_type,
			["Use body_type='static' for unmoving level geometry", "Use body_type='rigid' for physics-simulated objects", "Use body_type='character' for player-controlled bodies"]
		)

	body.name = ToolUtils.parse_string_arg(args, "name", _default_name(body_type))

	if body is RigidBody3D:
		(body as RigidBody3D).mass = ToolUtils.parse_float_arg(args, "mass", 1.0)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)
	parent.add_child(body)
	body.owner = root
	body.position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	var collision_shape_path := ""
	var auto_shape: bool = ToolUtils.parse_bool_arg(args, "auto_shape", true)
	if auto_shape:
		var shape_node := _make_collision_shape(args)
		if shape_node == null:
			return ToolUtils.error_with_solutions(
				"Unknown shape_type '%s'" % ToolUtils.parse_string_arg(args, "shape_type", "box"),
				["Use shape_type='box' | 'sphere' | 'capsule' | 'cylinder'", "Or pass auto_shape=false to skip and add shapes manually later"]
			)
		body.add_child(shape_node)
		shape_node.owner = root
		collision_shape_path = ToolUtils.node_relative_path(shape_node)

	return ToolUtils.success("Created %s '%s'" % [body.get_class(), body.name], {
		"node_path": ToolUtils.node_relative_path(body),
		"type": body.get_class(),
		"collision_shape_path": collision_shape_path,
	})


func _make_body(t: String) -> Node3D:
	match t:
		"static":
			return StaticBody3D.new()
		"rigid", "rigidbody", "dynamic":
			return RigidBody3D.new()
		"character", "characterbody":
			return CharacterBody3D.new()
		_:
			return null


func _default_name(t: String) -> String:
	match t:
		"static":
			return "StaticBody3D"
		"rigid", "rigidbody", "dynamic":
			return "RigidBody3D"
		"character", "characterbody":
			return "CharacterBody3D"
		_:
			return "PhysicsBody3D"


func _make_collision_shape(args: Dictionary) -> CollisionShape3D:
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
