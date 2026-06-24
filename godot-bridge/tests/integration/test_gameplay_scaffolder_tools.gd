extends GutTest

# Integration tests for the gameplay-scaffolder family's reuse-don't-refuse
# behavior:
#   create_2d_controller / create_game_manager / create_third_person_controller
#
# Each of these writes a SHARED, vetted GDScript template (platformer_controller.gd,
# game_manager.gd, third_person_controller.gd + orbit_camera.gd) and then builds
# its nodes. The script is a regenerable template, not a user asset — so once it
# already exists (the project built a game before), a SECOND game built in a fresh
# scene must REUSE the script and still build the nodes, NOT hard-refuse and abort
# the whole scaffold (which used to leave the new scene with no player / manager /
# overlay). These tests lock that in. They mirror the menu-family reuse tests in
# test_menu_flow_tools.gd.
#
# Convention (same as the other integration suites): tests operate on the
# currently-open edited scene root — open any scene first, preferably a throwaway
# scratch scene. Nodes the tools add to the root are torn down in after_each via a
# before/after child snapshot, so the active scene isn't polluted. Generated
# scripts go under a throwaway res:// dir so the real res://scripts is untouched.
#
# Root-type note: create_2d_controller refuses a Node3D root and
# create_third_person_controller refuses a Node2D root (each points 3D/2D callers
# at the other tool). A Control or plain Node root satisfies both. The two
# controller tests self-skip (pending) when the open root is the incompatible
# type, so the suite stays green whatever scene the dev has open;
# create_game_manager is root-agnostic and always runs.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const TEST_DIR := "res://_gladekit_gameplay_test"
const PLAYER_2D := "_GKTestPlayer2D"
const PLAYER_3D := "_GKTestPlayer3D"
const MANAGER := "_GKTestManager"

var _registry = null
var _root_children_before: Array = []


func should_skip_script():
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	_rm_dir(TEST_DIR)
	# Snapshot the root's children so after_each can remove exactly what a test
	# added (covers every node the scaffolders build — player, manager + HUD,
	# camera, ground, light — without hard-coding their names).
	var root := EditorInterface.get_edited_scene_root()
	_root_children_before = root.get_children() if root != null else []


func after_each() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		for child in root.get_children():
			if not _root_children_before.has(child):
				root.remove_child(child)
				child.free()
	_root_children_before = []
	_rm_dir(TEST_DIR)
	_registry = null


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# Free a direct child of the root by name (used to clear a just-built node so the
# next call has to build a fresh one and we exercise the script-reuse path).
func _free_root_child(node_name: String) -> void:
	var root := EditorInterface.get_edited_scene_root()
	var n := root.find_child(node_name, false, false)
	if n:
		root.remove_child(n)
		n.free()


func _rm_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ── create_game_manager (root-agnostic — always runs) ─────────────────────

func test_create_game_manager_reuses_existing_script() -> void:
	var script_path := TEST_DIR + "/game_manager.gd"
	var first := _run("create_game_manager", {"directory": TEST_DIR, "manager_name": MANAGER})
	assert_true(first.success, "first manager should build + write the shared script: %s" % first.get("message", ""))
	assert_true(FileAccess.file_exists(script_path), "shared game_manager.gd should exist after the first call")

	# Remove the manager so the one-per-scene group guard doesn't fire — this
	# simulates a fresh scene that has no manager but where the script already
	# exists from a prior game.
	_free_root_child(MANAGER)

	var second := _run("create_game_manager", {"directory": TEST_DIR, "manager_name": MANAGER})
	assert_true(second.success, "with the script present but no manager in scene, the tool must reuse the script and rebuild the manager, not refuse: %s" % second.get("message", ""))
	assert_ne(str(second.get("error", "")).find("Refused to overwrite"), 0, "must not fail with a script-overwrite refusal")
	assert_not_null(EditorInterface.get_edited_scene_root().find_child(MANAGER, false, false), "manager node should be rebuilt on the reuse path")


# ── create_2d_controller (needs a non-Node3D root) ────────────────────────

func test_create_2d_controller_reuses_existing_script() -> void:
	if EditorInterface.get_edited_scene_root() is Node3D:
		pending("open a 2D (Node2D) or Control/Node scene — create_2d_controller refuses a 3D root by design")
		return

	var script_path := TEST_DIR + "/platformer_controller.gd"
	var args := {
		"style": "platformer",
		"directory": TEST_DIR,
		"player_name": PLAYER_2D,
		"create_ground": false,  # keep the scene clean — we only assert the player
		"create_camera": false,
	}
	var first := _run("create_2d_controller", args)
	assert_true(first.success, "first controller should build + write the shared script: %s" % first.get("message", ""))
	assert_true(FileAccess.file_exists(script_path), "shared platformer_controller.gd should exist after the first call")

	# Drop the player so the second call must build a fresh one (and therefore
	# exercise the script-reuse path rather than just reusing the node).
	_free_root_child(PLAYER_2D)

	var second := _run("create_2d_controller", args)
	assert_true(second.success, "with the script present but no player in scene, the tool must reuse the script and rebuild the player, not refuse: %s" % second.get("message", ""))
	assert_ne(str(second.get("error", "")).find("Refused to overwrite"), 0, "must not fail with a script-overwrite refusal")
	assert_not_null(EditorInterface.get_edited_scene_root().find_child(PLAYER_2D, false, false), "player node should be rebuilt on the reuse path")


