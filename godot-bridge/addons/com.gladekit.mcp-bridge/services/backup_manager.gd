extends RefCounted

# Pre-mutation file + scene-tree backups + restore + per-turn cleanup.
# Mutating tools call backup_file(path, turn_id) or the client calls
# backup_node(node_path, turn_id) before mutations; the saved snapshots
# can be restored via restore_file / restore_node (used by the turn/revert
# endpoint) or discarded en masse via delete_turn (turn/accept).
#
# On-disk layout:
#   <project_root>/.gladekit-backups/
#     turn-<turn_id>/                  ← per-turn subtree, makes accept cheap
#       <res-relative path>.<ts>.bak   ← file snapshots (.gd, .tres, .tscn, etc.)
#       nodes/<safe-node-path>.tscn    ← scene-tree (node) snapshots packed via PackedScene
#
# Scene-tree (node) backups use PackedScene serialization. PackedScene only
# packs descendants whose `owner` points at the packed root; in the editor,
# descendants are owned by the scene root rather than the node being packed,
# so we temporarily rewire owners to the pack root, save, and restore
# owners. On restore we set the new instance's descendant owners back to
# the edited scene root so the instance serializes correctly with the
# scene on next save.
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
# the mutation. restore_file + restore_node ARE allowed to surface errors
# via their Dictionary return values because the revert UI needs to show them.

const BACKUP_DIR_NAME := ".gladekit-backups"
const MAX_BACKUPS_PER_PATH := 10

# One-shot flag for the "backup root unavailable" push_error. ProjectSettings
# can't be re-resolved mid-session (it's the project root), so once it fails
# it stays failed. Spamming push_error on every backup call would drown the
# Output panel — emit once per editor session and let the message stand.
static var _root_unavailable_logged: bool = false


# Resolve <project_root>/<BACKUP_DIR_NAME>. Returns "" only when
# ProjectSettings can't globalize res:// — which is a hard editor-state
# failure (read-only mount, no project, etc.). Callers MUST treat "" as a
# hard error: every backup will silently degrade, and the revert UI loses
# its undo capability without warning. The push_error (once per session)
# makes the failure visible in the Output panel even when in-process
# callers can't surface their own error.
static func _backup_root() -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	if project_root.is_empty():
		if not _root_unavailable_logged:
			_root_unavailable_logged = true
			push_error(
				"[GladeKit MCP Bridge] BackupManager: could not resolve project root "
				+ "via ProjectSettings.globalize_path(\"res://\"). All backups will be "
				+ "silently disabled this session — revert / undo will not work. Check "
				+ "that the project directory is writable and that the editor has a "
				+ "valid open project."
			)
		return ""
	return project_root.path_join(BACKUP_DIR_NAME)


# Public preflight check. Returns true if backups can be written this session.
# Callers that want to fail-fast (e.g. the WS revert handler) can probe this
# before committing to a turn rather than discovering the failure mid-mutation.
static func is_available() -> bool:
	return not _backup_root().is_empty()


static func _turn_subdir(turn_id: String) -> String:
	# Whitelist-trim the turn_id so a hostile/garbled value can't escape
	# the backup root. Allowed: letters, digits, "-", "_". Anything else
	# becomes "_". The client always sends a generated turnId like
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
	# the client adds at generateTurnId(); accept either form.
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
	# Same relative/absolute tolerance as restore_node — the client
	# computes the path with its own convention rather than reusing the
	# bridge's response. See _resolve_backup_path_to_absolute.
	backup_abs_path = _resolve_backup_path_to_absolute(backup_abs_path)
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

	# Remove the companion sidecars Godot generates next to a resource — the
	# `.uid` pin and any `.import` metadata. Leaving them behind orphans dead
	# entries in the FileSystem dock and, for a `.gd`, a stale UID that a scene
	# may still resolve to a now-missing script (a "missing dependency" load
	# error). Best-effort: a sidecar that won't delete does not fail the primary
	# delete.
	for sidecar: String in [target_res_path + ".uid", target_res_path + ".import"]:
		if FileAccess.file_exists(sidecar):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar))

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


