extends GutTest

# Unit tests for the GameManager win conditions baked into create_game_manager's
# vetted MANAGER_SRC template. Covers:
#   - explicit score target (score_to_win > 0) still wins at the target
#   - collect-them-all default (score_to_win == 0) wins once the collectibles
#     group is empty, but ONLY for a level that actually had collectibles
#   - a score-only level (no collectibles) never auto-wins
#
# These exercise the runtime decision logic synchronously: the script is loaded
# from the template, instantiated, parented (so get_tree() resolves), and its
# win helpers are driven directly. The deferred add_score -> _check_collect_all_win
# wiring + queue_free timing is covered by in-editor play + the integration
# suite; here we pin the decision itself.

const CreateGameManagerTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/script/create_game_manager.gd")

const TMP_SCRIPT := "res://_gladekit_gm_unit_test.gd"
const COLLECTIBLES_GROUP := "collectibles"

var _manager_script: GDScript = null
var _spawned: Array = []


func before_all() -> void:
	# Materialize the template to a loadable script once.
	var f := FileAccess.open(TMP_SCRIPT, FileAccess.WRITE)
	f.store_string(CreateGameManagerTool.MANAGER_SRC)
	f.close()
	_manager_script = load(TMP_SCRIPT)


func after_all() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SCRIPT))


func after_each() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.free()
	_spawned.clear()


# Build a manager node from the template, parented under the test so get_tree()
# (and thus the group lookups) resolve.
func _make_manager() -> Node:
	var mgr := Node.new()
	mgr.set_script(_manager_script)
	add_child(mgr)
	_spawned.append(mgr)
	return mgr


# A throwaway node that sits in the "collectibles" group, like a real pickup.
func _add_collectible() -> Node:
	var c := Node.new()
	add_child(c)
	c.add_to_group(COLLECTIBLES_GROUP)
	_spawned.append(c)
	return c


func test_explicit_score_target_still_wins() -> void:
	var mgr := _make_manager()
	mgr.set("score_to_win", 3)
	mgr.add_score(3)
	assert_true(mgr.get("_finished"), "reaching score_to_win must win")
	assert_eq(mgr.get("score"), 3)


func test_explicit_target_not_won_below_threshold() -> void:
	var mgr := _make_manager()
	mgr.set("score_to_win", 5)
	mgr.add_score(2)
	assert_false(mgr.get("_finished"), "below the target the game must not end")


func test_collect_all_wins_when_group_emptied() -> void:
	var mgr := _make_manager()
	# Simulate "this level had collectibles" (the deferred _detect_collectibles
	# sets this at runtime; we set it directly to keep the test synchronous).
	mgr.set("score_to_win", 0)
	mgr.set("_had_collectibles", true)
	# No nodes in the collectibles group → all collected → win.
	mgr.call("_check_collect_all_win")
	assert_true(mgr.get("_finished"), "collect-all: an empty collectibles group must win")


func test_collect_all_does_not_win_while_collectibles_remain() -> void:
	var mgr := _make_manager()
	mgr.set("score_to_win", 0)
	mgr.set("_had_collectibles", true)
	_add_collectible()  # one pickup still in the world
	mgr.call("_check_collect_all_win")
	assert_false(mgr.get("_finished"), "collect-all must not win while a collectible remains")


func test_score_only_game_never_collect_all_wins() -> void:
	var mgr := _make_manager()
	# Level shipped with no collectibles → _had_collectibles stays false.
	mgr.set("score_to_win", 0)
	mgr.set("_had_collectibles", false)
	mgr.call("_check_collect_all_win")
	assert_false(mgr.get("_finished"), "a score-only level must not auto-win on an empty collectibles group")
