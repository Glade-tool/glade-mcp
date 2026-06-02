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
const BackupManager = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")


func _init() -> void:
	tool_name = "modify_script"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")

	if script_path.get_extension().is_empty():
		script_path += ".gd"
	var ext := script_path.get_extension().to_lower()
	if ext == "cs":
		return ToolUtils.error_with_solutions(
			"modify_script only handles GDScript (.gd) files — got .cs. This is a Godot project; C# is a Unity convention.",
			[
				"Change the file extension from .cs to .gd",
				"Rewrite the body in GDScript syntax (# comments, var/func/extends)",
				"Pass `script_path` and `content` (NOT `scriptPath`/`scriptContent`)",
			]
		)
	if ext != "gd":
		return ToolUtils.error("modify_script only handles .gd files (got .%s)" % ext)

	# Accept Unity arg-name habits: `scriptContent` arrives as `script_content`
	# after normalize_args. Mirrors create_script's defense — keeps a
	# Unity-trained model out of the cryptic "content is required" trap.
	var content_key := ""
	for candidate in ["content", "script_content", "script_text"]:
		if args.has(candidate):
			content_key = candidate
			break
	if content_key == "":
		return ToolUtils.error(
			"content is required (Godot uses `content`; if you reached for `scriptContent` / `scriptText`, that's a Unity habit — use `content`)"
		)
	var content: String = ToolUtils.parse_string_arg(args, content_key)

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

	# Snapshot the pre-modification file BEFORE we overwrite it. The renderer
	# layer drives the revert UI off per-tool {backupPath, turnId} that comes
	# back from the bridge's backup/file endpoint, but a tool that mutates a
	# file without a corresponding endpoint round-trip would lose its pre-state
	# the moment we open(WRITE) below. Belt-and-suspenders: do an in-tool
	# snapshot too (unscoped, so it doesn't collide with the turn tree). Best
	# effort — backup_file is documented to never raise — so this never blocks
	# the mutation.
	BackupManager.backup_file(script_path)

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
