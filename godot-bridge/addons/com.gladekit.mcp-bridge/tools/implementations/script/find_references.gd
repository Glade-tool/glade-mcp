extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Finds every .gd script that references an identifier (a class_name, func, or
# var name) in CODE — whole-identifier matches only, never inside a string
# literal or a `# comment` (a lexical scan handles even multi-line """docstrings"""),
# and "Player" never matches "PlayerController". This is the dependency-edge
# primitive: before renaming or changing a symbol, find the scripts that would
# break (or use rename_symbol to update them all at once). Read-only.
#
# Args:
#   symbol:               String (required) — the identifier to find references to.
#   max_files:            int (default 40, clamped 1..100) — max distinct files.
#   max_matches_per_file: int (default 5, clamped 1..50) — line snippets per file
#                         (the per-file count is exact even when snippets are capped).
#
# Response payload:
#   symbol:          String
#   file_count:      int  — files returned WITH line detail (capped at max_files)
#   total_file_count:int  — true number of files referencing the symbol
#   total_matches:   int  — true total across all referencing files
#   truncated:       bool — true when total_file_count > file_count
#   references:      [ { path:String, count:int, matches:[ {line:int, text:String} ] } ]
#                    ordered by count descending (heaviest dependents first).
#
# The scan continues past max_files to tally the TRUE blast radius — a refactor
# never acts on a partial picture (an early-out that stopped counting at the cap
# made a widely-used symbol look far less used than it is).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const Scanner = preload("res://addons/com.gladekit.mcp-bridge/services/gdscript_lexical_scanner.gd")

const DEFAULT_MAX_FILES := 40
const HARD_CAP_FILES := 100
const DEFAULT_MAX_MATCHES := 5
const HARD_CAP_MATCHES := 50
const SNIPPET_CAP := 200


func _init() -> void:
	tool_name = "find_references"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var symbol: String = ToolUtils.parse_string_arg(args, "symbol")
	if symbol.is_empty():
		return ToolUtils.error("symbol is required")

	var max_files: int = clamp(ToolUtils.parse_int_arg(args, "max_files", DEFAULT_MAX_FILES), 1, HARD_CAP_FILES)
	var max_matches: int = clamp(ToolUtils.parse_int_arg(args, "max_matches_per_file", DEFAULT_MAX_MATCHES), 1, HARD_CAP_MATCHES)

	# Only a real identifier can be referenced — reject a symbol with a space, dot,
	# or operator up front rather than walking the whole project for it.
	if not Scanner.is_valid_identifier(symbol):
		return ToolUtils.error("'%s' is not a valid GDScript identifier." % symbol)

	var references: Array = []
	var total_file_count := 0
	var total_matches := 0

	# Manual stack walk (matches find_scripts) so deep trees don't blow the stack.
	# addons/ is always skipped — addon internals are never the user's project.
	# The walk does NOT stop at max_files: it keeps scanning to tally the true
	# blast radius, and only collects per-line detail for the first max_files.
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
				var hit := _scan_file(entry_path, symbol, max_matches)
				if hit["count"] > 0:
					total_file_count += 1
					total_matches += hit["count"]
					if references.size() < max_files:
						references.append(hit)
		dir.list_dir_end()

	references.sort_custom(func(a, b): return a["count"] > b["count"])

	var truncated: bool = total_file_count > references.size()

	var msg: String
	if total_file_count == 0:
		msg = "No references to '%s' found in project scripts." % symbol
	elif truncated:
		msg = "Found %d reference(s) to '%s' across %d script(s); showing line detail for the top %d. Raise max_files to see more, or narrow the symbol." % [
			total_matches, symbol, total_file_count, references.size()
		]
	else:
		msg = "Found %d reference(s) to '%s' across %d script(s)." % [total_matches, symbol, total_file_count]

	return ToolUtils.success(msg, {
		"symbol": symbol,
		"file_count": references.size(),
		"total_file_count": total_file_count,
		"total_matches": total_matches,
		"truncated": truncated,
		"references": references,
	})


func _scan_file(path: String, symbol: String, max_matches: int) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"path": path, "count": 0, "matches": []}
	var raw := file.get_as_text()
	file.close()

	# Whole-identifier matches in CODE regions only — never inside a string literal
	# or a comment (including multi-line docstrings). Count stays line-based (a line
	# with any match counts once), Godot's established find_references semantic;
	# snippets are drawn from the first max_matches matching lines.
	var occurrences := Scanner.find_occurrences(raw, symbol)
	if occurrences.is_empty():
		return {"path": path, "count": 0, "matches": []}

	var lines: PackedStringArray = raw.split("\n", true)
	var matches: Array = []
	var seen_lines := {}
	var line_count := 0
	for occ in occurrences:
		var ln: int = occ["line"]
		if seen_lines.has(ln):
			continue
		seen_lines[ln] = true
		line_count += 1
		if matches.size() < max_matches:
			var text := lines[ln - 1].strip_edges() if ln - 1 < lines.size() else ""
			if text.length() > SNIPPET_CAP:
				text = text.substr(0, SNIPPET_CAP)
			matches.append({"line": ln, "text": text})

	return {"path": path, "count": line_count, "matches": matches}
