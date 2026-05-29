extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Returns the nodes currently selected in the editor's Scene dock.
# Read-only — safe in play mode.
#
# Response payload:
#   selection: [String] — scene-relative paths
#   count:     int

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_selection"
	requires_edit_mode = false


func execute(_args: Dictionary) -> Dictionary:
	var selection := EditorInterface.get_selection()
	if selection == null:
		return ToolUtils.success("No selection (EditorInterface returned null)", {
			"selection": [],
			"count": 0,
		})
	var paths: Array = []
	for n in selection.get_selected_nodes():
		var rel := ToolUtils.node_relative_path(n)
		paths.append(rel if not rel.is_empty() else String(n.name))
	return ToolUtils.success("Selection retrieved", {
		"selection": paths,
		"count": paths.size(),
	})
