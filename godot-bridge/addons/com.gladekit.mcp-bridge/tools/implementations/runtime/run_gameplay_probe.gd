extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Input-driven playtest: run the scene headlessly while a probe presses the
# configured input actions on a schedule, tracks the player body, and reports
# what actually happened. Where run_project(verify=true) answers "does it run
# without errors?", this answers "does the GAMEPLAY work?" — did pressing
# move_right actually move the player, did jump gain height, did the body
# fall out of the world.
#
# Mechanics: spawns the same kind of headless child process as run_project,
# but boots it through probe/gameplay_probe_runner.gd (a SceneTree script)
# instead of the scene directly. The probe rides the normal play-session
# infrastructure — the response carries a session_id, output is read with
# get_debug_output, and stop_project / the session watchdog handle teardown.
# When the probe finishes it prints a single line to stdout:
#
#   GLADEKIT_PROBE_REPORT: {"probe":"gameplay","completed":true,
#       "steps":[...], "problems":[...], ...}
#
# and exits on its own. Runtime script errors still land on stderr exactly as
# with run_project, so one probe run yields both signals.
#
# Args:
#   scene:      String — scene to probe. Defaults to "current" (the scene open
#                        in the editor — almost always what you just edited).
#                        A res:// path probes that scene instead.
#   steps:      Array  — input schedule. Each step:
#                        {action: String (required — an InputMap action name),
#                         hold_frames: int = 30,
#                         start_frame: int (default: sequential),
#                         strength: float = 1.0,
#                         expect: "move" | "jump" | "none" (default "none")}
#                        Steps without start_frame run one after another.
#   max_frames: int    — probe duration ceiling in physics frames (default 300
#                        ≈ 5s at 60fps, capped 1800).
#   track:      String — node path/name of the body to track. Default: first
#                        "player"-group member, else first CharacterBody, else
#                        first RigidBody.
#   settle_frames:  int — frames to wait before the first input (default 10).
#   auto_save:      bool — save the edited scene before spawning (default true).
#   allow_multiple: bool — permit a concurrent play session (default false).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const PlaySessionManager = preload("res://addons/com.gladekit.mcp-bridge/services/play_session_manager.gd")

const RUNNER_SCRIPT := "res://addons/com.gladekit.mcp-bridge/probe/gameplay_probe_runner.gd"
const CONFIG_ARG_PREFIX := "--gladekit-probe-config="
const MAX_STEPS := 16
const QUIT_AFTER_SLACK_FRAMES := 240  # engine-level backstop past max_frames


func _init() -> void:
	tool_name = "run_gameplay_probe"
	requires_edit_mode = false  # safe in play mode (separate process)


