extends GutTest

# Pure tests for tool_utils.gd. No editor / scene tree access — safe to run
# headlessly.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


# ── parse_string_arg ──────────────────────────────────────────────────────

func test_parse_string_arg_returns_value_when_present() -> void:
	assert_eq(ToolUtils.parse_string_arg({"foo": "bar"}, "foo"), "bar")


func test_parse_string_arg_returns_default_when_missing() -> void:
	assert_eq(ToolUtils.parse_string_arg({}, "foo", "fallback"), "fallback")


func test_parse_string_arg_coerces_non_string_to_string() -> void:
	assert_eq(ToolUtils.parse_string_arg({"n": 42}, "n"), "42")


func test_parse_string_arg_null_falls_back_to_default() -> void:
	assert_eq(ToolUtils.parse_string_arg({"foo": null}, "foo", "fallback"), "fallback")


# ── parse_int_arg ─────────────────────────────────────────────────────────

func test_parse_int_happy_path() -> void:
	assert_eq(ToolUtils.parse_int_arg({"n": 5}, "n"), 5)


func test_parse_int_string_form() -> void:
	assert_eq(ToolUtils.parse_int_arg({"n": "7"}, "n"), 7)


func test_parse_int_float_coerced() -> void:
	assert_eq(ToolUtils.parse_int_arg({"n": 3.7}, "n"), 3)


func test_parse_int_garbage_falls_back_to_default() -> void:
	assert_eq(ToolUtils.parse_int_arg({"n": "not a number"}, "n", 99), 99)


# ── parse_bool_arg ────────────────────────────────────────────────────────

func test_parse_bool_native_true() -> void:
	assert_true(ToolUtils.parse_bool_arg({"b": true}, "b"))


func test_parse_bool_string_true() -> void:
	assert_true(ToolUtils.parse_bool_arg({"b": "true"}, "b"))


func test_parse_bool_string_yes() -> void:
	assert_true(ToolUtils.parse_bool_arg({"b": "yes"}, "b"))


func test_parse_bool_string_1() -> void:
	assert_true(ToolUtils.parse_bool_arg({"b": "1"}, "b"))


func test_parse_bool_missing_returns_default() -> void:
	assert_false(ToolUtils.parse_bool_arg({}, "b", false))


# ── parse_path_arg ────────────────────────────────────────────────────────

func test_parse_path_arg_normalizes_relative() -> void:
	assert_eq(ToolUtils.parse_path_arg({"p": "foo/bar.gd"}, "p"), "res://foo/bar.gd")


func test_parse_path_arg_preserves_res_prefix() -> void:
	assert_eq(ToolUtils.parse_path_arg({"p": "res://foo/bar.gd"}, "p"), "res://foo/bar.gd")


func test_parse_path_arg_preserves_user_prefix() -> void:
	assert_eq(ToolUtils.parse_path_arg({"p": "user://save.dat"}, "p"), "user://save.dat")


func test_parse_path_arg_strips_leading_slash() -> void:
	assert_eq(ToolUtils.parse_path_arg({"p": "/foo/bar.gd"}, "p"), "res://foo/bar.gd")


# ── parse_vector3_arg ─────────────────────────────────────────────────────

func test_parse_vector3_string_form() -> void:
	var v: Vector3 = ToolUtils.parse_vector3_arg({"pos": "1.5,2,3.25"}, "pos")
	assert_eq(v, Vector3(1.5, 2, 3.25))


func test_parse_vector3_array_form() -> void:
	var v: Vector3 = ToolUtils.parse_vector3_arg({"pos": [1, 2, 3]}, "pos")
	assert_eq(v, Vector3(1, 2, 3))


func test_parse_vector3_dict_form() -> void:
	var v: Vector3 = ToolUtils.parse_vector3_arg({"pos": {"x": 4, "y": 5, "z": 6}}, "pos")
	assert_eq(v, Vector3(4, 5, 6))


func test_parse_vector3_native_vector3_passes_through() -> void:
	var v: Vector3 = ToolUtils.parse_vector3_arg({"pos": Vector3(7, 8, 9)}, "pos")
	assert_eq(v, Vector3(7, 8, 9))


func test_parse_vector3_missing_returns_default() -> void:
	var d := Vector3(0.5, 0.5, 0.5)
	var v: Vector3 = ToolUtils.parse_vector3_arg({}, "pos", d)
	assert_eq(v, d)


func test_parse_vector3_malformed_string_returns_default() -> void:
	var d := Vector3(-1, -1, -1)
	var v: Vector3 = ToolUtils.parse_vector3_arg({"pos": "1,2"}, "pos", d)
	assert_eq(v, d)


# ── serialize_vector3 ─────────────────────────────────────────────────────

func test_serialize_vector3_format() -> void:
	# Loose contract: contains all three components, comma-separated.
	var s := ToolUtils.serialize_vector3(Vector3(1, 2, 3))
	assert_string_contains(s, ",")
	assert_string_contains(s, "1")
	assert_string_contains(s, "2")
	assert_string_contains(s, "3")


# ── success / error response builders ─────────────────────────────────────

