extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Convenience: creates a MeshInstance3D with a built-in primitive mesh.
# Equivalent to Unity's create_primitive but for Godot's resource model
# (MeshInstance3D node + PrimitiveMesh resource).
#
# Args:
#   primitive:   String — "box" | "sphere" | "cylinder" | "capsule" | "plane" |
#                "prism" | "torus" | "quad". Default: "box".
#   name:        String — node name. Default: <Primitive>.
#   parent_path: String — scene-relative path to parent. Default: scene root.
#
# Response payload:
#   node_path: String
#   type:      "MeshInstance3D"
#   mesh_type: String — the PrimitiveMesh subclass actually used

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_primitive_3d"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var primitive: String = ToolUtils.parse_string_arg(args, "primitive", "box").to_lower()
	var mesh: PrimitiveMesh = _make_mesh(primitive)
	if mesh == null:
		return ToolUtils.error(
			"Unknown primitive '%s' (expected: box, sphere, cylinder, capsule, plane, prism, torus, quad)" % primitive
		)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene is currently open in the editor")

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent node '%s' not found" % parent_path)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	var default_name: String = primitive.capitalize()
	mesh_instance.name = ToolUtils.parse_string_arg(args, "name", default_name)

	parent.add_child(mesh_instance)
	mesh_instance.owner = root

	var extras := {
		"node_path": ToolUtils.node_relative_path(mesh_instance),
		"type": "MeshInstance3D",
		"mesh_type": mesh.get_class(),
	}
	# Self-correcting hint if a 3D mesh was dropped into a 2D scene.
	var hint := ToolUtils.dimension_mismatch_note("3d", "create_sprite_2d (Sprite2D) or create_primitive_3d only in a 3D scene")
	if not hint.is_empty():
		extras["hint"] = hint

	return ToolUtils.success("Created %s primitive '%s'" % [primitive, mesh_instance.name], extras)


func _make_mesh(primitive: String) -> PrimitiveMesh:
	match primitive:
		"box", "cube":
			return BoxMesh.new()
		"sphere":
			return SphereMesh.new()
		"cylinder":
			return CylinderMesh.new()
		"capsule":
			return CapsuleMesh.new()
		"plane":
			return PlaneMesh.new()
		"prism":
			return PrismMesh.new()
		"torus":
			return TorusMesh.new()
		"quad":
			return QuadMesh.new()
		_:
			return null
