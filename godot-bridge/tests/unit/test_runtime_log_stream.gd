extends GutTest

# Pure unit tests for the runtime-event parser. No editor / scene tree
# access — the stream is fed text directly so these run headlessly.
#
# The parser splits incoming chunks into complete lines, recognizes Godot's
# error prefixes (ERROR / SCRIPT ERROR / USER SCRIPT ERROR), accumulates
# "   at:" stack frames onto the most recent header, and emits events into
# a 500-entry ring buffer with monotonic cursors + content fingerprints.

const RuntimeLogStream = preload("res://addons/com.gladekit.mcp-bridge/services/runtime_log_stream.gd")
const PlayModeObserver = preload("res://addons/com.gladekit.mcp-bridge/services/play_mode_observer.gd")

const _SID := "test-session"
const _OTHER_SID := "other-session"


func before_each() -> void:
	# Static state survives between test methods — wipe so each test starts
	# from a known baseline (matching how the editor starts cold).
	RuntimeLogStream.reset()
	PlayModeObserver.reset()


# ── Basic prefix matching ─────────────────────────────────────────────────


func test_single_error_block_emits_one_event() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: divide by zero\nsome unrelated stdout\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1, "one ERROR header should produce one event")
	assert_eq(String(events[0]["message"]), "divide by zero")
	assert_eq(String(events[0]["log_type"]), "ERROR")
	assert_eq(String(events[0]["stack_trace"]), "")


func test_script_error_prefix_classified_separately_from_error() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "SCRIPT ERROR: nil dereference\n---end---\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["log_type"]), "SCRIPT_ERROR")


func test_user_script_error_matched_before_error_prefix() -> void:
	# Prefix-ordering regression: "USER SCRIPT ERROR:" must NOT be matched as
	# "ERROR:" with a body of "USER SCRIPT ERROR" missing the colon — that's
	# what would happen if the prefix table were ordered shortest-first.
	RuntimeLogStream.ingest_chunk(_SID, "USER SCRIPT ERROR: push_error from Player.gd\nstdout\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["log_type"]), "USER_SCRIPT_ERROR")
	assert_eq(String(events[0]["message"]), "push_error from Player.gd")


func test_user_error_prefix_godot4_push_error() -> void:
	# Godot 4 changed `push_error("foo")` to emit "USER ERROR: foo" (vs the
	# Godot 3 "USER SCRIPT ERROR: foo"). The original prefix table missed
	# this, so every push_error during a play session silently dropped.
	RuntimeLogStream.ingest_chunk(_SID, "USER ERROR: BoomTest fired in _ready\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1, "USER ERROR: prefix must produce an event")
	assert_eq(String(events[0]["log_type"]), "USER_ERROR")
	assert_eq(String(events[0]["message"]), "BoomTest fired in _ready")


func test_user_error_prefix_matched_before_bare_error() -> void:
	# Prefix-ordering regression: "USER ERROR: X" must NOT route to the
	# bare ERROR: branch with " X" missing the colon. The match table
	# iterates in declaration order; the longer "USER ERROR:" must come
	# before "ERROR:".
	RuntimeLogStream.ingest_chunk(_SID, "USER ERROR: classified-correctly\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["log_type"]), "USER_ERROR",
		"USER ERROR must not be misclassified as ERROR")
	assert_eq(String(events[0]["message"]), "classified-correctly",
		"message body must be everything after the colon (no leading 'USER ')")


func test_warning_lines_dropped() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "WARNING: deprecated method called\nstdout\n")
	assert_eq(RuntimeLogStream.get_events_since_cursor(0).size(), 0,
		"WARNING is not in the captured prefix table — must be dropped")


func test_plain_stdout_dropped() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "Player jumped\nLevel loaded\n")
	assert_eq(RuntimeLogStream.get_events_since_cursor(0).size(), 0)


# ── Stack frame accumulation ──────────────────────────────────────────────


func test_stack_frames_concatenated_under_open_header() -> void:
	var chunk := "SCRIPT ERROR: bad call\n   at: Player.gd:42 @ _on_pressed()\n   at: Main.gd:7 @ _ready()\nstdout closes\n"
	RuntimeLogStream.ingest_chunk(_SID, chunk)
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	var stack: String = String(events[0]["stack_trace"])
	assert_true(stack.contains("Player.gd:42"), "first frame should land on stack")
	assert_true(stack.contains("Main.gd:7"), "subsequent frames should append")
	# Frames should be separated by a newline so the stack reads correctly.
	assert_true(stack.contains("\n"), "multi-frame stacks should be newline-separated")


