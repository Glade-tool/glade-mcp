extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Spawns a headless Godot process to run the current project (or a specific
# scene) and pipes stdout/stderr back into a PlaySessionManager session.
# Headline Phase 3 feature — the "live feedback loop" godot-mcp users
# explicitly ask for. We do strictly better than godot-mcp because the
# editor stays alive while the play session runs as a separate child
# process; the agent can keep mutating the scene AND watch the running
# game in parallel.
#
# Two ergonomic defaults that match Godot's editor F5 behavior:
#   * auto_save=true — saves the edited scene before spawning so the
#     subprocess loads what the agent just wrote, not the stale disk state.
#     Without this, a "create node + attach script + run_project" chain
#     silently runs against the pre-edit scene and the model concludes
#     nothing fired.
#   * Idempotency — refuses to spawn a second session while one is still
#     running. Pass allow_multiple=true to override. Prevents the
#     "two PIE windows opened" footgun when an agent retries.
#
# Args:
#   scene:           String — scene to launch. A res:// (or project-relative)
#                             path runs that scene. The special value "current"
#                             (or "edited") runs the scene currently open in the
#                             editor — use this to verify a change you just made,
#                             since the project's main scene may be a menu that
#                             does not include the node you edited. Empty (the
#                             default) runs the project's main scene (F5 behavior).
#   verify:          bool   — run a bounded headless pass for error capture.
#                             Adds --headless --quit-after so the process exits
#                             on its own and flushes its output, making
#                             get_debug_output a reliable "did it run clean?"
#                             check. Use this (with scene="current") to verify a
#                             gameplay change. Default false (long-lived run for
#                             interactive playtesting).
#   extra_args:      Array  — additional CLI args to pass through to godot.
#   auto_save:       bool   — save the edited scene before spawn. Default true.
#                             Set false for "run the version on disk as-is" flows.
#   allow_multiple:  bool   — permit a second concurrent session. Default false.
#
# Response payload:
#   session_id:       String — use this with get_debug_output / stop_project
#   pid:              int
#   command:          String — the spawned commandline (for diagnostics)
#   ran_scene:        String — the scene path actually launched, or "" when the
#                              project's main scene was used.
#   auto_saved_scene: String — res:// path of the saved scene, or "" when no
#                              save occurred (auto_save=false, no scene open,
#                              or unsaved untitled scene).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")


func _init() -> void:
	tool_name = "run_project"
	requires_edit_mode = false  # safe in play mode (different process)


func execute(args: Dictionary) -> Dictionary:
	# Idempotency check — refuse if any session is already running, unless
	# the caller explicitly asked for concurrent sessions. Without this, an
	# agent that retries run_project on a slow first response ends up with
	# two child processes and two visible game windows.
	var allow_multiple: bool = ToolUtils.parse_bool_arg(args, "allow_multiple", false)
	if not allow_multiple:
		for s in PlaySessionManager.list_sessions():
			if bool(s.get("running", false)):
				var existing_id: String = String(s.get("session_id", ""))
				var existing_pid: int = int(s.get("pid", 0))
				return ToolUtils.error_with_solutions(
					"A play session is already running (session_id='%s', pid=%d)" % [existing_id, existing_pid],
					[
						"Call stop_project(session_id='%s') first, then retry" % existing_id,
						"Or pass allow_multiple=true to launch a second concurrent session",
					]
				)

	var project_path := ProjectSettings.globalize_path("res://")
	if project_path.is_empty():
		return ToolUtils.error("Could not resolve project root via res://")

	# Save the edited scene first so the subprocess loads the agent's latest
	# in-memory changes from disk. Skipped for untitled scenes (no path to
	# save to) and when the caller opts out.
	var auto_saved_scene: String = ""
	var auto_save: bool = ToolUtils.parse_bool_arg(args, "auto_save", true)
	if auto_save:
		var root: Node = EditorInterface.get_edited_scene_root()
		if root != null:
			var scene_path: String = root.scene_file_path
			if scene_path.is_empty():
				push_warning("[run_project] Edited scene is untitled — cannot auto-save. Subprocess will use the last saved disk state. Call save_scene with a path first, or pass auto_save=false to suppress this warning.")
			else:
				var save_err: int = EditorInterface.save_scene()
				if save_err != OK:
					return ToolUtils.error_with_solutions(
						"Failed to auto-save scene '%s' before running (err %d)" % [scene_path, save_err],
						[
							"Pass auto_save=false to skip the auto-save step",
							"Or save the scene manually via save_scene then retry",
						]
					)
				auto_saved_scene = scene_path

	var scene: String = ToolUtils.parse_string_arg(args, "scene")
	# "current"/"edited" resolves to the scene open in the editor. This is what
	# an agent wants when verifying a change: the project main scene is often a
	# menu that doesn't instantiate the node just edited, so it would run clean
	# while the real edit went untested.
	if scene == "current" or scene == "edited":
		var edited_root: Node = EditorInterface.get_edited_scene_root()
		var edited_path: String = "" if edited_root == null else edited_root.scene_file_path
		if edited_path.is_empty():
			return ToolUtils.error_with_solutions(
				"scene='current' requested but no saved scene is open in the editor",
				[
					"Open (and save) the scene you want to run, then retry",
					"Or pass scene as an explicit res:// path",
				]
			)
		scene = edited_path
	# Allow either a res:// path or a project-relative path (godot CLI accepts both).

	var extra: Array = []
	if args.has("extra_args"):
		var ea = args["extra_args"]
		if ea is Array:
			extra = ea

	# verify=true: a bounded headless run for error capture. --headless avoids a
	# window flash; --quit-after makes the process exit on its own after a few
	# hundred frames so its buffered stdout/stderr flushes and get_debug_output
	# can read the result reliably. A long-lived windowed run may never flush a
	# small runtime error, and killing it does not flush the child's libc
	# buffers — so an indefinite run is unreliable for "did it run clean?".
	var verify: bool = ToolUtils.parse_bool_arg(args, "verify", false)
	if verify:
		var has_headless := false
		var has_quit := false
		for a in extra:
			var sa := str(a)
			if sa == "--headless":
				has_headless = true
			if sa.begins_with("--quit-after"):
				has_quit = true
		if not has_headless:
			extra.append("--headless")
		if not has_quit:
			extra.append("--quit-after")
			extra.append("300")

	var spawn := PlaySessionManager.start(project_path, scene, extra)
	if spawn.has("error"):
		return ToolUtils.error_with_solutions(
			spawn["error"],
			["Confirm the Godot executable is on PATH or accessible via OS.get_executable_path()", "Confirm the project_path resolves to a valid res:// directory"]
		)

	# Spell out both identifiers in the message so the model doesn't pick
	# the wrong one when it later calls stop_project / get_debug_output.
	# Common failure pattern was passing pid (an int) as session_id (a string).
	var msg: String = "Spawned play session (session_id='%s', pid=%d). Pass session_id (NOT pid) to get_debug_output and stop_project." % [
		String(spawn["session_id"]), int(spawn["pid"])
	]
	return ToolUtils.success(msg, {
		"session_id": spawn["session_id"],
		"pid": int(spawn["pid"]),
		"command": spawn["command"],
		"ran_scene": scene,
		"auto_saved_scene": auto_saved_scene,
	})
