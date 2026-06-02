extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates a new GDScript (.gd) file at a project path. Refuses to overwrite
# an existing file — use modify_script for that. After writing the file
# triggers a resource-filesystem scan so the script appears in the editor's
# FileSystem dock immediately.
#
# Args:
#   script_path: String (required) — res://-style path. Convenience: a path
#                without "res://" or "/" prefix is treated as res://<path>.
#                Auto-appends ".gd" if no extension.
#   content:     String (required) — full file contents.
#
# Response payload:
#   script_path: String — the final res:// path
#   bytes:       int

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")


func _init() -> void:
	tool_name = "create_script"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var script_path: String = ToolUtils.parse_path_arg(args, "script_path")
	if script_path.is_empty():
		return ToolUtils.error("script_path is required")

	# Auto-extension: default to .gd.
	if script_path.get_extension().is_empty():
		script_path += ".gd"
	# Extension check runs BEFORE content so a model that brought Unity habits
	# (.cs files, C# style) sees the actionable engine-mismatch error first,
	# instead of "content is required" hiding the root cause.
	var ext := script_path.get_extension().to_lower()
	if ext == "cs":
		return ToolUtils.error_with_solutions(
			"create_script only handles GDScript (.gd) files — got .cs. This is a Godot project; C# is a Unity convention.",
			[
				"Change the file extension from .cs to .gd",
				"Rewrite the body in GDScript: `#` comments (not `//`), `var`/`func`/`extends`, no `public class ...`",
				"Pass `script_path` (snake_case) and `content` (NOT `scriptPath`/`scriptContent`)",
			]
		)
	if ext != "gd":
		return ToolUtils.error("create_script only handles .gd files (got .%s); .gdshader will land in a later phase" % ext)

	# Accept Unity arg-name habits: `scriptContent` arrives as `script_content`
	# after normalize_args; `scriptText` becomes `script_text`. We document
	# `content` as the canonical name (and the schema enforces it for new
	# callers), but a model leaning on Unity priors gets one free pass instead
	# of a cryptic "content is required" while the diff card displays the
	# content it actually sent.
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

	# Ensure parent directory exists. DirAccess.make_dir_recursive_absolute
	# returns OK if the dir already exists; we check globalize_path so the
	# call works whether the project is on disk or running headless.
	var dir_path: String = script_path.get_base_dir()
	if not dir_path.is_empty():
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [dir_path, make_err])

	if FileAccess.file_exists(script_path):
		return ToolUtils.error("File already exists at '%s' (use modify_script to overwrite)" % script_path)

	var file := FileAccess.open(script_path, FileAccess.WRITE)
	if file == null:
		return ToolUtils.error("Could not open '%s' for writing (FileAccess error %d)" % [script_path, FileAccess.get_open_error()])
	file.store_string(content)
	file.close()

	# Track creation so modify_script knows the bridge created this script
	# in the current session (matches Unity SessionTracker semantics).
	SessionTracker.mark_created(script_path)

	# Tell the editor to pick up the new file.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.scan()

	return ToolUtils.success("Created script at '%s'" % script_path, {
		"script_path": script_path,
		"bytes": content.length(),
	})