func execute(args: Dictionary) -> Dictionary:
	# Same idempotency contract as run_project: refuse while another session
	# is running, unless explicitly overridden.
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

	# Save the edited scene first so the probe process loads the agent's
	# latest in-memory changes from disk (same default as run_project).
	var auto_saved_scene: String = ""
	var auto_save: bool = ToolUtils.parse_bool_arg(args, "auto_save", true)
	if auto_save:
		var root: Node = EditorInterface.get_edited_scene_root()
		if root != null:
			var scene_path: String = root.scene_file_path
			if scene_path.is_empty():
				push_warning("[run_gameplay_probe] Edited scene is untitled — cannot auto-save. The probe will use the last saved disk state. Call save_scene with a path first, or pass auto_save=false to suppress this warning.")
			else:
				var save_err: int = EditorInterface.save_scene()
				if save_err != OK:
					return ToolUtils.error_with_solutions(
						"Failed to auto-save scene '%s' before probing (err %d)" % [scene_path, save_err],
						[
							"Pass auto_save=false to skip the auto-save step",
							"Or save the scene manually via save_scene then retry",
						]
					)
				auto_saved_scene = scene_path

	# Default to the edited scene — a probe verifies the change just made,
	# and the project's main scene is often a menu that doesn't contain it.
	var scene: String = ToolUtils.parse_string_arg(args, "scene")
	if scene.is_empty() or scene == "current" or scene == "edited":
		var edited_root: Node = EditorInterface.get_edited_scene_root()
		var edited_path: String = "" if edited_root == null else edited_root.scene_file_path
		if edited_path.is_empty():
			return ToolUtils.error_with_solutions(
				"No saved scene is open in the editor to probe",
				[
					"Open (and save) the scene you want to probe, then retry",
					"Or pass scene as an explicit res:// path",
				]
			)
		scene = edited_path

	var steps := _sanitize_steps(args.get("steps"))
	if steps.has("error"):
		return ToolUtils.error_with_solutions(
			String(steps["error"]),
			[
				"Pass steps as an array of {action, hold_frames?, expect?} objects",
				"Each step's action must be an InputMap action name (see get_project_info's input_actions)",
			]
		)

	var max_frames: int = clampi(ToolUtils.parse_int_arg(args, "max_frames", 300), 30, 1800)
	var config := {
		"scene": scene,
		"steps": steps["steps"],
		"max_frames": max_frames,
		"settle_frames": clampi(ToolUtils.parse_int_arg(args, "settle_frames", 10), 0, 600),
	}
	var track: String = ToolUtils.parse_string_arg(args, "track")
	if not track.is_empty():
		config["track"] = track

	var extra: Array = [
		"--headless",
		"-s", RUNNER_SCRIPT,
		# Engine-level backstop: if the probe node somehow never reports, the
		# child still exits on its own (and the session watchdog remains the
		# outer safety net).
		"--quit-after", str(max_frames + QUIT_AFTER_SLACK_FRAMES),
		"--",
		CONFIG_ARG_PREFIX + Marshalls.utf8_to_base64(JSON.stringify(config)),
	]
	# The scene is deliberately NOT passed positionally — the runner script
	# replaces the main loop and loads the scene itself from the config.
	var spawn := PlaySessionManager.start(project_path, "", extra)
	if spawn.has("error"):
		return ToolUtils.error_with_solutions(
			spawn["error"],
			[
				"Confirm the Godot executable is accessible via OS.get_executable_path()",
				"Confirm the project path resolves to a valid res:// directory",
			]
		)

	var step_count: int = (steps["steps"] as Array).size()
	var msg: String = (
		"Spawned gameplay probe (session_id='%s', pid=%d) on '%s' with %d input step(s). "
		+ "Wait ~%d s, then call get_debug_output(session_id='%s') and read the GLADEKIT_PROBE_REPORT line "
		+ "(plus any SCRIPT ERROR lines). Pass session_id (NOT pid) to get_debug_output and stop_project."
	) % [
		String(spawn["session_id"]), int(spawn["pid"]), scene, step_count,
		maxi(3, int(ceilf(float(max_frames) / 60.0)) + 2), String(spawn["session_id"]),
	]
	return ToolUtils.success(msg, {
		"session_id": spawn["session_id"],
		"pid": int(spawn["pid"]),
		"command": spawn["command"],
		"ran_scene": scene,
		"steps_count": step_count,
		"max_frames": max_frames,
		"auto_saved_scene": auto_saved_scene,
	})


# Validate + normalize the steps arg into plain JSON-safe dicts. Returns
# {"steps": Array} on success or {"error": String} on a malformed arg. An
# empty/absent steps array is allowed — the probe then runs as a pure smoke
# test (load + fall detection, no input).
func _sanitize_steps(raw) -> Dictionary:
	var out: Array = []
	if raw == null:
		return {"steps": out}
	if not (raw is Array):
		return {"error": "steps must be an array of step objects"}
	if (raw as Array).size() > MAX_STEPS:
		return {"error": "steps is capped at %d entries per probe run" % MAX_STEPS}
	for entry in raw:
		if not (entry is Dictionary):
			return {"error": "each step must be an object with at least an 'action' key"}
		var action := String(entry.get("action", ""))
		if action.is_empty():
			return {"error": "each step needs a non-empty 'action' (an InputMap action name)"}
		var step := {"action": action}
		if entry.has("hold_frames"):
			step["hold_frames"] = clampi(int(_coerce_num(entry["hold_frames"], 30.0)), 1, 1200)
		if entry.has("start_frame"):
			step["start_frame"] = clampi(int(_coerce_num(entry["start_frame"], 0.0)), 0, 1800)
		if entry.has("strength"):
			step["strength"] = clampf(_coerce_num(entry["strength"], 1.0), 0.0, 1.0)
		if entry.has("expect"):
			var expect := String(entry["expect"]).to_lower()
			if expect not in ["move", "jump", "none"]:
				return {"error": "step expect must be one of: move, jump, none (got '%s')" % expect}
			step["expect"] = expect
		out.append(step)
	return {"steps": out}


# Numeric step fields arrive as int, float, or numeric string depending on
# the JSON path; coerce all three, falling back to the step default.
static func _coerce_num(v, default_value: float) -> float:
	if v is int or v is float:
		return float(v)
	if v is String and String(v).is_valid_float():
		return String(v).to_float()
	return default_value
