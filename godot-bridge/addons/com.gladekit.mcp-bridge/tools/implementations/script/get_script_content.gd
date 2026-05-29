extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Reads the contents of a .gd script file. Read-only — safe in play mode.
#
# Args:
#   script_path: String (required) — res:// path.
#
# Response payload:
#   script_path: String — normalized res:// path
#   content:     String
#   bytes:       int

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_script_content"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")

	if not FileAccess.file_exists(script_path):
		return ToolUtils.error("File does not exist at '%s'" % script_path)

	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return ToolUtils.error("Could not open '%s' for reading (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
	var content := file.get_as_text()
	file.close()

	return ToolUtils.success("Read script '%s'" % script_path, {
		"script_path": script_path,
		"content": content,
		"bytes": content.length(),
	})
