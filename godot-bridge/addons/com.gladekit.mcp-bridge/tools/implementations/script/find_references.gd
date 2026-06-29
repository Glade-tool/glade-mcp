extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Finds every .gd script that references an identifier (a class_name, func, or
# var name), using whole-word matching on GDScript identifier boundaries so
# "Player" does not match "PlayerController" or a substring inside another word.
# This is the dependency-edge primitive: before renaming or changing a symbol,
# find the scripts that would break. Read-only.
#
# Args:
#   symbol:               String (required) — the identifier to find references to.
#   max_files:            int (default 40, clamped 1..100) — max distinct files.
#   max_matches_per_file: int (default 5, clamped 1..50) — line snippets per file
#                         (the per-file count is exact even when snippets are capped).
#
# Response payload:
#   symbol:       String
#   file_count:   int
#   total_matches:int
#   truncated:    bool — true if the file scan hit max_files
#   references:   [ { path:String, count:int, matches:[ {line:int, text:String} ] } ]
#                 ordered by count descending (heaviest dependents first).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const DEFAULT_MAX_FILES := 40
const HARD_CAP_FILES := 100
const DEFAULT_MAX_MATCHES := 5
const HARD_CAP_MATCHES := 50
const SNIPPET_CAP := 200
const _WORD_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


func _init() -> void:
	tool_name = "find_references"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var symbol: String = ToolUtils.parse_string_arg(args, "symbol")
	if symbol.is_empty():
		return ToolUtils.error("symbol is required")

	var max_files: int = clamp(ToolUtils.parse_int_arg(args, "max_files", DEFAULT_MAX_FILES), 1, HARD_CAP_FILES)
	var max_matches: int = clamp(ToolUtils.parse_int_arg(args, "max_matches_per_file", DEFAULT_MAX_MATCHES), 1, HARD_CAP_MATCHES)

	# Identifier-boundary match: GDScript identifiers are [A-Za-z0-9_]. Escape the
	# symbol so a value with regex metacharacters can't break or widen the match.
	var re := RegEx.new()
	if re.compile("(?<![A-Za-z0-9_])" + _escape_regex(symbol) + "(?![A-Za-z0-9_])") != OK:
		return ToolUtils.error("Could not build a search pattern for '%s'" % symbol)

	var references: Array = []
	var truncated := false

	# Manual stack walk (matches find_scripts) so deep trees don't blow the stack.
	# addons/ is always skipped — addon internals are never the user's project.
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
				var hit := _scan_file(entry_path, re, max_matches)
				if hit["count"] > 0:
					references.append(hit)
					if references.size() >= max_files:
						truncated = true
						break
		dir.list_dir_end()
		if truncated:
			break

	references.sort_custom(func(a, b): return a["count"] > b["count"])

	var total_matches := 0
	for r in references:
		total_matches += r["count"]

	var msg: String
	if references.is_empty():
		msg = "No references to '%s' found in project scripts." % symbol
	else:
		msg = "Found %d reference(s) to '%s' across %d script(s)." % [total_matches, symbol, references.size()]

	return ToolUtils.success(msg, {
		"symbol": symbol,
		"file_count": references.size(),
		"total_matches": total_matches,
		"truncated": truncated,
		"references": references,
	})


func _scan_file(path: String, re: RegEx, max_matches: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"path": path, "count": 0, "matches": []}
	var raw := file.get_as_text()
	file.close()

	var lines: PackedStringArray = raw.split("\n", true)
	var matches: Array = []
	var count := 0
	for li in lines.size():
		if re.search(lines[li]) == null:
			continue
		count += 1
		if matches.size() < max_matches:
			var text := lines[li].strip_edges()
			if text.length() > SNIPPET_CAP:
				text = text.substr(0, SNIPPET_CAP)
			matches.append({"line": li + 1, "text": text})

	return {"path": path, "count": count, "matches": matches}


func _escape_regex(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s[i]
		if _WORD_CHARS.find(c) >= 0:
			out += c
		else:
			out += "\\" + c
	return out
