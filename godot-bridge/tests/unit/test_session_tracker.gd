extends GutTest

# Unit tests for SessionTracker's two distinct sets:
#   - _created_paths: session-wide, guards user code (modify_script gate)
#   - _recent_writes: per-CALL buffer the dispatcher drains into a tool
#     response's `written_scripts`, so clients can diff/revert scripts a
#     template tool wrote internally. No editor dependencies.

const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")


func before_each() -> void:
	SessionTracker.clear()


func after_each() -> void:
	SessionTracker.clear()


func test_mark_created_feeds_both_session_set_and_recent_buffer() -> void:
	SessionTracker.mark_created("res://scripts/path_mover_3d.gd")
	assert_true(
		SessionTracker.was_created_this_session("res://scripts/path_mover_3d.gd"),
		"session set should remember the write"
	)
	var writes := SessionTracker.take_recent_writes()
	assert_eq(writes.size(), 1)
	assert_eq(writes[0], "res://scripts/path_mover_3d.gd")


func test_begin_call_clears_only_the_per_call_buffer() -> void:
	SessionTracker.mark_created("res://scripts/a.gd")
	SessionTracker.begin_call()
	# The per-call buffer is empty after begin_call …
	assert_eq(SessionTracker.take_recent_writes().size(), 0, "begin_call resets the per-call buffer")
	# … but the session-wide protection set is untouched.
	assert_true(
		SessionTracker.was_created_this_session("res://scripts/a.gd"),
		"begin_call must NOT clear the session-wide created set"
	)


func test_take_recent_writes_drains_and_dedupes() -> void:
	SessionTracker.begin_call()
	SessionTracker.mark_created("res://scripts/controller.gd")
	SessionTracker.mark_created("res://scripts/camera.gd")
	SessionTracker.mark_created("res://scripts/controller.gd")  # duplicate same call
	var first := SessionTracker.take_recent_writes()
	assert_eq(first.size(), 2, "duplicates within a call collapse")
	assert_true(first.has("res://scripts/controller.gd"))
	assert_true(first.has("res://scripts/camera.gd"))
	# Draining empties the buffer — a second drain (no writes since) is empty.
	assert_eq(SessionTracker.take_recent_writes().size(), 0, "take_recent_writes drains the buffer")


func test_recent_writes_normalizes_paths_like_created_set() -> void:
	# Bare paths get the res:// prefix, matching _created_paths normalization,
	# so the client sees a consistent res:// URI to fetch + revert.
	SessionTracker.mark_created("scripts/bare.gd")
	var writes := SessionTracker.take_recent_writes()
	assert_eq(writes.size(), 1)
	assert_eq(writes[0], "res://scripts/bare.gd")


func test_clear_wipes_both() -> void:
	SessionTracker.mark_created("res://scripts/x.gd")
	SessionTracker.clear()
	assert_false(SessionTracker.was_created_this_session("res://scripts/x.gd"))
	assert_eq(SessionTracker.take_recent_writes().size(), 0)
