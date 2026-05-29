extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns the active scene's node hierarchy as a JSON-friendly tree.
# Read-only — safe during play mode.
#
# Args:
#   max_depth: int (optional, default 50) — safety cap against pathological scenes.
#
# Response payload:
#   tree:       Dictionary or null (null if no scene open)
#   scene_path: String  ("" for ad-hoc / unsaved scenes)
#   node_count: int
#
# Each node in the tree:
#   { "name": String, "type": String, "path": String,
#     "script_path": String (optional),
#     "children": [ ...recursive... ],
#     "children_truncated": int (only if max_depth hit) }

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_DEPTH := 50


func _init() -> void:
	tool_name = "get_scene_tree"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.success("No scene currently open in the editor", {
			"tree": null,
			"scene_path": "",
			"node_count": 0,
		})
	var max_depth: int = ToolUtils.parse_int_arg(args, "max_depth", DEFAULT_MAX_DEPTH)
	if max_depth <= 0:
		max_depth = DEFAULT_MAX_DEPTH
	var tree := _serialize(root, 0, max_depth)
	return ToolUtils.success("Scene tree retrieved", {
		"tree": tree,
		"scene_path": root.scene_file_path,
		"node_count": _count_nodes(root),
	})


func _serialize(node: Node, depth: int, max_depth: int) -> Dictionary:
	var result: Dictionary = {
		"name": String(node.name),
		"type": node.get_class(),
		"path": str(node.get_path()),
	}
	var script = node.get_script()
	if script != null and script.resource_path != "":
		result["script_path"] = script.resource_path
	if depth >= max_depth:
		result["children_truncated"] = node.get_child_count()
		result["children"] = []
		return result
	var children: Array = []
	for child in node.get_children():
		children.append(_serialize(child, depth + 1, max_depth))
	result["children"] = children
	return result


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total
