extends RefCounted

# Pre-mutation file backups. Tools that overwrite or delete existing
# resources call backup_file(path) first; the saved snapshot can be
# restored later (manually by the user, or via the cloud loop's revert
# endpoint).
#
# Backups land in <project_root>/.gladekit-backups/ which is OUTSIDE the
# project's res:// namespace so Godot doesn't try to import them. Each
# backup is timestamped to support multiple snapshots of the same path.
#
# Mirrors GladeAgenticAI.Services.BackupManager from the Unity bridge.
# Conservative defaults: best-effort, never raises — if a backup fails
# the tool still proceeds (we'd rather lose backup-ability than lose
# the operation).

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


# Snapshot a single file. Returns the absolute path of the saved backup,
# or "" if the source didn't exist or the snapshot couldn't be written.
static func backup_file(res_path: String) -> String:
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
	var backup_path: String = root.path_join(relative + "." + ts + ".bak")
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
	_prune_old_backups(root.path_join(relative))
	return backup_path


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
