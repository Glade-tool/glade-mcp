extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Project-wide rename of a GDScript identifier (class_name, func, var, const,
# signal, …) across every .gd file in the project. Rewrites ONLY whole-identifier
# occurrences in CODE — never inside a string literal or a comment, and never a
# substring (renaming "Player" leaves "PlayerController" alone) — which a plain
# find-and-replace cannot guarantee.
#
# Preview-first: pass dry_run=true to see the blast radius (files + counts)
# without writing. This is a LEXICAL rename — it does not tell two distinct
# symbols that share a name apart (that needs full semantic analysis), so on an
# ambiguous name preview first or scope with `directory`. Every modified file is
# snapshotted via the backup manager before it is overwritten, so a rename is
# revertible.
#
# Args:
#   old_name:  String (required) — the existing identifier to rename.
#   new_name:  String (required) — the new identifier (must not be a reserved word).
#   dry_run:   bool (default false) — report the change set without writing.
#   directory: String — optional res:// folder to scope the rename to.
#   max_files: int (default 200) — an APPLY is refused above this many files, since
#              a partial cross-file rename would break parsing.
#
# Response payload:
#   old_name, new_name: String
#   file_count:         int   — files that contain the symbol in code
#   total_occurrences:  int
#   changed_files:      [ { path:String, count:int } ] — sorted by count desc
#   dry_run:            bool
#   written:            int   — files written (apply only)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const Scanner = preload("res://addons/com.gladekit.mcp-bridge/services/gdscript_lexical_scanner.gd")
const BackupManager = preload("res://addons/com.gladekit.mcp-bridge/services/backup_manager.gd")

const DEFAULT_MAX_FILES := 200

# GDScript reserved words — renaming TO one would break parsing project-wide.
const RESERVED := {
	"if": true, "elif": true, "else": true, "for": true, "while": true,
	"match": true, "break": true, "continue": true, "pass": true, "return": true,
	"class": true, "class_name": true, "extends": true, "is": true, "in": true,
	"as": true, "self": true, "super": true, "func": true, "static": true,
	"const": true, "enum": true, "var": true, "signal": true, "await": true,
	"preload": true, "and": true, "or": true, "not": true, "true": true,
	"false": true, "null": true, "void": true, "breakpoint": true, "assert": true,
}


func _init() -> void:
	tool_name = "rename_symbol"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var old_name: String = ToolUtils.parse_string_arg(args, "old_name")
	var new_name: String = ToolUtils.parse_string_arg(args, "new_name")
	var dry_run: bool = ToolUtils.parse_bool_arg(args, "dry_run", false)
	var directory: String = ToolUtils.parse_string_arg(args, "directory")
	var max_files: int = ToolUtils.parse_int_arg(args, "max_files", DEFAULT_MAX_FILES)
	if max_files < 1:
		max_files = 1

	if old_name.is_empty():
		return ToolUtils.error("old_name is required")
	if new_name.is_empty():
		return ToolUtils.error("new_name is required")
	if old_name == new_name:
		return ToolUtils.error("old_name and new_name are identical — nothing to rename.")
	if not Scanner.is_valid_identifier(old_name):
		return ToolUtils.error("old_name '%s' is not a valid GDScript identifier." % old_name)
	if not Scanner.is_valid_identifier(new_name):
		return ToolUtils.error(
			"new_name '%s' is not a valid GDScript identifier (letters, digits, underscore; must not start with a digit)." % new_name
		)
	if RESERVED.has(new_name):
		return ToolUtils.error(
			"new_name '%s' is a reserved GDScript keyword — renaming to it would break parsing." % new_name
		)

	# Normalize an optional res:// directory scope.
	var scope := directory.strip_edges()
	if not scope.is_empty():
		if not scope.begins_with("res://"):
			scope = "res://" + scope.trim_prefix("/")
		scope = scope.trim_suffix("/")

	var changed_files: Array = []
	var pending: Array = [] # [ { path, text } ]
	var total_occurrences := 0

	# Manual stack walk (mirrors find_references); addons/ is always skipped.
	var stack: Array = ["res://"]
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		if dir_path.begins_with("res://addons"):
			continue
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		while true:
			var entry := dir.get_next()
			if entry.is_empty():
				break
			if entry.begins_with("."):
				continue
			var entry_path: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				stack.push_back(entry_path)
			elif entry.ends_with(".gd"):
				if not scope.is_empty() and not entry_path.begins_with(scope + "/") and entry_path != scope:
					continue
				var f := FileAccess.open(entry_path, FileAccess.READ)
				if f == null:
					continue
				var raw := f.get_as_text()
				f.close()
				var res := Scanner.rewrite(raw, old_name, new_name)
				var applied: int = res["count"]
				if applied == 0:
					continue
				total_occurrences += applied
				changed_files.append({"path": entry_path, "count": applied})
				pending.append({"path": entry_path, "text": res["text"]})
		dir.list_dir_end()

	changed_files.sort_custom(func(a, b): return a["count"] > b["count"])

	var extras := {
		"old_name": old_name,
		"new_name": new_name,
		"file_count": changed_files.size(),
		"total_occurrences": total_occurrences,
		"changed_files": changed_files,
		"dry_run": dry_run,
	}

	if changed_files.is_empty():
		var where := "" if scope.is_empty() else " under '%s'" % scope
		return ToolUtils.success("No code references to '%s' found%s; nothing to rename." % [old_name, where], extras)

	if dry_run:
		return ToolUtils.success(
			"[dry run] Renaming '%s' → '%s' would change %d occurrence(s) across %d file(s). No files were modified." % [
				old_name, new_name, total_occurrences, changed_files.size()
			],
			extras
		)

	# A partial cross-file rename leaves dangling references that fail to parse, so
	# refuse to APPLY beyond the cap — but still report the full blast radius.
	if changed_files.size() > max_files:
		extras["blocked"] = "exceedsMaxFiles"
		return ToolUtils.error(
			"Rename would touch %d files, above max_files=%d. A partial rename would break parsing. Narrow with `directory`, raise `max_files`, or run with dry_run=true to review the full blast radius first." % [
				changed_files.size(), max_files
			],
			extras
		)

	var written := 0
	var fs := EditorInterface.get_resource_filesystem()
	for item in pending:
		# Snapshot before overwrite so the rename is revertible.
		BackupManager.backup_file(item["path"])
		var wf := FileAccess.open(item["path"], FileAccess.WRITE)
		if wf == null:
			return ToolUtils.error(
				"Renamed %d/%d files, then failed writing '%s' (FileAccess error %d). The project may be partially renamed — revert via the backups or version control." % [
					written, pending.size(), item["path"], FileAccess.get_open_error()
				],
				extras
			)
		wf.store_string(item["text"])
		wf.close()
		if fs != null:
			fs.update_file(item["path"])
		written += 1

	extras["written"] = written
	return ToolUtils.success(
		"Renamed '%s' → '%s': %d occurrence(s) across %d file(s)." % [old_name, new_name, total_occurrences, written],
		extras
	)
