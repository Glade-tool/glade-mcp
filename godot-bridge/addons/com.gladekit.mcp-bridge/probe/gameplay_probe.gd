extends Node

# Input-driving gameplay probe. Spawned by gameplay_probe_runner.gd as a
# direct child of the SceneTree root (a sibling of the scene under test, so
# it survives an in-game change_scene_to_file).
#
# What it does, per physics frame:
#   1. presses/releases input actions on the configured schedule (both
#      Input.action_press AND Input.parse_input_event(InputEventAction), so
#      is_action_pressed / get_axis / get_vector polling AND
#      _input / is_action_just_pressed event handling all fire);
#   2. samples the tracked body's global position (and is_on_floor() for
#      CharacterBody2D/3D);
#   3. checks each step's declared expectation ("move" / "jump" / "none")
#      against what the body actually did.
#
# When the schedule completes (or max_frames elapses) it prints ONE
# machine-readable line to stdout and quits:
#
#   GLADEKIT_PROBE_REPORT: {"probe":"gameplay","completed":true,...}
#
# The report always carries the raw measurements (per-step displacement,
# upward gain, on-floor frames, fall detection) so the caller can reason
# about behavior even for steps with no declared expectation. Only declared
# expectations and out-of-world falls generate entries in "problems" —
# the probe measures; it does not guess what the game was supposed to do.
#
# Config keys (all optional):
#   steps: Array of {action: String (required per step),
#                    start_frame: int (default: scheduled sequentially),
#                    hold_frames: int (default 30),
#                    strength: float (default 1.0),
#                    expect: "move" | "jump" | "none" (default "none")}
#   max_frames: int      — probe duration ceiling in physics frames (default 300)
#   settle_frames: int   — frames before the first scheduled input (default 10)
#   track: String        — node path or name of the body to track. Default:
#                          first member of the "player" group, else the first
#                          CharacterBody3D/2D, else the first RigidBody3D/2D.
#   move_threshold: float — min horizontal displacement satisfying expect="move"
#                           (default 0.25 in 3D units / 8.0 px in 2D)
#   jump_threshold: float — min upward gain satisfying expect="jump"
#                           (default 0.3 in 3D units / 12.0 px in 2D)
#   fall_limit: float     — drop below the start position that counts as
#                           falling out of the world (default 25.0 / 1500.0 px)

const JUMP_TAIL_FRAMES := 30  # keep sampling up-gain this long after release
const FINISH_TAIL_FRAMES := 15  # idle frames after the last step before reporting
const STEP_GAP_FRAMES := 10  # gap between auto-scheduled steps
const DEFAULT_HOLD_FRAMES := 30
# A body often spawns slightly above the floor and needs a few frames to land.
# For an expect="jump" step on a CharacterBody we defer the press until the body
# is actually on the floor (up to this many frames) — pressing jump mid-drop
# reads as a broken jump when the jump is fine. Bounds how long we wait so a body
# that genuinely never lands (no floor) still reports rather than stalling.
const JUMP_SETTLE_WAIT_FRAMES := 120

var config: Dictionary = {}

var _frame: int = 0
var _finish_frame: int = 300
var _max_frames: int = 300
var _steps: Array = []

var _tracked: Node = null
var _tracked_path: String = ""
var _tracked_type: String = ""
var _space: String = ""  # "3d" | "2d" | "" while nothing is tracked
var _have_start: bool = false
var _start_pos: Vector3 = Vector3.ZERO  # 2D positions stored as (x, y, 0)
var _last_pos: Vector3 = Vector3.ZERO
var _min_y: float = 0.0
var _max_y: float = 0.0
var _on_floor_frames: int = 0
var _is_character_body: bool = false
var _notes: Array = []
var _reported: bool = false

var _move_threshold: float = 0.0
var _jump_threshold: float = 0.0
var _fall_limit: float = 0.0


