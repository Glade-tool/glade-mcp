extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Spawns a headless Godot process to run the current project (or a specific
# scene) and pipes stdout/stderr back into a PlaySessionManager session.
# Headline Phase 3 feature — the "live feedback loop" godot-mcp users
# explicitly ask for. We do strictly better than godot-mcp because the
# editor stays alive while the play session runs as a separate child
# process; the agent can keep mutating the scene AND watch the running
# game in parallel.
#
# Args:
#   scene:      String — optional scene path (.tscn) to launch. Default:
#                        project's main scene.
#   extra_args: Array  — additional CLI args to pass through to godot.
#
# Response payload:
#   session_id: String — use this with get_debug_output / stop_project
#   pid:        int
#   command:    String — the spawned commandline (for diagnostics)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "run_project"
	requires_edit_mode = false  # safe in play mode (different process)


func execute(args: Dictionary) -> Dictionary:
	var project_path := ProjectSettings.globalize_path("res://")
	if project_path.is_empty():
		return ToolUtils.error("Could not resolve project root via res://")

	var scene: String = ToolUtils.parse_string_arg(args, "scene")
	# Allow either a res:// path or a project-relative path.
	if not scene.is_empty() and scene.begins_with("res://"):
		scene = scene  # godot CLI accepts res:// paths

	var extra: Array = []
	if args.has("extra_args"):
		var ea = args["extra_args"]
		if ea is Array:
			extra = ea

	var spawn := PlaySessionManager.start(project_path, scene, extra)
	if spawn.has("error"):
		return ToolUtils.error_with_solutions(
			spawn["error"],
			["Confirm the Godot executable is on PATH or accessible via OS.get_executable_path()", "Confirm the project_path resolves to a valid res:// directory"]
		)

	return ToolUtils.success("Spawned play session (pid %d)" % int(spawn["pid"]), {
		"session_id": spawn["session_id"],
		"pid": int(spawn["pid"]),
		"command": spawn["command"],
	})