func test_success_shape() -> void:
	var r: Dictionary = ToolUtils.success("ok", {"a": 1})
	assert_true(r.success)
	assert_eq(r.message, "ok")
	assert_eq(r.a, 1)


func test_error_shape() -> void:
	var r: Dictionary = ToolUtils.error("boom", {"a": 1})
	assert_false(r.success)
	assert_eq(r.error, "boom")
	assert_eq(r.message, "boom")
	assert_eq(r.a, 1)


# ── require_string ────────────────────────────────────────────────────────

func test_require_string_missing() -> void:
	assert_string_contains(ToolUtils.require_string({}, "foo"), "Missing")


func test_require_string_empty() -> void:
	assert_string_contains(ToolUtils.require_string({"foo": ""}, "foo"), "empty")


func test_require_string_null() -> void:
	assert_string_contains(ToolUtils.require_string({"foo": null}, "foo"), "null")


func test_require_string_present() -> void:
	assert_eq(ToolUtils.require_string({"foo": "bar"}, "foo"), "")


# ── error_with_solutions ──────────────────────────────────────────────────

func test_error_with_solutions_shape() -> void:
	var r: Dictionary = ToolUtils.error_with_solutions("nope", ["try A", "try B"], {"ctx": 1})
	assert_false(r.success)
	assert_eq(r.error, "nope")
	assert_eq(r.possible_solutions, ["try A", "try B"])
	assert_eq(r.ctx, 1)


# ── normalize_args (camelCase → snake_case) ───────────────────────────────

func test_normalize_args_camel_to_snake() -> void:
	var out: Dictionary = ToolUtils.normalize_args({"nodePath": "X", "parentPath": "Y"})
	assert_true(out.has("node_path"))
	assert_true(out.has("parent_path"))
	assert_eq(out["node_path"], "X")
	assert_eq(out["parent_path"], "Y")


func test_normalize_args_snake_wins_on_collision() -> void:
	# When both snake_case and camelCase keys are present, snake_case wins.
	var out: Dictionary = ToolUtils.normalize_args({"node_path": "winner", "nodePath": "loser"})
	assert_eq(out["node_path"], "winner")
	# Camel-case version should NOT have been re-added.
	assert_false(out.has("nodePath"))


func test_normalize_args_preserves_snake_case_only() -> void:
	var out: Dictionary = ToolUtils.normalize_args({"node_path": "A", "name": "B"})
	assert_eq(out["node_path"], "A")
	assert_eq(out["name"], "B")


func test_normalize_args_empty() -> void:
	var out: Dictionary = ToolUtils.normalize_args({})
	assert_eq(out.size(), 0)


func test_normalize_args_mixed_with_complex_camel() -> void:
	# Multi-cap edges: confirmExistingFileModification → confirm_existing_file_modification
	var out: Dictionary = ToolUtils.normalize_args({"confirmExistingFileModification": true})
	assert_true(out.has("confirm_existing_file_modification"))
	assert_eq(out["confirm_existing_file_modification"], true)


# ── safe_instantiate_class ────────────────────────────────────────────────

func test_safe_instantiate_class_known_builtin() -> void:
	var r: Dictionary = ToolUtils.safe_instantiate_class("Node3D")
	assert_not_null(r["instance"])
	assert_eq(r["error"], "")
	assert_eq(r["source"], "class_db")
	(r["instance"] as Object).free()


func test_safe_instantiate_class_unknown_class() -> void:
	var r: Dictionary = ToolUtils.safe_instantiate_class("DefinitelyNotARealClass")
	assert_null(r["instance"])
	assert_string_contains(r["error"], "no class")


func test_safe_instantiate_class_rejects_injection() -> void:
	# Classes with non-identifier characters must be rejected before
	# hitting ClassDB.
	var r: Dictionary = ToolUtils.safe_instantiate_class("Node3D; system('rm -rf')")
	assert_null(r["instance"])
	assert_string_contains(r["error"], "invalid characters")


func test_safe_instantiate_class_empty() -> void:
	var r: Dictionary = ToolUtils.safe_instantiate_class("")
	assert_null(r["instance"])


# ── compare_versions ──────────────────────────────────────────────────────

func test_compare_versions_equal() -> void:
	assert_eq(ToolUtils.compare_versions("4.3", "4.3"), 0)
	assert_eq(ToolUtils.compare_versions("4.3.0", "4.3"), 0)


func test_compare_versions_less_than() -> void:
	assert_eq(ToolUtils.compare_versions("4.3", "4.4"), -1)
	assert_eq(ToolUtils.compare_versions("4.3.5", "4.4.0"), -1)


func test_compare_versions_greater_than() -> void:
	assert_eq(ToolUtils.compare_versions("4.4", "4.3"), 1)
	assert_eq(ToolUtils.compare_versions("4.4.1", "4.4"), 1)


func test_compare_versions_malformed_treated_as_zero() -> void:
	# Garbage components should fall back to 0, not crash.
	assert_eq(ToolUtils.compare_versions("4.x", "4.0"), 0)


