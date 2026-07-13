extends GutTest

# Unit tests for the headless gameplay probe's pure logic: step-schedule
# normalization, the up-gain / satisfied math in _finalize_step, and the
# problem-reporting that distinguishes a genuinely broken jump from a jump the
# probe could not test (body never on the floor). The frame-driven input
# driving and is_on_floor()-gated deferral are physics-timing dependent and are
# covered by the live probe runs; here we test the deterministic pieces that
# decide pass/fail, since a wrong threshold or a mislabeled problem would drive
# the self-heal loop to fix a non-bug (or miss a real one).

const GameplayProbe = preload("res://addons/com.gladekit.mcp-bridge/probe/gameplay_probe.gd")


func _probe() -> Node:
	# The probe is a Node; we instantiate it and call methods directly (no tree /
	# _physics_process). autofree keeps the run orphan-free.
	return autofree(GameplayProbe.new())


# ── _normalize_steps ─────────────────────────────────────────────────────────


func test_normalize_non_array_returns_empty() -> void:
	var p := _probe()
	assert_eq(p._normalize_steps("not an array", 10), [])
	assert_eq(p._normalize_steps(null, 10), [])


func test_normalize_skips_entries_without_action() -> void:
	var p := _probe()
	var steps: Array = p._normalize_steps([{"hold_frames": 5}, {"action": ""}, {"action": "jump"}], 10)
	assert_eq(steps.size(), 1, "only the entry with a non-empty action survives")
	assert_eq(String(steps[0]["action"]), "jump")


func test_normalize_schedules_sequentially_from_settle() -> void:
	var p := _probe()
	# settle=10; first press at 10, hold 20 -> release 30; next starts at
	# 30 + STEP_GAP_FRAMES(10) = 40.
	var steps: Array = p._normalize_steps(
		[{"action": "move_right", "hold_frames": 20}, {"action": "jump", "hold_frames": 15}], 10
	)
	assert_eq(int(steps[0]["press_frame"]), 10)
	assert_eq(int(steps[0]["release_frame"]), 30)
	assert_eq(int(steps[1]["press_frame"]), 40)
	assert_eq(int(steps[1]["release_frame"]), 55)


func test_normalize_explicit_start_frame_overrides_sequence() -> void:
	var p := _probe()
	var steps: Array = p._normalize_steps([{"action": "jump", "start_frame": 100, "hold_frames": 5}], 10)
	assert_eq(int(steps[0]["press_frame"]), 100)
	assert_eq(int(steps[0]["release_frame"]), 105)


func test_normalize_defaults_and_clamps() -> void:
	var p := _probe()
	var steps: Array = p._normalize_steps([{"action": "jump"}], 10)
	var s: Dictionary = steps[0]
	assert_eq(int(s["hold_frames"]), 30, "hold defaults to DEFAULT_HOLD_FRAMES")
	assert_eq(String(s["expect"]), "none", "expect defaults to none")
	# New defer/report fields must be present and zeroed so _advance_step /
	# _collect_problems never key-miss.
	assert_eq(int(s["press_deferrals"]), 0)
	assert_false(bool(s["never_grounded"]))
	assert_false(bool(s["had_press_pos"]))


func test_normalize_invalid_expect_falls_back_to_none() -> void:
	var p := _probe()
	var steps: Array = p._normalize_steps([{"action": "x", "expect": "teleport"}], 10)
	assert_eq(String(steps[0]["expect"]), "none")


# ── _finalize_step: up-gain + satisfied math ──────────────────────────────────


func _pressed_step(expect: String, press_y: float) -> Dictionary:
	# A step already "pressed" with a known press position, ready for the
	# vertical-envelope + displacement fields to be filled in per test.
	return {
		"action": "act",
		"expect": expect,
		"had_press_pos": true,
		"press_pos": Vector3(0.0, press_y, 0.0),
		"window_min_y": press_y,
		"window_max_y": press_y,
		"horizontal_displacement": 0.0,
		"up_gain": 0.0,
		"satisfied": null,
		"finalized": false,
		"never_grounded": false,
	}