func test_orphan_stack_frame_ignored() -> void:
	# Stack frame with no preceding error header — common when the runner
	# attaches mid-session after an earlier error has already scrolled past.
	RuntimeLogStream.ingest_chunk(_SID, "   at: somewhere.gd:1\n")
	assert_eq(RuntimeLogStream.get_events_since_cursor(0).size(), 0)


func test_non_stack_line_closes_open_event() -> void:
	# An error followed by a non-stack-non-error line should emit the error
	# immediately, not stall it waiting for more frames.
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: boom\nPlayer position 0,0\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["stack_trace"]), "",
		"non-stack line closed the event before any frames accumulated")


# ── Multi-event + cursor semantics ────────────────────────────────────────


func test_two_errors_in_one_chunk_produce_two_events() -> void:
	RuntimeLogStream.ingest_chunk(_SID,
		"ERROR: first\n   at: a.gd:1\nstdout\nERROR: second\n   at: b.gd:1\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 2)
	assert_eq(String(events[0]["message"]), "first")
	assert_eq(String(events[1]["message"]), "second")
	assert_eq(int(events[1]["cursor"]) - int(events[0]["cursor"]), 1,
		"cursors must be strictly monotonic with no gaps for back-to-back events")


func test_get_events_since_cursor_filters() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: one\nx\nERROR: two\ny\nERROR: three\nz\n")
	var all := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(all.size(), 3)
	# Pass the first event's cursor — should get events 2 and 3 only.
	var first_cursor := int(all[0]["cursor"])
	var rest := RuntimeLogStream.get_events_since_cursor(first_cursor)
	assert_eq(rest.size(), 2)
	assert_eq(String(rest[0]["message"]), "two")


func test_limit_caps_returned_events_for_next_poll() -> void:
	for i in 5:
		RuntimeLogStream.ingest_chunk(_SID, "ERROR: e%d\nclose\n" % i)
	var first_two := RuntimeLogStream.get_events_since_cursor(0, 2)
	assert_eq(first_two.size(), 2)
	# Events past the limit must remain available on the next poll —
	# limit caps the response, not the buffer.
	var tail := RuntimeLogStream.get_events_since_cursor(int(first_two[1]["cursor"]))
	assert_eq(tail.size(), 3)


# ── Chunk-boundary residue ────────────────────────────────────────────────


func test_incomplete_trailing_line_carries_to_next_chunk() -> void:
	# First chunk ends mid-word; second chunk completes the line.
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: split")
	assert_eq(RuntimeLogStream.get_events_since_cursor(0).size(), 0,
		"no newline yet — event must not emit prematurely")
	RuntimeLogStream.ingest_chunk(_SID, " across chunks\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["message"]), "split across chunks")


func test_chunk_split_between_header_and_stack_frame() -> void:
	# Header arrives in chunk 1; stack frames arrive in chunk 2. The open
	# event must persist across chunks so frames still attach.
	RuntimeLogStream.ingest_chunk(_SID, "SCRIPT ERROR: nil call\n")
	RuntimeLogStream.ingest_chunk(_SID, "   at: a.gd:5\n   at: b.gd:9\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_true(String(events[0]["stack_trace"]).contains("a.gd:5"))
	assert_true(String(events[0]["stack_trace"]).contains("b.gd:9"))


# ── Per-session isolation ─────────────────────────────────────────────────


func test_per_session_residue_does_not_cross_contaminate() -> void:
	# A's partial line must not get glued to B's chunk.
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: partial-from-a")
	RuntimeLogStream.ingest_chunk(_OTHER_SID, "ERROR: complete-from-b\nclose\n")
	# B's event closed; A still pending.
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["message"]), "complete-from-b")
	# Finish A — its message must be intact, no leakage from B.
	RuntimeLogStream.ingest_chunk(_SID, "\nclose\n")
	var all_events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(all_events.size(), 2)
	# Find the A event (order is push order — B was second message-wise but
	# arrived first chronologically; we just verify both messages exist).
	var messages: Array = []
	for e in all_events:
		messages.append(String(e["message"]))
	assert_true(messages.has("partial-from-a"))
	assert_true(messages.has("complete-from-b"))


# ── flush_session ─────────────────────────────────────────────────────────


func test_flush_session_closes_trailing_open_event() -> void:
	# Header + frames with no closing non-stack line — left "open" until
	# flush_session runs (which PlaySessionManager calls on process exit).
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: trailing\n   at: x.gd:1\n")
	assert_eq(RuntimeLogStream.get_events_since_cursor(0).size(), 0,
		"open event must not emit until a closer arrives or flush is called")
	RuntimeLogStream.flush_session(_SID)
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["message"]), "trailing")
	assert_true(String(events[0]["stack_trace"]).contains("x.gd:1"))


