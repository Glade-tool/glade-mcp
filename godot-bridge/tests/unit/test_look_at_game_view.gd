extends GutTest

# Pure tests for look_at_game_view's dimension-inference helpers. The capture
# path itself needs a live editor viewport (EditorInterface) and is exercised
# manually / in editor; these cover the branch logic that decides which view to
# grab, which is the part most likely to silently regress.

const LookAtGameView = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/camera/look_at_game_view.gd")


func _tool() -> Object:
	return LookAtGameView.new()


# ── tool identity ─────────────────────────────────────────────────────────

func test_tool_name_and_read_only() -> void:
	var t := _tool()
	assert_eq(t.tool_name, "look_at_game_view")
	# Read-only: capture mutates nothing, so it must not require edit mode.
	assert_false(t.requires_edit_mode)


# ── _should_use_2d: explicit space arg wins (no editor access needed) ──────

func test_explicit_space_2d() -> void:
	assert_true(_tool()._should_use_2d({"space": "2d"}))


func test_explicit_space_3d() -> void:
	assert_false(_tool()._should_use_2d({"space": "3d"}))


func test_explicit_space_is_case_insensitive() -> void:
	assert_true(_tool()._should_use_2d({"space": "2D"}))


# ── _has_node_of_type: recursive type search ──────────────────────────────

func test_has_node_of_type_matches_root() -> void:
	var root := Node2D.new()
	add_child_autofree(root)
	assert_true(_tool()._has_node_of_type(root, "Node2D"))
	assert_true(_tool()._has_node_of_type(root, "CanvasItem"))  # base class
	assert_false(_tool()._has_node_of_type(root, "Camera3D"))


func test_has_node_of_type_matches_descendant() -> void:
	var root := Node3D.new()
	var cam := Camera2D.new()
	root.add_child(cam)
	add_child_autofree(root)
	assert_true(_tool()._has_node_of_type(root, "Camera2D"))
	assert_true(_tool()._has_node_of_type(root, "Node3D"))
	assert_false(_tool()._has_node_of_type(root, "Camera3D"))
