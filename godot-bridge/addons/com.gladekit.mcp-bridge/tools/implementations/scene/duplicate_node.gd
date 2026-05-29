extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Duplicates a node (and its full subtree) under the same parent. Children
# are recursively included; scripts and resources are duplicated by
# reference (Godot's default Node.duplicate behavior).
#
# Args:
#   node_path: String (required) — scene-relative path of the source node.
#   new_name:  String — name for the duplicate. If omitted, Godot picks
#              one (typically "<name>2", "<name>3", ...).
#
# Response payload:
#   source_path:    String
#   duplicate_path: String

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "duplicate_node"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var source: Node = ToolUtils.find_node_by_path(node_path)
	if source == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)
	var root: Node = EditorInterface.get_edited_scene_root()
	if source == root:
		return ToolUtils.error("Cannot duplicate the scene root via duplicate_node")
	var parent: Node = source.get_parent()
	if parent == null:
		return ToolUtils.error("Node '%s' has no parent (cannot duplicate orphan)" % node_path)

	var copy: Node = source.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SIGNALS | Node.DUPLICATE_SCRIPTS)
	var requested_name: String = ToolUtils.parse_string_arg(args, "new_name")
	if not requested_name.is_empty():
		copy.name = requested_name

	parent.add_child(copy)
	# Set owner on the duplicate AND all its descendants so the entire subtree
	# saves with the scene.
	_set_owner_recursive(copy, root)

	return ToolUtils.success("Duplicated '%s' → '%s'" % [node_path, String(copy.name)], {
		"source_path": node_path,
		"duplicate_path": ToolUtils.node_relative_path(copy),
	})


func _set_owner_recursive(node: Node, owner_root: Node) -> void:
	if node != owner_root:
		node.owner = owner_root
	for child in node.get_children():
		_set_owner_recursive(child, owner_root)
