extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Attaches an existing GDScript to a node in the edited scene. In Godot a
# node can have at most one script — this replaces any existing attached
# script.
#
# The script must already exist on disk. Use create_script first if it
# doesn't.
#
# Args:
#   node_path:   String (required)
#   script_path: String (required) — res:// path to a .gd file.
#
# Response payload:
#   node_path:           String
#   script_path:         String
#   previous_script_path: String — empty if no script was attached before.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "attach_script_to_node"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")
	if not FileAccess.file_exists(script_path):
		return ToolUtils.error("Script does not exist at '%s' (call create_script first)" % script_path)

	var script := load(script_path)
	if not (script is Script):
		return ToolUtils.error("Resource at '%s' loaded but is not a Script (got %s)" % [script_path, type_string(typeof(script))])

	var previous_script_path: String = ""
	var prev = node.get_script()
	if prev != null and prev.resource_path != "":
		previous_script_path = prev.resource_path

	node.set_script(script)

	return ToolUtils.success("Attached '%s' to node '%s'" % [script_path, node_path], {
		"node_path": ToolUtils.node_relative_path(node),
		"script_path": script_path,
		"previous_script_path": previous_script_path,
	})