func test_finalize_jump_3d_up_gain_from_max_y() -> void:
	var p := _probe()
	p._space = "3d"
	p._jump_threshold = 0.3
	var s := _pressed_step("jump", 1.0)
	s["window_max_y"] = 2.6  # rose 1.6 above the press position
	p._finalize_step(s)
	assert_almost_eq(float(s["up_gain"]), 1.6, 0.0001)
	assert_true(bool(s["satisfied"]), "1.6 clears the 0.3 jump threshold")


func test_finalize_jump_2d_up_gain_from_min_y() -> void:
	var p := _probe()
	# In 2D, up is -y (screen coords grow downward), so up_gain = press_y - min_y.
	p._space = "2d"
	p._jump_threshold = 12.0
	var s := _pressed_step("jump", 300.0)
	s["window_min_y"] = 280.0  # rose 20 px upward
	p._finalize_step(s)
	assert_almost_eq(float(s["up_gain"]), 20.0, 0.0001)
	assert_true(bool(s["satisfied"]))


func test_finalize_jump_below_threshold_is_unsatisfied() -> void:
	var p := _probe()
	p._space = "3d"
	p._jump_threshold = 0.3
	var s := _pressed_step("jump", 1.0)
	s["window_max_y"] = 1.1  # only rose 0.1
	p._finalize_step(s)
	assert_false(bool(s["satisfied"]))


func test_finalize_move_uses_horizontal_threshold() -> void:
	var p := _probe()
	p._space = "3d"
	p._move_threshold = 0.25
	var moved := _pressed_step("move", 1.0)
	moved["horizontal_displacement"] = 6.0
	p._finalize_step(moved)
	assert_true(bool(moved["satisfied"]))
	var still := _pressed_step("move", 1.0)
	still["horizontal_displacement"] = 0.05
	p._finalize_step(still)
	assert_false(bool(still["satisfied"]))


func test_finalize_expect_none_leaves_satisfied_null() -> void:
	var p := _probe()
	p._space = "3d"
	var s := _pressed_step("none", 1.0)
	s["window_max_y"] = 5.0
	p._finalize_step(s)
	assert_null(s["satisfied"], "a measure-only step never claims pass/fail")


func test_finalize_without_press_pos_is_noop() -> void:
	var p := _probe()
	var s := _pressed_step("jump", 1.0)
	s["had_press_pos"] = false
	p._finalize_step(s)
	assert_null(s["satisfied"])
	assert_true(bool(s["finalized"]))


# ── _collect_problems: never-grounded vs genuinely broken jump ────────────────


func _finalized_jump(never_grounded: bool) -> Dictionary:
	# A jump step that ran and did not gain height.
	return {
		"action": "jump",
		"expect": "jump",
		"missing_action": false,
		"had_press_pos": true,
		"satisfied": false,
		"never_grounded": never_grounded,
		"up_gain": 0.0,
		"horizontal_displacement": 0.0,
		"press_frame": 10,
		"release_frame": 20,
	}


func _prime_grounded(p: Node) -> void:
	# Mark a valid start + no fall so _collect_problems reaches the per-step pass.
	p._have_start = true
	p._space = "3d"
	p._fall_limit = 25.0
	p._start_pos = Vector3(0, 1, 0)
	p._last_pos = Vector3(0, 1, 0)
	p._jump_threshold = 0.3


func test_problem_real_broken_jump_reports_upward_gain() -> void:
	var p := _probe()
	_prime_grounded(p)
	p._steps = [_finalized_jump(false)]
	var problems: Array = p._collect_problems()
	assert_eq(problems.size(), 1)
	assert_string_contains(String(problems[0]), "upward gain")
	assert_false(String(problems[0]).contains("never on the floor"))


func test_problem_never_grounded_reports_distinct_message() -> void:
	var p := _probe()
	_prime_grounded(p)
	p._steps = [_finalized_jump(true)]
	var problems: Array = p._collect_problems()
	assert_eq(problems.size(), 1)
	# The honest-reporting distinction: a jump we could not test must NOT read as
	# a broken jump (that would trigger a bogus heal).
	assert_string_contains(String(problems[0]), "never on the floor")
	assert_false(String(problems[0]).contains("upward gain"))


func test_problem_satisfied_jump_produces_no_problem() -> void:
	var p := _probe()
	_prime_grounded(p)
	var ok := _finalized_jump(false)
	ok["satisfied"] = true
	p._steps = [ok]
	assert_eq(p._collect_problems().size(), 0)
