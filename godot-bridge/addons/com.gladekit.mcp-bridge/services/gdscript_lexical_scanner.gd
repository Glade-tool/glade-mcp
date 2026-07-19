extends RefCounted

## Lexical (not semantic) scanner for GDScript source. It classifies every
## character as code or non-code (inside a `#` comment or a string literal —
## "…", '…', or a triple-quoted """…""" / '''…''' docstring) so callers can match
## or rewrite WHOLE identifiers only in code regions — never inside a string like
## "Player" or a `# Player` comment, which is the false-positive class a plain
## regex over the file text cannot avoid. Triple-quoted strings that span many
## lines (GDScript docstrings) are handled correctly, which per-line matching is
## not.
##
## Identifiers are maximal [A-Za-z0-9_] runs starting with a letter or '_', so
## "whole identifier" falls out for free: searching `Player` never matches
## `PlayerController`, and `foo.Player` yields two identifier tokens.
##
## This is a lexer, not a parser: it does not bind identifiers to symbols, so it
## cannot tell two distinct things that share a name apart. For the common
## refactor ("rename this symbol") that is correct and far more precise than
## substring/regex matching. Known minor limitations (documented, not bugs): a
## bare node-path shorthand (`$Player`, `%Player`) and an annotation
## (`@export`) are treated as ordinary identifiers — quoted node paths
## (`$"Player"`) are strings and are skipped as usual.


static func _is_ident_start(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


static func _is_ident_part(c: String) -> bool:
	return _is_ident_start(c) or (c >= "0" and c <= "9")


## True when `s` is a syntactically valid GDScript identifier (letter or '_'
## followed by letters, digits, or '_'). Callers use this to reject a rename
## target or a find_references symbol that could never be a real identifier
## before scanning the project.
static func is_valid_identifier(s: String) -> bool:
	if s.is_empty() or not _is_ident_start(s[0]):
		return false
	for i in range(1, s.length()):
		if not _is_ident_part(s[i]):
			return false
	return true


## Per-character code mask: mask[i] == 1 when s[i] is a code character and 0 when
## it is inside a comment or a string literal. Shared primitive the other methods
## derive from, so they stay in exact lexical agreement.
static func compute_code_mask(s: String) -> PackedByteArray:
	var n := s.length()
	var mask := PackedByteArray()
	mask.resize(n) # zero-filled

	var i := 0
	while i < n:
		var c := s[i]

		# Line comment to end of line.
		if c == "#":
			while i < n and s[i] != "\n":
				i += 1
			continue

		# Triple-quoted string (may span multiple lines).
		if i + 3 <= n and (s.substr(i, 3) == '"""' or s.substr(i, 3) == "'''"):
			var triple := s.substr(i, 3)
			i += 3
			while i < n:
				if s[i] == "\\" and i + 1 < n:
					i += 2
					continue
				if i + 3 <= n and s.substr(i, 3) == triple:
					i += 3
					break
				i += 1
			continue

		# Single-line string.
		if c == '"' or c == "'":
			var quote := c
			i += 1
			while i < n:
				if s[i] == "\\" and i + 1 < n:
					i += 2
					continue
				if s[i] == quote:
					i += 1
					break
				if s[i] == "\n":
					break # unterminated — bail defensively
				i += 1
			continue

		# Ordinary code character (identifier char, operator, punctuation).
		mask[i] = 1
		i += 1

	return mask


## Every whole-identifier occurrence of `symbol` in a code region, as
## { "index": int, "line": int } (1-based line). Line numbers stay correct even
## across a multi-line string because physical newlines are always counted.
static func find_occurrences(source: String, symbol: String) -> Array:
	var result: Array = []
	if source.is_empty() or symbol.is_empty():
		return result

	var mask := compute_code_mask(source)
	var n := source.length()
	var slen := symbol.length()
	var line := 1
	var i := 0
	while i < n:
		var c := source[i]
		if c == "\n":
			line += 1
			i += 1
			continue
		if mask[i] == 1 and _is_ident_start(c):
			var start := i
			var start_line := line
			i += 1
			while i < n and mask[i] == 1 and _is_ident_part(source[i]):
				i += 1
			if (i - start) == slen and source.substr(start, slen) == symbol:
				result.append({"index": start, "line": start_line})
		else:
			i += 1
	return result


## Count of whole-identifier occurrences of `symbol` in code regions.
static func count_occurrences(source: String, symbol: String) -> int:
	return find_occurrences(source, symbol).size()


## Replace every code-region whole-identifier `old_name` with `new_name`, leaving
## strings and comments untouched. Returns { "text": String, "count": int }.
static func rewrite(source: String, old_name: String, new_name: String) -> Dictionary:
	if source.is_empty() or old_name.is_empty():
		return {"text": source, "count": 0}

	var mask := compute_code_mask(source)
	var n := source.length()
	var olen := old_name.length()
	var parts := PackedStringArray()
	var cursor := 0
	var count := 0
	var i := 0
	while i < n:
		if mask[i] == 1 and _is_ident_start(source[i]):
			var start := i
			i += 1
			while i < n and mask[i] == 1 and _is_ident_part(source[i]):
				i += 1
			if (i - start) == olen and source.substr(start, olen) == old_name:
				parts.append(source.substr(cursor, start - cursor))
				parts.append(new_name)
				cursor = i
				count += 1
		else:
			i += 1

	if count == 0:
		return {"text": source, "count": 0}
	parts.append(source.substr(cursor, n - cursor))
	return {"text": "".join(parts), "count": count}
