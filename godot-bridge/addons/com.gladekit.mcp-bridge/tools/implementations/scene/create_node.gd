extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a new Node of the requested type and adds it to the edited scene.
#
# Args:
#   type:        String (required) — Godot class name (Node3D, CharacterBody3D,
#                                    Sprite2D, RigidBody3D, MeshInstance3D, ...).
#                                    Must be instantiable via ClassDB.
#   name:        String — name for the new node. Default: <type>.
#   parent_path: String — scene-relative path to parent node. Default: scene root.
#
# Response payload:
#   node_path: String — scene-relative path of the new node
#   type:      String — confirmed class

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_node"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var node_type: String = ToolUtils.parse_string_arg(args, "type")
	if node_type.is_empty():
		return ToolUtils.error("type is required (e.g. 'Node3D', 'CharacterBody3D', 'Sprite2D')")

	if not ClassDB.class_exists(node_type):
		return ToolUtils.error("Unknown Godot class '%s'" % node_type)
	if not ClassDB.can_instantiate(node_type):
		return ToolUtils.error("Class '%s' cannot be instantiated" % node_type)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error("No scene is currently open in the editor")

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent node '%s' not found" % parent_path)

	var instance = ClassDB.instantiate(node_type)
	if not (instance is Node):
		return ToolUtils.error("Class '%s' did not instantiate to a Node" % node_type)
	var node: Node = instance

	var node_name: String = ToolUtils.parse_string_arg(args, "name", node_type)
	node.name = node_name

	parent.add_child(node)
	# `owner` controls scene-save inclusion. Without this, the node won't
	# persist when the scene is saved.
	node.owner = root

	var path := ToolUtils.node_relative_path(node)
	return ToolUtils.success(
		"Created %s named '%s' under '%s'" % [node_type, node.name, (parent_path if not parent_path.is_empty() else String(root.name))],
		{
			"node_path": path,
			"type": node.get_class(),
		}
	)