# ── 2D / 3D classification + space resolution ─────────────────────────────

func test_classify_class_space_3d() -> void:
	assert_eq(ToolUtils.classify_class_space("Node3D"), "3d")
	assert_eq(ToolUtils.classify_class_space("Camera3D"), "3d")
	assert_eq(ToolUtils.classify_class_space("CharacterBody3D"), "3d")


func test_classify_class_space_2d() -> void:
	assert_eq(ToolUtils.classify_class_space("Node2D"), "2d")
	assert_eq(ToolUtils.classify_class_space("Sprite2D"), "2d")
	assert_eq(ToolUtils.classify_class_space("TileMapLayer"), "2d")


func test_classify_class_space_ui() -> void:
	assert_eq(ToolUtils.classify_class_space("Control"), "ui")
	assert_eq(ToolUtils.classify_class_space("Button"), "ui")
	assert_eq(ToolUtils.classify_class_space("CanvasLayer"), "ui")


func test_classify_class_space_unknown() -> void:
	assert_eq(ToolUtils.classify_class_space(""), "unknown")
	assert_eq(ToolUtils.classify_class_space("NotARealClass_xyz"), "unknown")
	# A plain Node is neither 2D nor 3D nor UI.
	assert_eq(ToolUtils.classify_class_space("Node"), "other")


func test_resolve_space_explicit_wins() -> void:
	# An explicit arg is honored regardless of scene context (none here).
	assert_eq(ToolUtils.resolve_space({"space": "2d"}), "2d")
	assert_eq(ToolUtils.resolve_space({"space": "3d"}), "3d")
	# Normalizes "2"/"3".
	assert_eq(ToolUtils.resolve_space({"space": "2"}), "2d")
	assert_eq(ToolUtils.resolve_space({"space": "3"}), "3d")


func test_resolve_space_invalid_explicit_passthrough() -> void:
	# An invalid explicit value returns lowercased for the caller to error on.
	assert_eq(ToolUtils.resolve_space({"space": "2.5d"}), "2.5d")


func test_resolve_space_falls_back_without_scene() -> void:
	# No editor scene in the headless test context, so empty/missing space
	# falls back to the provided default rather than crashing.
	assert_eq(ToolUtils.resolve_space({}), "3d")
	assert_eq(ToolUtils.resolve_space({}, "2d"), "2d")
	assert_eq(ToolUtils.resolve_space({"space": ""}), "3d")


# ── deselect_before_free ──────────────────────────────────────────────────

func test_deselect_before_free_null_is_noop() -> void:
	# Must not crash on null or freed nodes (headless test context has no
	# EditorInterface, so this also exercises the no-editor early return).
	ToolUtils.deselect_before_free(null)
	var n := Node.new()
	n.free()
	ToolUtils.deselect_before_free(n)
	pass_test("deselect_before_free tolerated null and freed nodes")


# ── apply_script_properties (reused-existing-script collision guard) ───────

# Build a Node carrying a tiny script that declares only the given `var` names —
# stands in for a user's own same-named script the bridge reused instead of the
# vetted template.
func _node_with_vars(var_names: Array) -> Node:
	var src := "extends Node\n"
	for v in var_names:
		src += "var %s = null\n" % v
	var script := GDScript.new()
	script.source_code = src
	script.reload()
	var node := Node.new()
	node.set_script(script)
	return node


func test_apply_script_properties_sets_known_and_reports_missing() -> void:
	# The script has `speed` but NOT `route`: the declared knob must land, the
	# missing one must come back named — never silently dropped (the bug where a
	# moving platform "did nothing" because route/speed had nowhere to go).
	var node := _node_with_vars(["speed"])
	var dropped := ToolUtils.apply_script_properties(node, {
		"speed": 7.0,
		"route": "0,0,0;4,0,0",
	})
	assert_eq(node.get("speed"), 7.0, "a declared property must be set")
	assert_eq(Array(dropped), ["route"], "a missing property must be reported")
	node.free()


func test_apply_script_properties_empty_when_all_present() -> void:
	# The common case: the vetted template WAS written, so every knob exists and
	# nothing is reported — the collision signal stays quiet without a collision.
	var node := _node_with_vars(["a", "b"])
	var dropped := ToolUtils.apply_script_properties(node, {"a": 1, "b": 2})
	assert_eq(node.get("a"), 1)
	assert_eq(node.get("b"), 2)
	assert_true(dropped.is_empty(), "no warning when every property exists")
	node.free()


func test_apply_script_properties_null_node_is_safe() -> void:
	var dropped := ToolUtils.apply_script_properties(null, {"x": 1})
	assert_true(dropped.is_empty(), "null node must not crash and reports nothing")


func test_reused_script_warning_names_dropped_and_path() -> void:
	var msg := ToolUtils.reused_script_warning(
		PackedStringArray(["route", "speed"]), "res://scripts/moving_platform.gd"
	)
	assert_string_contains(msg, "route")
	assert_string_contains(msg, "speed")
	assert_string_contains(msg, "res://scripts/moving_platform.gd")
	assert_string_contains(msg, "overwrite=true")