func _ready() -> void:
	# Keep probing even if the game pauses itself (e.g. a pause menu fired).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_max_frames = clampi(int(config.get("max_frames", 300)), 30, 1800)
	# Default settle gives a body that spawns just above the floor time to land
	# before the first input — a mid-drop press (especially for jump) misreads.
	var settle: int = clampi(int(config.get("settle_frames", 30)), 0, 600)
	_steps = _normalize_steps(config.get("steps", []), settle)
	# Finish shortly after the last step's observation window closes; a
	# stepless run is a pure smoke test and uses the full max_frames.
	var last_window_end: int = 0
	for s in _steps:
		last_window_end = maxi(last_window_end, int(s["release_frame"]) + JUMP_TAIL_FRAMES)
	if _steps.is_empty():
		_finish_frame = _max_frames
	else:
		_finish_frame = mini(_max_frames, last_window_end + FINISH_TAIL_FRAMES)


func _physics_process(_delta: float) -> void:
	if _reported:
		return
	_frame += 1
	_ensure_tracked()
	_sample_tracked()
	for s in _steps:
		_advance_step(s)
	if _frame >= _finish_frame:
		_finish()


# ── Step schedule ────────────────────────────────────────────────────────────


func _normalize_steps(raw, settle: int) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	var next_start: int = settle
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var action := String(entry.get("action", ""))
		if action.is_empty():
			continue
		var hold: int = clampi(int(entry.get("hold_frames", DEFAULT_HOLD_FRAMES)), 1, 1200)
		var start: int = int(entry.get("start_frame", -1))
		if start < 0:
			start = next_start
		var expect := String(entry.get("expect", "none")).to_lower()
		if expect not in ["move", "jump", "none"]:
			expect = "none"
		out.append({
			"action": action,
			"expect": expect,
			"strength": clampf(float(entry.get("strength", 1.0)), 0.0, 1.0),
			"press_frame": start,
			"hold_frames": hold,
			"release_frame": start + hold,
			"pressed": false,
			"released": false,
			"finalized": false,
			"missing_action": false,
			"press_deferrals": 0,
			"never_grounded": false,
			"press_pos": Vector3.ZERO,
			"had_press_pos": false,
			"window_min_y": 0.0,
			"window_max_y": 0.0,
			"horizontal_displacement": 0.0,
			"up_gain": 0.0,
			"satisfied": null,
		})
		next_start = start + hold + STEP_GAP_FRAMES
	return out


func _advance_step(s: Dictionary) -> void:
	if s["finalized"]:
		return
	if not s["pressed"] and _frame >= int(s["press_frame"]):
		# For an expect="jump" step, wait until a CharacterBody is actually on the
		# floor before pressing — a jump requires ground contact, and pressing
		# while the body is still settling onto the floor reads as a broken jump.
		# Bounded so a body that never lands (no floor) still presses and reports.
		if (
			String(s["expect"]) == "jump"
			and _is_character_body
			and _tracked_valid()
			and not _tracked.is_on_floor()
		):
			if int(s["press_deferrals"]) < JUMP_SETTLE_WAIT_FRAMES:
				s["press_deferrals"] = int(s["press_deferrals"]) + 1
				return
			s["never_grounded"] = true
		s["pressed"] = true
		if not InputMap.has_action(String(s["action"])):
			s["missing_action"] = true
			s["finalized"] = true
			return
		_send_action(String(s["action"]), true, float(s["strength"]))
		# Recompute the release relative to the ACTUAL press frame so a deferred
		# press still holds for the requested duration, and push the report-out
		# frame back so a late jump's arc is fully sampled before we finish.
		s["release_frame"] = _frame + int(s["hold_frames"])
		_finish_frame = mini(_max_frames, maxi(_finish_frame, int(s["release_frame"]) + JUMP_TAIL_FRAMES + FINISH_TAIL_FRAMES))
		if _have_start and _tracked_valid():
			s["press_pos"] = _current_pos()
			s["had_press_pos"] = true
			s["window_min_y"] = s["press_pos"].y
			s["window_max_y"] = s["press_pos"].y
	if not s["pressed"]:
		return
	# Track the vertical envelope through the hold + a short tail, so a jump
	# whose apex lands after release still counts.
	if s["had_press_pos"] and _tracked_valid():
		var pos := _current_pos()
		s["window_min_y"] = minf(float(s["window_min_y"]), pos.y)
		s["window_max_y"] = maxf(float(s["window_max_y"]), pos.y)
	if not s["released"] and _frame >= int(s["release_frame"]):
		s["released"] = true
		_send_action(String(s["action"]), false, 0.0)
		if s["had_press_pos"] and _tracked_valid():
			var delta: Vector3 = _current_pos() - Vector3(s["press_pos"])
			s["horizontal_displacement"] = _horizontal_length(delta)
	if s["released"] and _frame >= int(s["release_frame"]) + JUMP_TAIL_FRAMES:
		_finalize_step(s)


