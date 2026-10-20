extends GutTest

# Pure tests for set_node_transform's apply paths. _apply_2d/_apply_3d act on a
# node passed in directly, so a free-standing Node2D/Node3D is enough: no
# edited scene or EditorInterface needed, safe to run headlessly. execute()
# itself resolves the node through the editor and is covered by integration.

const SetNodeTransformTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/scene/set_node_transform.gd")


func _tool():
	return SetNodeTransformTool.new()


# ── 2D: the documented "x,y" form ─────────────────────────────────────────

func test_2d_position_accepts_two_component_string() -> void:
	# Used to go through parse_vector3_arg, which rejects 2 parts, so the node
	# silently stayed put while the tool reported success.
	var n: Node2D = autofree(Node2D.new())
	var r: Dictionary = _tool()._apply_2d(n, {"position": "100,200"}, false, "set", "Player")
	assert_true(r.success)
	assert_eq(n.position, Vector2(100, 200))


func test_2d_position_still_accepts_three_component_string() -> void:
	var n: Node2D = autofree(Node2D.new())
	_tool()._apply_2d(n, {"position": "5,6,0"}, false, "set", "Player")
	assert_eq(n.position, Vector2(5, 6))


func test_2d_position_add() -> void:
	var n: Node2D = autofree(Node2D.new())
	n.position = Vector2(1, 1)
	_tool()._apply_2d(n, {"position": "2,3"}, false, "add", "Player")
	assert_eq(n.position, Vector2(3, 4))


func test_2d_scale_accepts_two_component_string() -> void:
	var n: Node2D = autofree(Node2D.new())
	_tool()._apply_2d(n, {"scale": "2,3"}, false, "set", "Player")
	assert_eq(n.scale, Vector2(2, 3))


# ── 3D: unchanged happy path ──────────────────────────────────────────────

func test_3d_position_full_vector() -> void:
	var n: Node3D = autofree(Node3D.new())
	_tool()._apply_3d(n, {"position": "0,3,0"}, false, "set", "Player")
	assert_eq(n.position, Vector3(0, 3, 0))
