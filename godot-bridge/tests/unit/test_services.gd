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


# ── BackupManager: turn-scoped flow (backup → restore → accept) ──────────
# These pin the end-to-end revert contract the four bridge endpoints rely
# on. The unscoped path above (no turn_id) is preserved for backwards
# compatibility with legacy callers (set_material_property, save_scene);
# everything below exercises the new turn-id subtree.

const _TURN_SCOPED_TEST_FILE := "res://_gk_turn_scoped_test.gd"
const _TURN_ID := "turn-1234567890-test1"


func _write_test_file(res_path: String, body: String) -> void:
	var f := FileAccess.open(res_path, FileAccess.WRITE)
	assert_not_null(f, "could not open '%s' for write" % res_path)
	f.store_string(body)
	f.close()


func _cleanup_test_file(res_path: String) -> void:
	if FileAccess.file_exists(res_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))


func _cleanup_turn(turn_id: String) -> void:
	# delete_turn returns 0 on a no-op (turn never created any files) so
	# it's safe to call unconditionally in teardown.
	BackupManager.delete_turn(turn_id)


func test_backup_file_with_turn_id_lands_under_turn_subdir() -> void:
	_write_test_file(_TURN_SCOPED_TEST_FILE, "v1")
	var backup_path := BackupManager.backup_file(_TURN_SCOPED_TEST_FILE, _TURN_ID)
	assert_false(backup_path.is_empty(), "backup_file should return a path")
	# Per-turn subtree: the absolute backup path must contain the turn_id.
	assert_true(backup_path.contains(_TURN_ID), "backup path should contain turn id, got '%s'" % backup_path)
	assert_true(FileAccess.file_exists(backup_path))
	# delete_turn must report at least one file removed (could be more if
	# the path-suffix prune kept additional snapshots).
	var removed: int = BackupManager.delete_turn(_TURN_ID)
	assert_gt(removed, 0, "delete_turn should report >=1 file removed")
	assert_false(FileAccess.file_exists(backup_path), "backup must be gone after delete_turn")
	_cleanup_test_file(_TURN_SCOPED_TEST_FILE)


func test_backup_then_modify_then_restore_round_trip() -> void:
	# Write v1 → snapshot under turn_id → mutate to v2 → restore must
	# rewind to v1. Smoking-gun for the turn/revert endpoint.
	_write_test_file(_TURN_SCOPED_TEST_FILE, "v1")
	var backup_path := BackupManager.backup_file(_TURN_SCOPED_TEST_FILE, _TURN_ID)
	assert_false(backup_path.is_empty())

	_write_test_file(_TURN_SCOPED_TEST_FILE, "v2-mutated")

	var result := BackupManager.restore_file(backup_path, _TURN_SCOPED_TEST_FILE)
	assert_true(result.get("success", false), "restore should succeed, got: %s" % str(result))
	var read := FileAccess.open(_TURN_SCOPED_TEST_FILE, FileAccess.READ)
	assert_eq(read.get_as_text(), "v1", "restored content should match the pre-mutation snapshot")
	read.close()

	_cleanup_turn(_TURN_ID)
	_cleanup_test_file(_TURN_SCOPED_TEST_FILE)


func test_restore_returns_structured_error_when_backup_missing() -> void:
	# Manually-deleted backup (or one that pruned out before revert ran).
	var fake_backup_path: String = ProjectSettings.globalize_path("res://.does_not_exist.bak")
	var result := BackupManager.restore_file(fake_backup_path, _TURN_SCOPED_TEST_FILE)
	assert_false(result.get("success", true), "restore should fail when backup is missing")
	assert_true(str(result.get("error", "")).contains("no longer exists"), "error message should mention missing backup")


func test_delete_file_removes_existing_and_no_ops_when_absent() -> void:
	_write_test_file(_TURN_SCOPED_TEST_FILE, "to be deleted")

	var r1 := BackupManager.delete_file(_TURN_SCOPED_TEST_FILE)
	assert_true(r1.get("success", false), "delete_file should succeed: %s" % str(r1))
	assert_true(r1.get("deleted", false), "delete_file should report deleted=true on first call")
	assert_false(FileAccess.file_exists(_TURN_SCOPED_TEST_FILE))

	# Second call on the same path — file already absent. Must still
	# return success (revert is idempotent for "created"-changetype undo).
	var r2 := BackupManager.delete_file(_TURN_SCOPED_TEST_FILE)
	assert_true(r2.get("success", false), "delete_file should be idempotent (success=true on absent file)")
	assert_false(r2.get("deleted", false), "second call should report deleted=false")


func test_delete_turn_is_safe_on_empty_or_unknown_turn() -> void:
	# A turn that produced no file mutations should not raise — just
	# returns 0. Same for a garbage turn id.
	assert_eq(BackupManager.delete_turn("turn-never-existed"), 0)
	assert_eq(BackupManager.delete_turn(""), 0, "empty turn id should be a no-op")


func test_turn_id_with_slashes_is_path_sanitized() -> void:
	# Belt-and-suspenders: a hostile turn_id like "../../etc/passwd" must
	# not escape the backup root. The sanitizer turns illegal characters
	# into "_" — see _turn_subdir.
	_write_test_file(_TURN_SCOPED_TEST_FILE, "v1")
	var backup_path := BackupManager.backup_file(_TURN_SCOPED_TEST_FILE, "../../bad")
	assert_false(backup_path.is_empty())
	# The on-disk path must not contain "../" segments — they should be
	# replaced with underscores.
	assert_false(backup_path.contains("../"), "turn_id sanitizer should strip path traversal: %s" % backup_path)
	BackupManager.delete_turn("../../bad")
	_cleanup_test_file(_TURN_SCOPED_TEST_FILE)


func test_path_exists_helper_checks_disk_state() -> void:
	# backup/check_exists endpoint hangs off this. Smoke: returns true for
	# a written file, false after deletion, false for empty/garbage paths.
	_write_test_file(_TURN_SCOPED_TEST_FILE, "exists")
	assert_true(BackupManager.path_exists(_TURN_SCOPED_TEST_FILE))
	_cleanup_test_file(_TURN_SCOPED_TEST_FILE)
	assert_false(BackupManager.path_exists(_TURN_SCOPED_TEST_FILE))
	assert_false(BackupManager.path_exists(""))
