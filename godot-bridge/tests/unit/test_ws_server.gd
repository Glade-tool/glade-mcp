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
