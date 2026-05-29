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