# ── create_third_person_controller (needs a non-Node2D root) ──────────────

func test_create_third_person_controller_reuses_existing_scripts() -> void:
	if EditorInterface.get_edited_scene_root() is Node2D:
		pending("open a 3D (Node3D) or Control/Node scene — create_third_person_controller refuses a 2D root by design")
		return

	var controller_path := TEST_DIR + "/third_person_controller.gd"
	var camera_path := TEST_DIR + "/orbit_camera.gd"
	var args := {
		"directory": TEST_DIR,
		"player_name": PLAYER_3D,
		"create_ground": false,
	}
	var first := _run("create_third_person_controller", args)
	assert_true(first.success, "first controller should build + write both shared scripts: %s" % first.get("message", ""))
	assert_true(FileAccess.file_exists(controller_path), "shared third_person_controller.gd should exist after the first call")
	assert_true(FileAccess.file_exists(camera_path), "shared orbit_camera.gd should exist after the first call")

	# Drop the player so the second call rebuilds it; the camera + scripts are
	# reused. Pre-fix the existing scripts would have aborted the whole scaffold.
	_free_root_child(PLAYER_3D)

	var second := _run("create_third_person_controller", args)
	assert_true(second.success, "with both scripts present, the tool must reuse them and rebuild the player, not refuse: %s" % second.get("message", ""))
	assert_ne(str(second.get("error", "")).find("Refused to overwrite"), 0, "must not fail with a script-overwrite refusal")
	assert_not_null(EditorInterface.get_edited_scene_root().find_child(PLAYER_3D, false, false), "player node should be rebuilt on the reuse path")


# ── create_moving_platform — the carry invariant ──────────────────────────
# The whole point of this tool is that the rider is an AnimatableBody (driven by
# its OWN transform via the PathMover), NOT a StaticBody. A StaticBody — or a
# body whose parent is moved instead of the body itself — does not report
# platform velocity, so a CharacterBody player is left floating when the platform
# reverses. These tests pin the AnimatableBody2D/3D rider + the correct
# per-dimension mover script so a regression to "hand-rolled" geometry is caught.

func test_create_moving_platform_3d_carry_uses_animatablebody3d() -> void:
	var r := _run("create_moving_platform", {"space": "3d", "directory": TEST_DIR, "name": "_GKPlat3D"})
	assert_true(r.success, "3D moving platform should build: %s" % r.get("message", ""))
	assert_eq(r.get("space", ""), "3d", "response should report 3d space")
	assert_eq(str(r.get("created_script", "")), TEST_DIR + "/path_mover_3d.gd", "3D uses the 3D mover script")
	assert_true(FileAccess.file_exists(TEST_DIR + "/path_mover_3d.gd"), "path_mover_3d.gd should be written")

	var root := EditorInterface.get_edited_scene_root()
	var path := root.get_node_or_null("_GKPlat3D")
	assert_true(path is Path3D, "the route node should be a Path3D")
	var rider := root.get_node_or_null(str(r.get("rider", "")))
	assert_true(rider is AnimatableBody3D, "rider MUST be an AnimatableBody3D (the carry invariant), not a StaticBody3D")
	assert_true((rider as AnimatableBody3D).sync_to_physics, "sync_to_physics must be on so the player is carried")
	# The mover drives the rider's OWN transform — it must NOT be parented under a
	# separately-moved PathFollow node.
	assert_true(rider.find_child("CollisionShape3D", false, false) is CollisionShape3D, "rider needs a CollisionShape3D")
	var mover := root.get_node_or_null(str(r.get("mover", "")))
	assert_not_null(mover, "PathMover node should exist")
	assert_eq(str(mover.get("rider")), str(mover.get_path_to(rider)), "PathMover must drive the rider directly")


func test_create_moving_platform_2d_carry_uses_animatablebody2d() -> void:
	var r := _run("create_moving_platform", {"space": "2d", "directory": TEST_DIR, "name": "_GKPlat2D"})
	assert_true(r.success, "2D moving platform should build: %s" % r.get("message", ""))
	assert_eq(r.get("space", ""), "2d", "response should report 2d space")
	assert_eq(str(r.get("created_script", "")), TEST_DIR + "/path_mover.gd", "2D uses the 2D mover script")

	var root := EditorInterface.get_edited_scene_root()
	assert_true(root.get_node_or_null("_GKPlat2D") is Path2D, "the route node should be a Path2D")
	var rider := root.get_node_or_null(str(r.get("rider", "")))
	assert_true(rider is AnimatableBody2D, "rider MUST be an AnimatableBody2D (the carry invariant), not a StaticBody2D")


func test_create_moving_platform_3d_target_keeps_existing_node_script() -> void:
	# A patrolling existing node: the tool drives its position, never its script.
	var root := EditorInterface.get_edited_scene_root()
	var enemy := CharacterBody3D.new()
	enemy.name = "_GKPatrol3D"
	root.add_child(enemy)
	enemy.owner = root

	var r := _run("create_moving_platform", {"space": "3d", "directory": TEST_DIR, "name": "_GKRoute3D", "target_path": "_GKPatrol3D"})
	assert_true(r.success, "sending an existing Node3D along a route should succeed: %s" % r.get("message", ""))
	var rider := root.get_node_or_null(str(r.get("rider", "")))
	assert_eq(rider, enemy, "the existing node should be the rider")
	assert_true(rider is CharacterBody3D, "the existing node's type is untouched (no AnimatableBody swap)")
