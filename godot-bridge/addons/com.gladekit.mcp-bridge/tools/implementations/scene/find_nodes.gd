extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Searches the edited scene for nodes matching the given filters.
# Read-only — safe during play mode.
#
# All filters are AND-combined. At least one of name_contains, name_exact,
# type, or group should be set; with none, returns every node (capped).
#
# Args:
#   name_contains: String — case-insensitive substring match on node name
#   name_exact:    String — exact node name match
#   type:          String — class name; passes if node.is_class(type) is true
#                  (matches subclasses too, e.g. type="Node3D" picks up
#                  MeshInstance3D, CharacterBody3D, ...)
#   group:         String — node must be in this group
#   max_results:   int (default 100, clamped 1..500)
#
# Response payload:
#   nodes: [String]    scene-relative paths
#   count: int
#   truncated: bool    true if max_results was hit

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_RESULTS := 100
const HARD_CAP := 500


func _init() -> void:
	tool_name = "find_nodes"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.success("No scene currently open", {
			"nodes": [],
			"count": 0,
			"truncated": false,
		})

	var name_contains: String = ToolUtils.parse_string_arg(args, "name_contains").to_lower()
	var name_exact: String = ToolUtils.parse_string_arg(args, "name_exact")
	var type_filter: String = ToolUtils.parse_string_arg(args, "type")
	var group_filter: String = ToolUtils.parse_string_arg(args, "group")
	var max_results: int = ToolUtils.parse_int_arg(args, "max_results", DEFAULT_MAX_RESULTS)
	max_results = clamp(max_results, 1, HARD_CAP)

	var matches: Array = []
	var truncated: bool = false
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if _node_matches(node, name_contains, name_exact, type_filter, group_filter):
			var rel := ToolUtils.node_relative_path(node)
			matches.append(rel if not rel.is_empty() else String(node.name))
			if matches.size() >= max_results:
				truncated = true
				break
		for child in node.get_children():
			stack.push_back(child)

	matches.sort()
	return ToolUtils.success("Found %d node(s)" % matches.size(), {
		"nodes": matches,
		"count": matches.size(),
		"truncated": truncated,
	})


func _node_matches(node: Node, name_contains: String, name_exact: String, type_filter: String, group_filter: String) -> bool:
	if not name_contains.is_empty() and not String(node.name).to_lower().contains(name_contains):
		return false
	if not name_exact.is_empty() and String(node.name) != name_exact:
		return false
	if not type_filter.is_empty() and not node.is_class(type_filter):
		return false
	if not group_filter.is_empty() and not node.is_in_group(group_filter):
		return false
	return true
