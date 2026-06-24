extends GutTest

# Unit coverage for ws_server.gd helpers that are testable without sockets
# or an editor session.

const WsServer = preload("res://addons/com.gladekit.mcp-bridge/bridge/ws_server.gd")


# Regression guard for the 0.6.4 orphan-reap startup notice: the original
# inline form applied % to only the last concatenated literal (one %d, two
# args — a runtime format error on the start() path after plugin hot-reload).
# The helper must consume both args and produce a fully-substituted message.
func test_format_reap_message_substitutes_both_counts() -> void:
	var msg := WsServer._format_reap_message(3, 1)
	assert_string_contains(msg, "reaped 3 orphan play session(s)")
	assert_string_contains(msg, "(1 still running and killed)")
	assert_false(msg.contains("%d"), "All placeholders must be substituted")


func test_format_reap_message_zero_killed() -> void:
	var msg := WsServer._format_reap_message(1, 0)
	assert_string_contains(msg, "reaped 1 orphan play session(s)")
	assert_string_contains(msg, "(0 still running and killed)")


# ── Main-thread stall watchdog: _split_expired_dispatches ─────────────────
# The expiry policy is a static pure function so the watchdog's behavior is
# testable without threads, sockets, or a wedged editor.

const STALL_THRESHOLD_MSEC := 25_000


func _dispatch_entry(request_id: String, queued_at_msec: int) -> Dictionary:
	return {
		"peer": null,
		"request": {"endpoint": "tools/execute", "toolName": "get_project_info"},
		"request_id": request_id,
		"queued_at_msec": queued_at_msec,
	}


func test_fresh_dispatches_stay_queued() -> void:
	var split: Dictionary = WsServer._split_expired_dispatches(
		[_dispatch_entry("a", 1_000)], 2_000, STALL_THRESHOLD_MSEC
	)
	assert_eq(split["expired"].size(), 0)
	assert_eq(split["remaining"].size(), 1)


func test_stale_dispatches_expire() -> void:
	var split: Dictionary = WsServer._split_expired_dispatches(
		[_dispatch_entry("a", 0)], STALL_THRESHOLD_MSEC + 1, STALL_THRESHOLD_MSEC
	)
	assert_eq(split["expired"].size(), 1)
	assert_eq(split["remaining"].size(), 0)
	assert_eq(split["expired"][0]["request_id"], "a")


func test_stall_threshold_boundary_is_inclusive() -> void:
	# Exactly at the threshold counts as expired — the watchdog must answer
	# before the client's own timeout, so erring early is the safe side.
	var split: Dictionary = WsServer._split_expired_dispatches(
		[_dispatch_entry("a", 0)], STALL_THRESHOLD_MSEC, STALL_THRESHOLD_MSEC
	)
	assert_eq(split["expired"].size(), 1)


func test_mixed_queue_splits_and_preserves_order() -> void:
	var split: Dictionary = WsServer._split_expired_dispatches(
		[
			_dispatch_entry("old1", 0),
			_dispatch_entry("fresh1", 90_000),
			_dispatch_entry("old2", 10),
			_dispatch_entry("fresh2", 99_000),
		],
		100_000,
		STALL_THRESHOLD_MSEC
	)
	assert_eq(split["expired"].size(), 2)
	assert_eq(split["remaining"].size(), 2)
	assert_eq(split["expired"][0]["request_id"], "old1")
	assert_eq(split["expired"][1]["request_id"], "old2")
	assert_eq(split["remaining"][0]["request_id"], "fresh1")
	assert_eq(split["remaining"][1]["request_id"], "fresh2")


func test_dispatch_without_stamp_is_treated_as_fresh() -> void:
	# Defensive: an unstamped entry must never expire (it would get an error
	# response for work the main thread may still legitimately run).
	var unstamped: Dictionary = {"peer": null, "request": {}, "request_id": "x"}
	var split: Dictionary = WsServer._split_expired_dispatches(
		[unstamped], 9_999_999, STALL_THRESHOLD_MSEC
	)
	assert_eq(split["expired"].size(), 0)
	assert_eq(split["remaining"].size(), 1)


func test_empty_queue_returns_empty_split() -> void:
	var split: Dictionary = WsServer._split_expired_dispatches([], 1_000, STALL_THRESHOLD_MSEC)
	assert_eq(split["expired"].size(), 0)
	assert_eq(split["remaining"].size(), 0)


# ── created-node detection: _collect_instance_ids / _collect_new_top_level_nodes
# Pure scene-tree diff helpers backing the dispatcher's `created_nodes` (node
# revert for template/scaffolder tools). Editor-free: they operate on a plain
# Node tree, so they're testable under GUT's headless runner.

func test_collect_instance_ids_gathers_all_descendants() -> void:
	var root := Node.new()
	var a := Node.new()
	var b := Node.new()
	var a_child := Node.new()
	root.add_child(a)
	root.add_child(b)
	a.add_child(a_child)

	var ids: Dictionary = {}
	WsServer._collect_instance_ids(root, ids)
	# Descendants only (not the root itself).
	assert_eq(ids.size(), 3)
	assert_true(ids.has(a.get_instance_id()))
	assert_true(ids.has(b.get_instance_id()))
	assert_true(ids.has(a_child.get_instance_id()))
	assert_false(ids.has(root.get_instance_id()))
	root.free()


func test_collect_new_top_level_nodes_reports_subtree_roots_only() -> void:
	# Pre-existing tree: root > A, B.
	var root := Node.new()
	var a := Node.new()
	a.name = "A"
	var b := Node.new()
	b.name = "B"
	root.add_child(a)
	root.add_child(b)

	# Snapshot BEFORE the "tool" mutates the tree.
	var before: Dictionary = {}
	WsServer._collect_instance_ids(root, before)

	# The "tool" adds: C under root, D under existing A, and a new subtree
	# E > F under root.
	var c := Node.new()
	c.name = "C"
	var d := Node.new()
	d.name = "D"
	var e := Node.new()
	e.name = "E"
	var f := Node.new()
	f.name = "F"
	root.add_child(c)
	a.add_child(d)
	root.add_child(e)
	e.add_child(f)

	var new_nodes: Array = []
	WsServer._collect_new_top_level_nodes(root, before, new_nodes)

	# C, D, E are top-level new. F is nested under the new E → excluded
	# (deleting E removes F on revert).
	assert_eq(new_nodes.size(), 3, "exactly the 3 subtree roots, not F")
	assert_true(new_nodes.has(c))
	assert_true(new_nodes.has(d), "a new node under a PRE-EXISTING parent is top-level")
	assert_true(new_nodes.has(e))
	assert_false(new_nodes.has(f), "a new node under a NEW parent is redundant")
	root.free()


func test_collect_new_top_level_nodes_empty_when_nothing_added() -> void:
	var root := Node.new()
	var a := Node.new()
	root.add_child(a)
	var before: Dictionary = {}
	WsServer._collect_instance_ids(root, before)

	var new_nodes: Array = []
	WsServer._collect_new_top_level_nodes(root, before, new_nodes)
	assert_eq(new_nodes.size(), 0, "no mutations → no created nodes")
	root.free()
