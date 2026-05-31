extends GutTest

# Pure tests for the service layer. No editor / scene tree access — these
# run headlessly.

const ReadOnlyGuard = preload("res://addons/com.gladekit.mcp-bridge/services/read_only_guard.gd")
const ErrorTracker = preload("res://addons/com.gladekit.mcp-bridge/services/error_tracker.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")
const BackupManager = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")


# ── ReadOnlyGuard ─────────────────────────────────────────────────────────

func before_each() -> void:
	OS.set_environment("GLADEKIT_GODOT_READ_ONLY", "")
	OS.set_environment("GLADEKIT_GODOT_ALLOW_DEMO_WRITES", "")
	ErrorTracker.clear()


func test_read_only_disabled_by_default_allows_writes() -> void:
	assert_true(ReadOnlyGuard.is_allowed("create_node"))


func test_read_only_enabled_via_env_blocks_writes() -> void:
	OS.set_environment("GLADEKIT_GODOT_READ_ONLY", "1")
	assert_false(ReadOnlyGuard.is_allowed("create_node"))


func test_read_only_enabled_still_allows_reads() -> void:
	OS.set_environment("GLADEKIT_GODOT_READ_ONLY", "1")
	assert_true(ReadOnlyGuard.is_allowed("get_scene_tree"))
	assert_true(ReadOnlyGuard.is_allowed("get_node_info"))
	assert_true(ReadOnlyGuard.is_allowed("get_uid"))
	# Late-added read-only tools must also pass (regression for the stale-list bug).
	assert_true(ReadOnlyGuard.is_allowed("list_signal_connections"))
	assert_true(ReadOnlyGuard.is_allowed("get_project_info"))


func test_read_only_blocks_side_effecting_play_mode_tools() -> void:
	# run/stop/launch are play-mode-safe but NOT read-only — they must be
	# blocked in read-only mode (they spawn/kill processes / focus the editor).
	OS.set_environment("GLADEKIT_GODOT_READ_ONLY", "1")
	assert_false(ReadOnlyGuard.is_allowed("run_project"))
	assert_false(ReadOnlyGuard.is_allowed("stop_project"))
	assert_false(ReadOnlyGuard.is_allowed("launch_editor"))


func test_read_only_env_true_string_works() -> void:
	OS.set_environment("GLADEKIT_GODOT_READ_ONLY", "true")
	assert_false(ReadOnlyGuard.is_allowed("create_node"))


# ── ErrorTracker ──────────────────────────────────────────────────────────

func test_error_tracker_records_and_returns() -> void:
	ErrorTracker.record("create_node", "type 'X' unknown", {"type": "X"})
	assert_eq(ErrorTracker.count(), 1)
	var recent: Array = ErrorTracker.recent(5)
	assert_eq(recent.size(), 1)
	assert_eq(recent[0]["tool_name"], "create_node")
	assert_string_contains(recent[0]["error"], "unknown")
	assert_true(recent[0].has("timestamp_ms"))


func test_error_tracker_ring_buffer_caps_at_max() -> void:
	for i in 80:
		ErrorTracker.record("t%d" % i, "err %d" % i, {})
	# Cap is MAX_ENTRIES = 50.
	assert_eq(ErrorTracker.count(), 50)
	# Newest entry survives.
	var newest: Array = ErrorTracker.recent(1)
	assert_eq(newest[0]["tool_name"], "t79")


func test_error_tracker_clear() -> void:
	ErrorTracker.record("foo", "bar", {})
	ErrorTracker.clear()
	assert_eq(ErrorTracker.count(), 0)


func test_error_tracker_recent_zero_returns_empty() -> void:
	ErrorTracker.record("foo", "bar", {})
	assert_eq(ErrorTracker.recent(0), [])


# ── DemoAssetsGuard ───────────────────────────────────────────────────────

func test_demo_guard_blocks_protected_prefix() -> void:
	var err := DemoAssetsGuard.check_write("res://addons/com.gladekit.mcp-bridge/demo_assets/example.tscn")
	assert_false(err.is_empty())
	assert_string_contains(err, "demo-asset")


func test_demo_guard_allows_unprotected_paths() -> void:
	assert_eq(DemoAssetsGuard.check_write("res://main.tscn"), "")
	assert_eq(DemoAssetsGuard.check_write("res://scripts/player.gd"), "")


func test_demo_guard_env_override_allows_writes() -> void:
	OS.set_environment("GLADEKIT_GODOT_ALLOW_DEMO_WRITES", "1")
	assert_eq(DemoAssetsGuard.check_write("res://addons/com.gladekit.mcp-bridge/demo_assets/x.tscn"), "")


# ── BackupManager (filesystem) ────────────────────────────────────────────

const _BACKUP_TEST_FILE := "res://_gk_backup_test.txt"


func test_backup_file_no_op_for_missing_file() -> void:
	# File never existed — backup_file returns "" silently.
	var p := BackupManager.backup_file("res://does_not_exist_xyz.tscn")
	assert_eq(p, "")


func test_backup_file_snapshots_existing_file() -> void:
	# Write a test file, snapshot it, verify the backup exists and matches.
	var f := FileAccess.open(_BACKUP_TEST_FILE, FileAccess.WRITE)
	assert_not_null(f, "could not open test file for write")
	f.store_string("hello backup")
	f.close()

	var backup_path := BackupManager.backup_file(_BACKUP_TEST_FILE)
	assert_false(backup_path.is_empty(), "backup_file should return a path")
	assert_true(FileAccess.file_exists(backup_path), "backup file should exist")
	var read := FileAccess.open(backup_path, FileAccess.READ)
	assert_eq(read.get_as_text(), "hello backup")
	read.close()

	# Cleanup
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_BACKUP_TEST_FILE))
	DirAccess.remove_absolute(backup_path)
