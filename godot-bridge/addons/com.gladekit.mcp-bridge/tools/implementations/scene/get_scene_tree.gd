extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns the active scene's node hierarchy as a JSON-friendly tree.
# Read-only — safe during play mode.
#
# Args:
#   max_depth: int (optional, default 50) — safety cap against pathological scenes.
#   response_format: String (optional, default "both") — controls which views
#                    of the tree are returned. One of:
#                      "both"           — both `tree` (nested) and `tree_text`
#                                         (ASCII). Backward-compatible default.
#                      "tree_text_only" — drop `tree`; keep `tree_text` only.
#                                         Recommended for agent calls: half the
#                                         payload tokens on large scenes.
#                      "tree_only"      — drop `tree_text`; keep `tree` only.
#                                         For programmatic callers that walk
#                                         children[] arrays.
#                    `scene_path` and `node_count` are returned in every mode.
#
# Response payload:
#   tree:       Dictionary or null (null if no scene open, or if format dropped it)
#   tree_text:  String — flat, indented ASCII rendering of the whole tree.
#               This is the model-friendly view: it lists every node top to
#               bottom so an LLM can enumerate the scene without having to walk
#               nested `children[]` arrays (which weaker/faster models routinely
#               under-read, reporting only the root). Returned as "" when the
#               format dropped it.
#   scene_path: String  ("" for ad-hoc / unsaved scenes)
#   node_count: int  — also echoed in the success message.
#
# Each node in `tree`:
#   { "name": String, "type": String, "path": String,
#     "script_path": String (optional),
#     "children": [ ...recursive... ],
#     "children_truncated": int (only if max_depth hit) }

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_DEPTH := 50
const FORMAT_BOTH := "both"
const FORMAT_TREE_TEXT_ONLY := "tree_text_only"
const FORMAT_TREE_ONLY := "tree_only"
const _VALID_FORMATS := [FORMAT_BOTH, FORMAT_TREE_TEXT_ONLY, FORMAT_TREE_ONLY]


func _init() -> void:
	tool_name = "get_scene_tree"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var format: String = ToolUtils.parse_string_arg(args, "response_format", FORMAT_BOTH)
	if not _VALID_FORMATS.has(format):
		return ToolUtils.error_with_solutions(
			"Unknown response_format '%s'" % format,
			[
				"Use response_format='both' (default — tree + tree_text)",
				"Use response_format='tree_text_only' to drop the nested JSON tree",
				"Use response_format='tree_only' to drop the ASCII tree_text",
			]
		)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		var empty: Dictionary = {
			"scene_path": "",
			"node_count": 0,
		}
		if format != FORMAT_TREE_TEXT_ONLY:
			empty["tree"] = null
		if format != FORMAT_TREE_ONLY:
			empty["tree_text"] = ""
		return ToolUtils.success("No scene currently open in the editor", empty)
	var max_depth: int = ToolUtils.parse_int_arg(args, "max_depth", DEFAULT_MAX_DEPTH)
	if max_depth <= 0:
		max_depth = DEFAULT_MAX_DEPTH
	var count := _count_nodes(root)
	var noun: String = "node" if count == 1 else "nodes"

	var payload: Dictionary = {
		"scene_path": root.scene_file_path,
		"node_count": count,
	}
	if format != FORMAT_TREE_TEXT_ONLY:
		payload["tree"] = _serialize(root, 0, max_depth)
	if format != FORMAT_TREE_ONLY:
		var lines: Array = []
		_render_lines(root, 0, max_depth, "", true, true, lines)
		payload["tree_text"] = "\n".join(lines)
	return ToolUtils.success("Scene tree retrieved (%d %s)" % [count, noun], payload)


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


# Append a flat, indented ASCII rendering of the subtree to `out` (one line per
# node). The root prints flush-left; descendants get box-drawing connectors:
#
#   Main (Node3D)
#   ├─ MainCamera (Camera3D)
#   └─ Ground (StaticBody3D)
#      └─ CollisionShape3D (CollisionShape3D)
func _render_lines(
	node: Node, depth: int, max_depth: int, prefix: String, is_last: bool, is_root: bool, out: Array
) -> void:
	var label: String = "%s (%s)" % [String(node.name), node.get_class()]
	var script = node.get_script()
	if script != null and script.resource_path != "":
		label += "  [script: %s]" % script.resource_path
	if is_root:
		out.append(label)
	else:
		out.append("%s%s%s" % [prefix, "└─ " if is_last else "├─ ", label])
	var child_prefix: String = prefix if is_root else prefix + ("   " if is_last else "│  ")
	if depth >= max_depth:
		var hidden := node.get_child_count()
		if hidden > 0:
			out.append("%s└─ … (%d more, max_depth reached)" % [child_prefix, hidden])
		return
	var children := node.get_children()
	for i in children.size():
		_render_lines(children[i], depth + 1, max_depth, child_prefix, i == children.size() - 1, false, out)