func _finalize_step(s: Dictionary) -> void:
	s["finalized"] = true
	if not s["had_press_pos"]:
		return
	var press_y := float(Vector3(s["press_pos"]).y)
	# "Up" is +y in 3D and -y in 2D (screen coordinates grow downward).
	if _space == "2d":
		s["up_gain"] = press_y - float(s["window_min_y"])
	else:
		s["up_gain"] = float(s["window_max_y"]) - press_y
	match String(s["expect"]):
		"move":
			s["satisfied"] = float(s["horizontal_displacement"]) >= _move_threshold
		"jump":
			s["satisfied"] = float(s["up_gain"]) >= _jump_threshold
		_:
			s["satisfied"] = null


func _send_action(action: String, pressed: bool, strength: float) -> void:
	# Event path first (feeds _input / _unhandled_input / just_pressed), then
	# the direct action-state path (feeds is_action_pressed / get_axis /
	# get_vector immediately, without waiting for input accumulation).
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = strength if pressed else 0.0
	Input.parse_input_event(ev)
	if pressed:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


# ── Body tracking ────────────────────────────────────────────────────────────


func _tracked_valid() -> bool:
	return _tracked != null and is_instance_valid(_tracked)


func _ensure_tracked() -> void:
	if _tracked_valid():
		return
	var had_tracked := not _tracked_path.is_empty()
	_tracked = null
	var scene_root := get_tree().current_scene
	if scene_root == null:
		return
	var requested := String(config.get("track", ""))
	var found: Node = null
	if not requested.is_empty():
		found = _find_requested(scene_root, requested)
	if found == null:
		found = _auto_detect(scene_root)
	if found == null:
		return
	_tracked = found
	_tracked_path = String(get_tree().root.get_path_to(found))
	_tracked_type = found.get_class()
	_space = "2d" if found is Node2D else "3d"
	_is_character_body = (found is CharacterBody2D) or (found is CharacterBody3D)
	_apply_space_thresholds()
	if had_tracked:
		_notes.append("tracked body was freed mid-run; re-tracking '%s'" % _tracked_path)
	if not _have_start:
		_have_start = true
		_start_pos = _current_pos()
		_last_pos = _start_pos
		_min_y = _start_pos.y
		_max_y = _start_pos.y


func _apply_space_thresholds() -> void:
	var is_2d := _space == "2d"
	_move_threshold = float(config.get("move_threshold", 8.0 if is_2d else 0.25))
	_jump_threshold = float(config.get("jump_threshold", 12.0 if is_2d else 0.3))
	_fall_limit = float(config.get("fall_limit", 1500.0 if is_2d else 25.0))


func _find_requested(scene_root: Node, requested: String) -> Node:
	var node := scene_root.get_node_or_null(NodePath(requested))
	if node == null:
		node = get_tree().root.get_node_or_null(NodePath(requested))
	if node == null:
		node = scene_root.find_child(requested.get_file(), true, false)
	if node != null and (node is Node2D or node is Node3D):
		return node
	return null


