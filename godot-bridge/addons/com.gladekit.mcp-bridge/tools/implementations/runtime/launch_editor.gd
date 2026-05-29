extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Launches a fresh Godot editor instance on a different project. Useful
# for opening a different Godot project in a separate editor, and as a quick
# way to bootstrap a project that the agent just scaffolded on disk.
#
# Read-only with respect to the current editor session — the launched
# process is independent and inherits no state from this bridge.
#
# Args:
#   project_path: String (required) — absolute path to a directory
#                                     containing project.godot.
#
# Response payload:
#   pid:          int — process id of the launched editor
#   project_path: String
#   command:      String — full commandline for diagnostics

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "launch_editor"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var project_path: String = ToolUtils.parse_string_arg(args, "project_path")
	if project_path.is_empty():
		return ToolUtils.error("project_path is required")
	# Strip trailing separators for a clean concat.
	project_path = project_path.rstrip("/").rstrip("\\")
	var manifest := project_path + "/project.godot"
	if not FileAccess.file_exists(manifest):
		# FileAccess only resolves res://, so for absolute paths we have
		# to fall back to OS-level file check. Use a DirAccess detour.
		var dir := DirAccess.open(project_path)
		if dir == null:
			return ToolUtils.error_with_solutions(
				"project_path '%s' is not a readable directory" % project_path,
				["Pass an absolute filesystem path", "Verify the directory exists outside res://"]
			)
		if not dir.file_exists("project.godot"):
			return ToolUtils.error_with_solutions(
				"No project.godot found in '%s'" % project_path,
				["Pass the directory that contains project.godot", "Or call create_scene + save_scene to scaffold one"]
			)

	var godot_exe := OS.get_executable_path()
	if godot_exe.is_empty():
		return ToolUtils.error("Could not resolve Godot executable path")

	# create_process returns a PID immediately; the editor stays running
	# detached from this bridge.
	var pid := OS.create_process(godot_exe, ["-e", "--path", project_path])
	if pid <= 0:
		return ToolUtils.error("OS.create_process failed to spawn editor (pid=%d)" % pid)

	return ToolUtils.success("Launched editor (pid %d) on '%s'" % [pid, project_path], {
		"pid": pid,
		"project_path": project_path,
		"command": "%s -e --path %s" % [godot_exe, project_path],
	})