# Does the given path point at a file that still exists? Backs the
# backup/check_exists endpoint, which the client uses to prune turn
# entries whose backup files have been GC'd (the per-path prune cap
# above, or manual user cleanup of .gladekit-backups/).
#
# Same relative/absolute tolerance as restore_file + restore_node — the
# client ships its own client-computed stateBackupPath as a
# project-relative path (`.gladekit-backups/turn-X/nodes/<safe>.tscn`),
# and without resolving to absolute, FileAccess.file_exists returns
# false. That misses every gameobject_modified change during pruning,
# the turn gets marked accepted, and the Undo button greys out.
static func path_exists(abs_path: String) -> bool:
	if abs_path.is_empty():
		return false
	return FileAccess.file_exists(_resolve_backup_path_to_absolute(abs_path))


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


# ── Scene-tree (node) backups ─────────────────────────────────────────────
# PackedScene-based capture. Used by the client's pre-mutation hook for
# scene-tree-modifying tools (delete_node, set_node_transform, etc.). The
# turn/revert handler later loads the .tscn and re-instantiates under the
# original parent.

const NODE_BACKUP_SUBDIR := "nodes"


# Map a scene-relative node path ("Player/Sprite") to its on-disk backup
# location. Forward slashes are replaced with "_" so the result is a valid
# single filename, scoped under the turn subtree.
static func node_backup_path(node_path_in_scene: String, turn_id: String) -> String:
	var root := _backup_root()
	if root.is_empty():
		return ""
	var subdir := _turn_subdir(turn_id)
	if subdir.is_empty():
		return ""
	var safe := _safe_node_filename(node_path_in_scene)
	return root.path_join(subdir).path_join(NODE_BACKUP_SUBDIR).path_join(safe + ".tscn")


# Pack `node` and its descendants into a PackedScene saved at the
# per-turn node-backup location for `node_path_in_scene`. Returns a
# Dictionary with success + backup_path (absolute) so the WS handler can
# forward the path back to the client.
#
# Owner rewiring: PackedScene.pack() only includes descendants whose
# `owner` points at the packed root. In the editor every descendant is
# owned by the scene root, not the node being packed, so without
# rewiring you get an empty PackedScene. We snapshot every descendant's
# owner, set them to `node`, pack, then restore — net-zero side effect
# on the live scene.
static func backup_node(node: Node, node_path_in_scene: String, turn_id: String) -> Dictionary:
	if node == null:
		return {"success": false, "error": "node is null"}
	if node_path_in_scene.is_empty():
		return {"success": false, "error": "node_path_in_scene is empty"}
	if turn_id.is_empty():
		return {"success": false, "error": "turn_id is empty"}
	var backup_path := node_backup_path(node_path_in_scene, turn_id)
	if backup_path.is_empty():
		return {"success": false, "error": "could not compute backup path"}

	# mkdir -p
	var backup_dir: String = backup_path.get_base_dir()
	var mk_err := DirAccess.make_dir_recursive_absolute(backup_dir)
	if mk_err != OK and mk_err != ERR_ALREADY_EXISTS:
		return {"success": false, "error": "could not create backup dir '%s' (err %d)" % [backup_dir, mk_err]}

	var saved_owners: Array = _capture_and_rewire_owners(node, node)
	var packed := PackedScene.new()
	var pack_err := packed.pack(node)
	_restore_owners(saved_owners)
	if pack_err != OK:
		return {"success": false, "error": "PackedScene.pack failed (err %d) for node '%s'" % [pack_err, node_path_in_scene]}

	var save_err := ResourceSaver.save(packed, backup_path)
	if save_err != OK:
		return {"success": false, "error": "ResourceSaver.save failed (err %d) writing %s" % [save_err, backup_path]}

	# Diagnostic: print what we captured + how big the on-disk PackedScene
	# is. A suspiciously small file (~200 bytes) means pack() didn't catch
	# the node's properties — useful signal if a restore looks like it
	# silently no-ops.
	var size_str := "?"
	var stat := FileAccess.open(backup_path, FileAccess.READ)
	if stat != null:
		size_str = str(stat.get_length())
		stat.close()
	print_rich(
		"[color=cyan][GladeKit Backup][/color] packed %s '%s' (%s bytes) -> %s"
		% [node.get_class(), node_path_in_scene, size_str, backup_path]
	)

	return {"success": true, "backup_path": backup_path}


