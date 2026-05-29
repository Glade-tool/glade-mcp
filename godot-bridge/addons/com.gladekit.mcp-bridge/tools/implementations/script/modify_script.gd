extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Overwrites an existing GDScript file. Refuses to modify a file the bridge
# did NOT create in the current session, unless the caller passes
# confirm_existing_file_modification = true.
#
# This mirrors ModifyScriptTool.cs in the Unity bridge: AI clients that
# misread a "scaffold a new system" prompt as "extend an existing one" can
# silently destroy user code. The user-intent gate forces the caller to
# acknowledge it is touching pre-existing code.
#
# Args:
#   script_path: String (required) — res:// path to an existing .gd file.
#   content:     String (required) — full new file contents.
#   confirm_existing_file_modification: bool (default false) — required if
#                                       the file was not created via
#                                       create_script in this session.
#
# Response payload:
#   script_path: String
#   bytes:       int

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")


func _init() -> void:
	tool_name = "modify_script"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")
	if not args.has("content"):
		return ToolUtils.error("content is required")
	var content: String = ToolUtils.parse_string_arg(args, "content")

	if script_path.get_extension().is_empty():
		script_path += ".gd"
	var ext := script_path.get_extension().to_lower()
	if ext != "gd":
		return ToolUtils.error("modify_script only handles .gd files (got .%s)" % ext)

	if not FileAccess.file_exists(script_path):
		return ToolUtils.error("File does not exist at '%s' (use create_script to create a new script)" % script_path)

	var confirm: bool = ToolUtils.parse_bool_arg(args, "confirm_existing_file_modification", false)
	if not SessionTracker.was_created_this_session(script_path) and not confirm:
		return ToolUtils.error(
			"Refused to modify '%s' — this script was not created in the current Godot session via create_script. " % script_path
			+ "If the user explicitly named this file to extend or modify, retry with confirm_existing_file_modification=true. "
			+ "Otherwise treat this as a fresh-scaffold task and call create_script with a new path.",
			{"script_path": script_path, "reason": "preExistingScriptWithoutConfirmation"}
		)

	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return ToolUtils.error("Could not open '%s' for writing (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
	file.store_string(content)
	file.close()

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	return ToolUtils.success("Modified script at '%s'" % script_path, {
		"script_path": script_path,
		"bytes": content.length(),
	})