func test_flush_session_processes_residue_as_final_line() -> void:
	# Process dies mid-line (no trailing newline on the final chunk).
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: dying message")
	RuntimeLogStream.flush_session(_SID)
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 1)
	assert_eq(String(events[0]["message"]), "dying message")


# ── Fingerprint stability ─────────────────────────────────────────────────


func test_identical_content_yields_identical_fingerprint() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: same\n   at: a.gd:1\nclose\n")
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: same\n   at: a.gd:1\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 2)
	assert_eq(String(events[0]["fingerprint"]), String(events[1]["fingerprint"]),
		"two identical errors must hash to the same fingerprint for client-side dedup")


func test_stack_change_drifts_fingerprint() -> void:
	# Same message, different stack (e.g. after a script edit shifted line
	# numbers). Fingerprint MUST drift so an autonomous fixer gets a fresh
	# shot at the error after a recompile — matches the Unity-side semantic.
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: same\n   at: a.gd:1\nclose\n")
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: same\n   at: a.gd:99\nclose\n")
	var events := RuntimeLogStream.get_events_since_cursor(0)
	assert_eq(events.size(), 2)
	assert_ne(String(events[0]["fingerprint"]), String(events[1]["fingerprint"]),
		"different stack → different fingerprint")


# ── Buffer overflow ───────────────────────────────────────────────────────


func test_ring_buffer_evicts_oldest_past_max() -> void:
	# Push MAX_ENTRIES + 5 — verify oldest 5 are evicted and dropped_due_to_overflow ticks.
	var n: int = RuntimeLogStream.MAX_ENTRIES + 5
	for i in n:
		RuntimeLogStream.ingest_chunk(_SID, "ERROR: e%d\nclose\n" % i)
	assert_eq(RuntimeLogStream.current_size(), RuntimeLogStream.MAX_ENTRIES,
		"buffer must cap at MAX_ENTRIES")
	assert_eq(RuntimeLogStream.dropped_due_to_overflow(), 5,
		"overflow counter tracks evictions")
	assert_eq(RuntimeLogStream.total_events_observed(), n,
		"total observed counts ingested events including the evicted ones")


# ── PlayModeObserver ──────────────────────────────────────────────────────


func test_start_observation_snapshots_latest_cursor() -> void:
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: prior\nclose\n")
	var prior_cursor := RuntimeLogStream.latest_cursor()
	PlayModeObserver.start_observation()
	assert_true(PlayModeObserver.is_observation_active())
	assert_eq(PlayModeObserver.observation_start_cursor(), prior_cursor,
		"baseline cursor must capture state at arming time so prior errors aren't replayed")


func test_re_arming_refreshes_baseline_cursor() -> void:
	PlayModeObserver.start_observation()
	var first_baseline := PlayModeObserver.observation_start_cursor()
	# Cursors are 1-indexed (the empty-buffer sentinel is 0), so a single
	# ingested event would already advance latest_cursor past the baseline.
	# We push two anyway to keep the test exercising the multi-event path.
	RuntimeLogStream.ingest_chunk(_SID, "ERROR: first\nclose\nERROR: second\nclose\n")
	var after_cursor := RuntimeLogStream.latest_cursor()
	assert_gt(after_cursor, first_baseline, "buffer must have advanced before re-arming")
	PlayModeObserver.start_observation()
	assert_eq(PlayModeObserver.observation_start_cursor(), after_cursor,
		"re-arming after a reconnect must snapshot the NEW latest cursor")


func test_stop_observation_disarms() -> void:
	PlayModeObserver.start_observation()
	assert_true(PlayModeObserver.is_observation_active())
	PlayModeObserver.stop_observation()
	assert_false(PlayModeObserver.is_observation_active())
