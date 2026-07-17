extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Modifies an existing GDScript file. Refuses to modify a file the bridge
# did NOT create in the current session, unless the caller passes
# confirm_existing_file_modification = true.
#
# This mirrors ModifyScriptTool.cs in the Unity bridge: AI clients that
# misread a "scaffold a new system" prompt as "extend an existing one" can
# silently destroy user code. The user-intent gate forces the caller to
# acknowledge it is touching pre-existing code.
#
# Two edit modes:
#   1. SURGICAL EDIT (old_string/new_string) — replace one exact snippet,
#      leaving the rest of the file untouched. Far cheaper and safer on large
#      files than resending the whole thing. Exact literal match; a non-unique
#      old_string is rejected unless replace_all=true; empty new_string deletes.
#   2. FULL REWRITE (content) — replace the entire file.
#
# Args:
#   script_path: String (required) — res:// path to an existing .gd file.
#   old_string:  String — surgical edit: exact snippet to replace (must be
#                unique unless replace_all=true). When set, content is ignored.
#   new_string:  String — surgical edit: replacement for old_string ("" deletes).
#   replace_all: bool (default false) — replace every occurrence of old_string.
#   content:     String — full rewrite: complete new file contents.
#   confirm_existing_file_modification: bool (default false) — required if
#                                       the file was not created via
#                                       create_script in this session.
#
# Response payload:
#   script_path:  String
#   bytes:        int
#   mode:         String — "anchor" (only present for a surgical edit)
#   replacements: int    — occurrences replaced (only present for a surgical edit)

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

	# Surgical edit mode: old_string present → replace one snippet, don't rewrite.
	var old_string: String = ToolUtils.parse_string_arg(args, "old_string")
	var new_string: String = ToolUtils.parse_string_arg(args, "new_string")
	var replace_all: bool = ToolUtils.parse_bool_arg(args, "replace_all", false)
	var anchor_mode: bool = not old_string.is_empty()

	# Full-rewrite content. Accept Unity arg-name habits: `scriptContent` arrives
	# as `script_content` after normalize_args. Mirrors create_script's defense —
	# keeps a Unity-trained model out of the cryptic "content is required" trap.
	# Only required when NOT doing a surgical edit.
	var content: String = ""
	if not anchor_mode:
		var content_key := ""
		for candidate in ["content", "script_content", "script_text"]:
			if args.has(candidate):
				content_key = candidate
				break
		if content_key == "":
			return ToolUtils.error(
				"Provide either `content` (full rewrite) or `old_string` (surgical edit). "
				+ "For a small change to a large file, prefer old_string/new_string. "
				+ "(Godot uses `content`; `scriptContent`/`scriptText` is a Unity habit.)"
			)
		content = ToolUtils.parse_string_arg(args, content_key)

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

	var replacements: int = 0
	if anchor_mode:
		# Resolve the surgical edit against the current file. Exact literal
		# matching (no regex) — the snippet the caller sends is what gets replaced.
		var read_file := FileAccess.open(script_path, FileAccess.READ)
		if read_file == null:
			return ToolUtils.error("Could not open '%s' for reading (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
		var current := read_file.get_as_text()
		read_file.close()

		if old_string == new_string:
			return ToolUtils.error("old_string and new_string are identical — no change to make.")

		var occurrences: int = current.count(old_string)
		if occurrences == 0:
			return ToolUtils.error(
				"old_string was not found in '%s'. It must match the file's current text exactly " % script_path
				+ "(whitespace and indentation included). Read the script first (get_script_content) to copy the exact snippet."
			)
		if occurrences > 1 and not replace_all:
			return ToolUtils.error(
				"old_string matched %d times in '%s'. Include more surrounding context to make it " % [occurrences, script_path]
				+ "unique, or set replace_all=true to replace every occurrence."
			)

		if replace_all:
			content = current.replace(old_string, new_string)
			replacements = occurrences
		else:
			content = _replace_first(current, old_string, new_string)
			replacements = 1

	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return ToolUtils.error("Could not open '%s' for writing (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
	file.store_string(content)
	file.close()

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	var payload := {
		"script_path": script_path,
		"bytes": content.length(),
	}
	var msg := "Modified script at '%s'" % script_path
	if anchor_mode:
		payload["mode"] = "anchor"
		payload["replacements"] = replacements
		msg += " (%d replacement%s)" % [replacements, "" if replacements == 1 else "s"]
	return ToolUtils.success(msg, payload)


# Replaces only the first occurrence of `needle` in `haystack` (GDScript's
# String.replace replaces all). Returns `haystack` unchanged when not found.
func _replace_first(haystack: String, needle: String, repl: String) -> String:
	var idx := haystack.find(needle)
	if idx < 0:
		return haystack
	return haystack.substr(0, idx) + repl + haystack.substr(idx + needle.length())
