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
