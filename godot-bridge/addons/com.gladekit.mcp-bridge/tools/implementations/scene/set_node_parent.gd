extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reparents a node to a new parent within the edited scene.
#
# Args:
#   node_path:       String (required) — node to move.
#   new_parent_path: String (required) — destination parent. Empty/"." means
#                                       the scene root.
#   keep_transform:  bool — when true, preserves the node's global transform
#                    (only meaningful for Node3D/Node2D). Default true.
#
# Response payload:
#   old_parent_path: String
#   new_parent_path: String
#   node_path:       String — node's path after the move

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "set_node_parent"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	if not args.has("new_parent_path"):
		return ToolUtils.error("new_parent_path is required")

	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	var new_parent_path: String = ToolUtils.parse_string_arg(args, "new_parent_path")
	var new_parent: Node = ToolUtils.find_node_by_path(new_parent_path)
	if new_parent == null:
		return ToolUtils.error("New parent '%s' not found" % new_parent_path)

	if node == new_parent:
		return ToolUtils.error("A node cannot be its own parent")
	if _is_ancestor(node, new_parent):
		return ToolUtils.error("Cannot reparent '%s' under its own descendant" % node_path)

	var keep_transform: bool = ToolUtils.parse_bool_arg(args, "keep_transform", true)
	var root: Node = EditorInterface.get_edited_scene_root()
	if node == root:
		return ToolUtils.error("Cannot reparent the scene root")

	var old_parent: Node = node.get_parent()
	var old_parent_path: String = ToolUtils.node_relative_path(old_parent) if old_parent != null else ""

	# Capture global transform before move if we need to preserve it.
	var preserved_global_3d: Transform3D
	var preserved_global_2d: Transform2D
	var is_3d := node is Node3D
	var is_2d := node is Node2D
	if keep_transform:
		if is_3d:
			preserved_global_3d = (node as Node3D).global_transform
		elif is_2d:
			preserved_global_2d = (node as Node2D).global_transform

	if old_parent != null:
		old_parent.remove_child(node)
	new_parent.add_child(node)
	node.owner = root

	if keep_transform:
		if is_3d:
			(node as Node3D).global_transform = preserved_global_3d
		elif is_2d:
			(node as Node2D).global_transform = preserved_global_2d

	return ToolUtils.success("Reparented '%s' → '%s'" % [String(node.name), new_parent_path], {
		"old_parent_path": old_parent_path,
		"new_parent_path": new_parent_path,
		"node_path": ToolUtils.node_relative_path(node),
	})


func _is_ancestor(potential_ancestor: Node, descendant: Node) -> bool:
	var cur: Node = descendant.get_parent()
	while cur != null:
		if cur == potential_ancestor:
			return true
		cur = cur.get_parent()
	return false