# Re-instantiate a previously-packed node under `parent_in_scene` with the
# original `node_name`. Used by turn/revert for changeType "deleted"
# (re-create the node) and "modified" (delete the current then add the
# backup back in place). For the "modified" case the caller should free
# the existing node first; this helper only handles the attach side.
#
# After attach, walks the new instance's descendants and assigns their
# owner to the edited scene root so subsequent scene saves include them
# (Godot drops owner=null nodes from the saved .tscn).
static func restore_node(backup_abs_path: String, parent_in_scene: Node, node_name: String, sibling_index: int = -1) -> Dictionary:
	if backup_abs_path.is_empty():
		return {"success": false, "error": "backup_abs_path is empty"}
	# Tolerate both absolute paths (what backup_node returns) and
	# project-relative paths (`.gladekit-backups/...`, the convention the
	# client mirrors on the client side and ships back in the revert
	# payload). The client computes its own path so its TurnChange can
	# be saved/restored without round-tripping the bridge response —
	# but the bridge has to resolve both forms on revert.
	var resolved_path: String = _resolve_backup_path_to_absolute(backup_abs_path)
	if not FileAccess.file_exists(resolved_path):
		return {"success": false, "error": "backup file no longer exists at '%s'" % resolved_path}
	backup_abs_path = resolved_path
	if parent_in_scene == null:
		return {"success": false, "error": "parent is null"}

	var packed = load(backup_abs_path)
	if not (packed is PackedScene):
		return {"success": false, "error": "backup '%s' did not load as a PackedScene" % backup_abs_path}
	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		return {"success": false, "error": "PackedScene.instantiate returned null"}
	if not node_name.is_empty():
		instance.name = node_name

	parent_in_scene.add_child(instance)
	if sibling_index >= 0 and sibling_index < parent_in_scene.get_child_count():
		parent_in_scene.move_child(instance, sibling_index)

	# Break the PackedScene linkage so the instance serializes inline
	# rather than as `instance=ExtResource("path/to/backup.tscn")`. Without
	# this, saving the scene writes a reference to the transient backup
	# file under .gladekit-backups/, which (a) ships the backup path into
	# the user's scene file, and (b) breaks the scene the moment that
	# backup is GC'd or a turn is accepted. Clearing scene_file_path
	# tells Godot to serialize this node as a regular subtree member.
	instance.scene_file_path = ""

	# Restore ownership chain so the instance + its descendants save back
	# into the scene. Without setting owner on the instance itself, the
	# restored node is in the scene tree at runtime but vanishes the
	# next time the user saves (Godot drops owner=null nodes during
	# serialization).
	#
	# Owner target derivation: in production parent_in_scene was loaded as
	# part of the edited scene, so parent_in_scene.owner IS the edited
	# scene root (same value EditorInterface.get_edited_scene_root() would
	# return). Deriving from the parent instead of calling EditorInterface
	# keeps this method runnable from non-editor contexts (e.g. GUT runs
	# tests via play_custom_scene, where EditorInterface is unreachable).
	# Falls back to parent_in_scene itself when parent has no owner (the
	# parent IS the scene root) — same semantic as the original call.
	var scene_root: Node = parent_in_scene.owner if parent_in_scene.owner != null else parent_in_scene
	if instance != scene_root:
		instance.owner = scene_root
		_assign_owner_recursive(instance, scene_root)

	print_rich(
		"[color=cyan][GladeKit Restore][/color] loaded %s, instantiated %s '%s', attached under '%s' at index %d (parent now has %d children)"
		% [
			(packed as PackedScene).get_class(),
			instance.get_class(),
			instance.name,
			parent_in_scene.name,
			parent_in_scene.get_children().find(instance),
			parent_in_scene.get_child_count(),
		]
	)

	return {"success": true, "instance_name": instance.name}


