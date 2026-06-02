extends RefCounted

# Pre-mutation file backups + restore + per-turn cleanup. Mutating tools
# call backup_file(path, turn_id) before they overwrite or delete a file;
# the saved snapshot can be restored via restore_file() (used by the
# turn/revert endpoint) or discarded via delete_turn() (turn/accept).
#
# On-disk layout:
#   <project_root>/.gladekit-backups/
#     turn-<turn_id>/                  ← per-turn subtree, makes accept cheap
#       <res-relative path>.<ts>.bak   ← one file = one backup
#
# When a tool calls backup_file() WITHOUT a turn_id (legacy callers like
# set_material_property and save_scene), the file lands at the root of
# .gladekit-backups/ — they participate in pruning but not in the
# turn-scoped revert flow. Wiring those into a turn is a follow-up.
#
# The backup tree lives OUTSIDE res:// so Godot's resource importer
# doesn't try to scan it as project content.
#
# Defaults are conservative: best-effort, never raises. If a backup fails
# the tool still proceeds — we'd rather lose backup-ability than block
# the mutation. restore_file IS allowed to surface errors via its
# Dictionary return value because the revert UI needs to show them.

const BACKUP_DIR_NAME := ".gladekit-backups"
const MAX_BACKUPS_PER_PATH := 10


static func _backup_root() -> String:
	# Resolve project root via res:// → absolute, then append the backup
	# directory name. Stays outside res:// so the editor importer leaves
	# it alone.
	var project_root := ProjectSettings.globalize_path("res://")
	if project_root.is_empty():
		return ""
	return project_root.path_join(BACKUP_DIR_NAME)