func _auto_detect(scene_root: Node) -> Node:
	for n in get_tree().get_nodes_in_group("player"):
		if n is Node2D or n is Node3D:
			return n
	var first_character: Node = null
	var first_rigid: Node = null
	var queue: Array = [scene_root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if first_character == null and ((n is CharacterBody2D) or (n is CharacterBody3D)):
			first_character = n
		if first_rigid == null and ((n is RigidBody2D) or (n is RigidBody3D)):
			first_rigid = n
		for child in n.get_children():
			queue.append(child)
	if first_character != null:
		return first_character
	return first_rigid


func _current_pos() -> Vector3:
	if _tracked is Node3D:
		return (_tracked as Node3D).global_position
	if _tracked is Node2D:
		var p: Vector2 = (_tracked as Node2D).global_position
		return Vector3(p.x, p.y, 0.0)
	return Vector3.ZERO


func _sample_tracked() -> void:
	if not _tracked_valid() or not _have_start:
		return
	_last_pos = _current_pos()
	_min_y = minf(_min_y, _last_pos.y)
	_max_y = maxf(_max_y, _last_pos.y)
	if _is_character_body and _tracked.is_on_floor():
		_on_floor_frames += 1


func _horizontal_length(delta: Vector3) -> float:
	if _space == "2d":
		return absf(delta.x)
	return Vector2(delta.x, delta.z).length()


# ── Report ───────────────────────────────────────────────────────────────────


func _fell_out_of_world() -> bool:
	if not _have_start:
		return false
	if _space == "2d":
		# 2D "down" is +y.
		return (_last_pos.y - _start_pos.y) > _fall_limit
	return (_start_pos.y - _last_pos.y) > _fall_limit


func _collect_problems() -> Array:
	var problems: Array = []
	var wants_tracking := not String(config.get("track", "")).is_empty()
	for s in _steps:
		if String(s["expect"]) != "none":
			wants_tracking = true
		if s["missing_action"]:
			problems.append(
				"input action '%s' is not in the InputMap — add it with add_input_action (or use a built-in ui_* action)" % s["action"]
			)
	if not _have_start:
		if wants_tracking:
			problems.append(
				"no trackable body found (looked for the 'player' group, then CharacterBody2D/3D, then RigidBody2D/3D) — pass track=<node path>"
			)
		return problems
	for s in _steps:
		if s["missing_action"] or not s["had_press_pos"]:
			continue
		if s["satisfied"] == false and String(s["expect"]) == "move":
			problems.append(
				"expected '%s' to move the body, but it moved %.3f (threshold %.3f) over %d held frames"
				% [s["action"], float(s["horizontal_displacement"]), _move_threshold, int(s["release_frame"]) - int(s["press_frame"])]
			)
		elif s["satisfied"] == false and String(s["expect"]) == "jump":
			if s["never_grounded"]:
				problems.append(
					"could not test '%s' to jump — the body was never on the floor to jump from within %d frames (no floor collision, or it spawned falling?)"
					% [s["action"], JUMP_SETTLE_WAIT_FRAMES]
				)
			else:
				problems.append(
					"expected '%s' to make the body jump, but its upward gain was %.3f (threshold %.3f)"
					% [s["action"], float(s["up_gain"]), _jump_threshold]
				)
	if _fell_out_of_world():
		problems.append(
			"tracked body ended %.1f below its start position — it likely fell out of the world (missing floor collision?)"
			% absf(_last_pos.y - _start_pos.y)
		)
	return problems


func _round3(v: float) -> float:
	return snappedf(v, 0.001)


func _pos_array(p: Vector3) -> Array:
	if _space == "2d":
		return [_round3(p.x), _round3(p.y)]
	return [_round3(p.x), _round3(p.y), _round3(p.z)]


func _finish() -> void:
	if _reported:
		return
	_reported = true
	var steps_out: Array = []
	for s in _steps:
		if not s["finalized"]:
			_finalize_step(s)
		steps_out.append({
			"action": s["action"],
			"expect": s["expect"],
			"pressed_at_frame": s["press_frame"],
			"held_frames": int(s["release_frame"]) - int(s["press_frame"]),
			"action_in_input_map": not s["missing_action"],
			"horizontal_displacement": _round3(float(s["horizontal_displacement"])),
			"up_gain": _round3(float(s["up_gain"])),
			"satisfied": s["satisfied"],
		})
	var report := {
		"probe": "gameplay",
		"completed": true,
		"frames": _frame,
		"tracked_node": _tracked_path if _have_start else null,
		"tracked_type": _tracked_type if _have_start else null,
		"space": _space if _have_start else null,
		"start_position": _pos_array(_start_pos) if _have_start else null,
		"end_position": _pos_array(_last_pos) if _have_start else null,
		"net_horizontal_distance": _round3(_horizontal_length(_last_pos - _start_pos)) if _have_start else null,
		"min_y": _round3(_min_y) if _have_start else null,
		"max_y": _round3(_max_y) if _have_start else null,
		"on_floor_frames": _on_floor_frames if (_have_start and _is_character_body) else null,
		"steps": steps_out,
		"problems": _collect_problems(),
		"notes": _notes,
	}
	print("GLADEKIT_PROBE_REPORT: %s" % JSON.stringify(report))
	get_tree().quit(0)
