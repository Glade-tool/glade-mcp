extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Removes a node from the edited scene. The scene root itself cannot be
# deleted (return an error).
#
# Args:
#   node_path: String (required) — scene-relative path of the node to delete.
#
# Response payload:
#   deleted_path: String — path of the deleted node (echoed for confirmation)
#   parent_path:  String — path of the (former) parent

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "delete_node"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)
	var root: Node = EditorInterface.get_edited_scene_root()
	if node == root:
		return ToolUtils.error("Cannot delete the scene root via delete_node; close or replace the scene instead")

	var parent: Node = node.get_parent()
	var parent_path: String = ToolUtils.node_relative_path(parent) if parent != null else ""

	var deleted_path: String = ToolUtils.node_relative_path(node)
	# free() (not queue_free, which is deferred) — for an editor-side mutation
	# we want the node gone immediately so subsequent tool calls in the same
	# dispatch tick see the new state. Deselect first so the scene-tree dock /
	# inspector never hold a freed node.
	ToolUtils.deselect_before_free(node)
	if parent != null:
		parent.remove_child(node)
	node.free()

	return ToolUtils.success("Deleted node '%s'" % deleted_path, {
		"deleted_path": deleted_path,
		"parent_path": parent_path,
	})
