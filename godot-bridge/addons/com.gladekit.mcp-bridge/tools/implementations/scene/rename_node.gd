extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Renames an existing node. Godot auto-uniquifies names within a parent (so
# "Player" may become "Player2" if the parent already has a "Player"); we
# echo the actual final name back to the caller.
#
# Args:
#   node_path: String (required) — scene-relative path of the target node.
#   new_name:  String (required) — desired new name. Must be non-empty.
#
# Response payload:
#   old_name:      String
#   new_name:      String   — actual name Godot settled on
#   new_node_path: String   — path under the same parent with new_name

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "rename_node"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in edited scene" % node_path)

	var new_name: String = ToolUtils.parse_string_arg(args, "new_name")
	if new_name.is_empty():
		return ToolUtils.error("new_name is required and must be non-empty")

	var old_name: String = String(node.name)
	node.name = new_name
	var actual_name: String = String(node.name)

	return ToolUtils.success("Renamed '%s' → '%s'" % [old_name, actual_name], {
		"old_name": old_name,
		"new_name": actual_name,
		"new_node_path": ToolUtils.node_relative_path(node),
	})