static func _turn_subdir(turn_id: String) -> String:
	# Whitelist-trim the turn_id so a hostile/garbled value can't escape
	# the backup root. Allowed: letters, digits, "-", "_". Anything else
	# becomes "_". The renderer always sends a generated turnId like
	# "turn-1234567890-abc12345" so this is belt-and-suspenders.
	if turn_id.is_empty():
		return ""
	var safe := ""
	for i in turn_id.length():
		var c := turn_id[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_":
			safe += c
		else:
			safe += "_"
	if safe.is_empty():
		return ""
	# Match the Unity convention: every turn_id ships with a `turn-` prefix
	# the renderer adds at generateTurnId(); accept either form.
	if safe.begins_with("turn-"):
		return safe
	return "turn-" + safe


# Snapshot a single file. Returns the absolute path of the saved backup,
# or "" if the source didn't exist or the snapshot couldn't be written.
# When turn_id is provided, backups land under <root>/turn-<id>/...
# (the per-turn subtree that turn/accept + turn/revert operate on).
static func backup_file(res_path: String, turn_id: String = "") -> String:
	if res_path.is_empty():
		return ""
	if not FileAccess.file_exists(res_path):
		return ""
	var root := _backup_root()
	if root.is_empty():
		return ""
	# Mirror the res-relative subpath under the backup root so multiple
	# files with the same basename don't collide.
	var relative := res_path.replace("res://", "")
	# Integer seconds → 10-digit timestamp string. Sortable lexicographically
	# (won't be true after year 2286 but we'll cross that bridge then).
	var ts: String = str(int(Time.get_unix_time_from_system()))
	var subdir := _turn_subdir(turn_id)
	var scoped_root: String = root if subdir.is_empty() else root.path_join(subdir)
	var backup_path: String = scoped_root.path_join(relative + "." + ts + ".bak")
	var backup_dir: String = backup_path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(backup_dir)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		push_warning("[GladeKit MCP Bridge] backup mkdir failed at %s (err %d)" % [backup_dir, mkdir_err])
		return ""
	var src := FileAccess.open(res_path, FileAccess.READ)
	if src == null:
		return ""
	var bytes := src.get_buffer(src.get_length())
	src.close()
	var dst := FileAccess.open(backup_path, FileAccess.WRITE)
	if dst == null:
		push_warning("[GladeKit MCP Bridge] backup write failed at %s" % backup_path)
		return ""
	dst.store_buffer(bytes)
	dst.close()
	# Pruning operates on the same scoped tree so prior turns don't
	# evict the snapshots the current turn just created.
	_prune_old_backups(scoped_root.path_join(relative))
	return backup_path


# Restore a previously-snapshotted file from `backup_abs_path` back to its
# original res:// location at `target_res_path`. Used by turn/revert when
# changeType is "modified" or "deleted". Returns a Dictionary so the caller
# can surface a structured error to the UI (unlike backup_file which is
# best-effort).
static func restore_file(backup_abs_path: String, target_res_path: String) -> Dictionary:
	if backup_abs_path.is_empty():
		return {"success": false, "error": "backup_path is empty"}
	if target_res_path.is_empty():
		return {"success": false, "error": "target_path is empty"}
	if not FileAccess.file_exists(backup_abs_path):
		return {"success": false, "error": "backup file no longer exists at '%s'" % backup_abs_path}

	# Ensure the target's parent exists (the original may have lived in a
	# directory we just emptied by deleting other files in the same turn).
	var target_dir_res: String = target_res_path.get_base_dir()
	if not target_dir_res.is_empty():
		var abs_target_dir: String = ProjectSettings.globalize_path(target_dir_res)
		var mk_err := DirAccess.make_dir_recursive_absolute(abs_target_dir)
		if mk_err != OK and mk_err != ERR_ALREADY_EXISTS:
			return {"success": false, "error": "could not create parent directory '%s' (err %d)" % [target_dir_res, mk_err]}

	var src := FileAccess.open(backup_abs_path, FileAccess.READ)
	if src == null:
		return {"success": false, "error": "could not open backup '%s' (FileAccess err %d)" % [backup_abs_path, FileAccess.get_open_error()]}
	var bytes := src.get_buffer(src.get_length())
	src.close()
	var dst := FileAccess.open(target_res_path, FileAccess.WRITE)
	if dst == null:
		return {"success": false, "error": "could not open '%s' for restore (FileAccess err %d)" % [target_res_path, FileAccess.get_open_error()]}
	dst.store_buffer(bytes)
	dst.close()
	return {"success": true, "restored_to": target_res_path, "bytes": bytes.size()}


# Delete a single file at a res:// path. Used by turn/revert when
# changeType is "created" — the user wants to undo the creation, and a
# fresh file has no backup to restore from. Returns a Dictionary so the
# revert handler can roll up per-change outcomes. A no-op (returning
# success=true) when the target is already gone — restoring a "deleted"
# state from a missing source is the correct end state.
static func delete_file(target_res_path: String) -> Dictionary:
	if target_res_path.is_empty():
		return {"success": false, "error": "target_path is empty"}
	if not FileAccess.file_exists(target_res_path):
		return {"success": true, "deleted": false, "reason": "file already absent"}
	var abs_target: String = ProjectSettings.globalize_path(target_res_path)
	var err := DirAccess.remove_absolute(abs_target)
	if err != OK:
		return {"success": false, "error": "could not delete '%s' (DirAccess err %d)" % [target_res_path, err]}
	return {"success": true, "deleted": true}


# Tear down every backup for a turn — used by turn/accept once the user
# confirms the mutations. Returns the number of files removed; absent
# turn dirs are a no-op (the turn may have produced no file mutations).
static func delete_turn(turn_id: String) -> int:
	var root := _backup_root()
	if root.is_empty():
		return 0
	var subdir := _turn_subdir(turn_id)
	if subdir.is_empty():
		return 0
	var turn_root: String = root.path_join(subdir)
	return _remove_dir_recursive(turn_root)


# Does an absolute path point at a file that still exists? Backs the
# backup/check_exists endpoint, which the renderer uses to prune turn
# entries whose backup files have been GC'd (the per-path prune cap
# above, or manual user cleanup of .gladekit-backups/).
static func path_exists(abs_path: String) -> bool:
	if abs_path.is_empty():
		return false
	return FileAccess.file_exists(abs_path)


# Keep at most MAX_BACKUPS_PER_PATH timestamped snapshots per source path.
# Older ones are removed silently (the project would otherwise grow
# unboundedly on long agent sessions).
static func _prune_old_backups(base_path: String) -> void:
	var dir_path := base_path.get_base_dir()
	var basename := base_path.get_file()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var matches: Array = []
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if dir.current_is_dir():
			continue
		if not entry.begins_with(basename + "."):
			continue
		if not entry.ends_with(".bak"):
			continue
		matches.append(entry)
	dir.list_dir_end()
	if matches.size() <= MAX_BACKUPS_PER_PATH:
		return
	matches.sort()  # lexicographic on the embedded timestamp = chronological
	var to_delete: int = matches.size() - MAX_BACKUPS_PER_PATH
	for i in to_delete:
		DirAccess.remove_absolute(dir_path.path_join(matches[i]))


# Recursively delete a directory and every file/subdir inside it. Returns
# the number of files removed (sans directories). Silent best-effort —
# any path it can't read is skipped, never raises.
static func _remove_dir_recursive(abs_dir_path: String) -> int:
	if abs_dir_path.is_empty():
		return 0
	var dir := DirAccess.open(abs_dir_path)
	if dir == null:
		return 0
	var files_removed: int = 0
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		var child: String = abs_dir_path.path_join(entry)
		if dir.current_is_dir():
			files_removed += _remove_dir_recursive(child)
			DirAccess.remove_absolute(child)
		else:
			if DirAccess.remove_absolute(child) == OK:
				files_removed += 1
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_dir_path)
	return files_removed