# Find a node at the given scene-relative path and free it. Mirrors
# delete_file: the "created" revert path (no backup to consult — just
# undo the creation). Returns success=true with deleted=false when the
# target is already gone (idempotent — restoring a "never existed" state
# from an absent node is the correct end state).
static func delete_node_at(node_path_in_scene: String) -> Dictionary:
	if node_path_in_scene.is_empty():
		return {"success": false, "error": "node_path_in_scene is empty"}
	# Reuse the bridge's resolver so the same NodePath conventions
	# (absolute, scene-relative, single-name search) work here. The
	# resolver returns null both when the scene is closed AND when the
	# node legitimately doesn't exist — for this revert path both are
	# the same outcome (the "created" change has nothing to undo because
	# the node isn't there), so we collapse both into the idempotent
	# success/deleted=false response.
	var ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
	var node: Node = ToolUtils.find_node_by_path(node_path_in_scene)
	if node == null:
		return {"success": true, "deleted": false, "reason": "node already absent at '%s'" % node_path_in_scene}
	var root: Node = ToolUtils.get_edited_scene_root_safe()
	if root != null and node == root:
		return {"success": false, "error": "refusing to delete scene root via revert"}
	var parent: Node = node.get_parent()
	ToolUtils.deselect_before_free(node)
	if parent != null:
		parent.remove_child(node)
	node.free()
	return {"success": true, "deleted": true}


# ── Owner rewiring (PackedScene.pack workaround) ──────────────────────────

static func _capture_and_rewire_owners(pack_root: Node, current: Node) -> Array:
	# Returns an Array of {node, original_owner} dicts so _restore_owners
	# can put things back exactly as they were.
	var saved: Array = []
	_walk_capture(pack_root, current, saved)
	return saved


static func _walk_capture(pack_root: Node, current: Node, saved: Array) -> void:
	for child in current.get_children():
		saved.append({"node": child, "owner": child.owner})
		# Rewire to the pack root so PackedScene.pack picks them up.
		child.owner = pack_root
		_walk_capture(pack_root, child, saved)


static func _restore_owners(saved: Array) -> void:
	for entry in saved:
		var node: Node = entry.get("node")
		if node != null and is_instance_valid(node):
			node.owner = entry.get("owner")


static func _assign_owner_recursive(node: Node, new_owner: Node) -> void:
	for child in node.get_children():
		child.owner = new_owner
		_assign_owner_recursive(child, new_owner)


# Promote a possibly-relative backup path (`.gladekit-backups/turn-X/...`)
# to an absolute filesystem path. Pass-through for paths that are already
# absolute, res://-rooted, user://-rooted, or platform-absolute (Windows
# drive letters or POSIX leading slash). Used by restore_file + restore_node
# so the client can store relative paths (mirroring its computed
# convention) without forcing every revert to round-trip the response.
static func _resolve_backup_path_to_absolute(path: String) -> String:
	if path.is_empty():
		return path
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	# POSIX absolute or Windows drive (`C:`, `D:`, etc.) — leave as-is.
	if path.begins_with("/"):
		return path
	if path.length() >= 2 and path[1] == ":":
		return path
	# Treat everything else as project-relative.
	var project_root: String = ProjectSettings.globalize_path("res://")
	if project_root.is_empty():
		return path
	return project_root.path_join(path)


static func _safe_node_filename(node_path_in_scene: String) -> String:
	# Replace any path-segment-ish character with "_" so the result is a
	# valid filename. Clients computing the same path independently must
	# apply the same sanitizer (keep `[A-Za-z0-9._-]`, replace the rest
	# with `_`) so their stateBackupPath matches the bridge's on-disk file.
	var out := ""
	for i in node_path_in_scene.length():
		var c := node_path_in_scene[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "-" or c == "_" or c == ".":
			out += c
		else:
			out += "_"
	if out.is_empty():
		out = "_root"
	return out
