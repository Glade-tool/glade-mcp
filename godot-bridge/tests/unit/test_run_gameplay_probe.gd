extends GutTest

# Unit tests for run_gameplay_probe's input-contract validation: the step
# sanitizer (what the model is allowed to pass) and the numeric coercion that
# tolerates int / float / numeric-string args. The spawn path itself needs a
# live editor + subprocess and is covered by the live probe runs; this locks
# down the arg parsing that decides whether a probe request is accepted or
# rejected with a helpful error.

const RunGameplayProbeTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/runtime/run_gameplay_probe.gd")


func _tool() -> RefCounted:
	return RunGameplayProbeTool.new()


func test_tool_name() -> void:
	assert_eq(_tool().tool_name, "run_gameplay_probe")


# ── _sanitize_steps ──────────────────────────────────────────────────────────


func test_sanitize_null_is_empty_smoke_test() -> void:
	# Absent steps is allowed — the probe then runs as a pure load/fall smoke test.
	var r: Dictionary = _tool()._sanitize_steps(null)
	assert_false(r.has("error"))
	assert_eq(r["steps"], [])


func test_sanitize_non_array_errors() -> void:
	var r: Dictionary = _tool()._sanitize_steps({"action": "jump"})
	assert_true(r.has("error"))


func test_sanitize_rejects_too_many_steps() -> void:
	var many: Array = []
	for i in range(17):  # MAX_STEPS is 16
		many.append({"action": "jump"})
	var r: Dictionary = _tool()._sanitize_steps(many)
	assert_true(r.has("error"))
	assert_string_contains(String(r["error"]), "capped")


func test_sanitize_rejects_non_dict_entry() -> void:
	var r: Dictionary = _tool()._sanitize_steps(["jump"])
	assert_true(r.has("error"))


func test_sanitize_rejects_empty_action() -> void:
	var r: Dictionary = _tool()._sanitize_steps([{"hold_frames": 10}])
	assert_true(r.has("error"))
	assert_string_contains(String(r["error"]), "action")


func test_sanitize_rejects_bad_expect() -> void:
	var r: Dictionary = _tool()._sanitize_steps([{"action": "jump", "expect": "fly"}])
	assert_true(r.has("error"))
	assert_string_contains(String(r["error"]), "expect")


func test_sanitize_accepts_and_passes_through_valid_fields() -> void:
	var r: Dictionary = _tool()._sanitize_steps(
		[{"action": "move_right", "hold_frames": 60, "expect": "move", "strength": 0.5, "start_frame": 20}]
	)
	assert_false(r.has("error"))
	var s: Dictionary = (r["steps"] as Array)[0]
	assert_eq(String(s["action"]), "move_right")
	assert_eq(int(s["hold_frames"]), 60)
	assert_eq(String(s["expect"]), "move")
	assert_almost_eq(float(s["strength"]), 0.5, 0.0001)
	assert_eq(int(s["start_frame"]), 20)


func test_sanitize_omits_unset_optional_fields() -> void:
	# Only action given -> the sanitized step carries just the action, letting the
	# probe apply its own defaults (hold/expect/etc.).
	var r: Dictionary = _tool()._sanitize_steps([{"action": "jump"}])
	var s: Dictionary = (r["steps"] as Array)[0]
	assert_false(s.has("hold_frames"))
	assert_false(s.has("expect"))
	assert_false(s.has("strength"))


func test_sanitize_clamps_numeric_ranges() -> void:
	var r: Dictionary = _tool()._sanitize_steps(
		[{"action": "jump", "hold_frames": 100000, "strength": 5.0, "start_frame": -50}]
	)
	var s: Dictionary = (r["steps"] as Array)[0]
	assert_eq(int(s["hold_frames"]), 1200, "hold clamps to the 1200 ceiling")
	assert_almost_eq(float(s["strength"]), 1.0, 0.0001, "strength clamps to 1.0")
	assert_eq(int(s["start_frame"]), 0, "negative start clamps to 0")


func test_sanitize_coerces_string_numbers() -> void:
	# Args can arrive as numeric strings depending on the JSON path.
	var r: Dictionary = _tool()._sanitize_steps([{"action": "jump", "hold_frames": "45"}])
	var s: Dictionary = (r["steps"] as Array)[0]
	assert_eq(int(s["hold_frames"]), 45)


# ── _coerce_num ──────────────────────────────────────────────────────────────


func test_coerce_num_int_float_string_and_fallback() -> void:
	assert_almost_eq(RunGameplayProbeTool._coerce_num(7, 1.0), 7.0, 0.0001)
	assert_almost_eq(RunGameplayProbeTool._coerce_num(2.5, 1.0), 2.5, 0.0001)
	assert_almost_eq(RunGameplayProbeTool._coerce_num("3.5", 1.0), 3.5, 0.0001)
	# Non-numeric string and other types fall back to the default.
	assert_almost_eq(RunGameplayProbeTool._coerce_num("abc", 9.0), 9.0, 0.0001)
	assert_almost_eq(RunGameplayProbeTool._coerce_num(null, 9.0), 9.0, 0.0001)
	assert_almost_eq(RunGameplayProbeTool._coerce_num([], 9.0), 9.0, 0.0001)
