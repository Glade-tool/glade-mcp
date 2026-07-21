extends RefCounted

## Extracts a lightweight structural outline from a GDScript source file — its
## script-level and class-level declarations with line numbers — so a caller can
## navigate a large file before deciding which lines to actually read.
##
## Emits one dictionary per symbol: { kind, name, line, signature }, in source
## order. Kinds: class_name, class (inner), func (incl. static func — the
## signature keeps the modifier), signal, enum (name "" when anonymous), const,
## export_var (@export… var), onready_var (@onready var).
##
## It runs over a "blanked" copy of the source (comments and string literals
## spaced out via GDScriptLexicalScanner.compute_code_mask), so a declaration
## keyword inside a docstring or comment is never matched. GDScript is
## indentation-scoped, not brace-scoped, so block context is tracked with an
## indentation SCOPE STACK: members of an inner `class X:` are emitted (any
## nesting depth), while anything inside a `func` body — local `const`s, local
## `var`s, lambda bodies — is excluded. A plain class-level `var` without
## @export/@onready is intentionally omitted to keep the outline readable
## (mirrors the C# outline omitting fields).
##
## This is a heuristic navigation aid, not a parser. Documented limits (rare,
## not bugs): indentation is compared by raw leading-whitespace char count, so a
## file mixing tabs and spaces across sibling blocks may mis-scope; a brace on
## its own line dedented past its enum's indent can pop a scope early.

const GDScriptLexicalScanner = preload("res://addons/com.gladekit.mcp-bridge/services/gdscript_lexical_scanner.gd")

const MAX_SIGNATURE_CHARS := 200
const MAX_SIGNATURE_CONTINUATION_LINES := 4


## Returns Array[Dictionary] of { kind: String, name: String, line: int,
## signature: String } for every recognized declaration, in source order.
static func extract(source: String) -> Array:
	var symbols: Array = []
	if source.is_empty():
		return symbols

	var blanked_lines := _blank_non_code_lines(source)
	var raw_lines: PackedStringArray = source.split("\n", true)

	# Indentation scope stack: { indent: int, kind: "class" | "func" }.
	var scopes: Array = []
	# Annotations seen on their own line(s), waiting for the declaration line
	# (`@export` on line N, `var x` on line N+1 must still classify as export).
	var pending_annotations: Array = []

	for i in range(blanked_lines.size()):
		var bline: String = blanked_lines[i]
		var stripped := bline.strip_edges()
		if stripped.is_empty():
			continue # blank, comment-only, or string-interior line — no scope effect

		var indent := _leading_ws_count(bline)
		while not scopes.is_empty() and indent <= scopes[-1]["indent"]:
			scopes.pop_back()
		var in_func := false
		for s in scopes:
			if s["kind"] == "func":
				in_func = true
				break

		var ann := _strip_leading_annotations(stripped)
		var line_annotations: Array = ann["annotations"]
		var rest: String = ann["rest"]
		if rest.is_empty():
			# Annotation-only line — carry to the next declaration line.
			pending_annotations.append_array(line_annotations)
			continue

		var carried: Array = pending_annotations
		pending_annotations = []
		var all_annotations: Array = carried + line_annotations

		var raw_sig := raw_lines[i].strip_edges() if i < raw_lines.size() else ""
		if not carried.is_empty():
			# The raw declaration line doesn't show annotations from previous
			# lines — prepend them so the signature keeps the classification.
			raw_sig = " ".join(PackedStringArray(carried)) + " " + raw_sig

		if rest.begins_with("class_name ") or rest.begins_with("class_name\t"):
			if not in_func:
				symbols.append(_symbol("class_name", _ident_prefix(rest.substr(10).strip_edges()), i + 1, raw_sig))
		elif rest.begins_with("class ") or rest.begins_with("class\t"):
			var cname := _ident_prefix(rest.substr(6).strip_edges())
			if not in_func and not cname.is_empty():
				symbols.append(_symbol("class", cname, i + 1, raw_sig))
			scopes.append({"indent": indent, "kind": "class"})
		elif rest.begins_with("func ") or rest.begins_with("static func ") or rest.begins_with("func\t") or rest.begins_with("static func\t"):
			var after_func := rest.substr(rest.find("func") + 4).strip_edges()
			var fname := _ident_prefix(after_func)
			if not in_func and not fname.is_empty():
				var sig := _join_multiline_signature(raw_sig, stripped, blanked_lines, raw_lines, i)
				symbols.append(_symbol("func", fname, i + 1, sig))
			scopes.append({"indent": indent, "kind": "func"})
		elif rest.begins_with("signal ") or rest.begins_with("signal\t"):
			if not in_func:
				var sig := _join_multiline_signature(raw_sig, stripped, blanked_lines, raw_lines, i)
				symbols.append(_symbol("signal", _ident_prefix(rest.substr(7).strip_edges()), i + 1, sig))
		elif rest == "enum" or rest.begins_with("enum ") or rest.begins_with("enum{") or rest.begins_with("enum\t"):
			if not in_func:
				# `enum Named { … }` → "Named"; anonymous `enum { … }` → "".
				var ename := _ident_prefix(rest.substr(4).strip_edges())
				symbols.append(_symbol("enum", ename, i + 1, raw_sig))
		elif rest.begins_with("const ") or rest.begins_with("const\t"):
			if not in_func:
				symbols.append(_symbol("const", _ident_prefix(rest.substr(6).strip_edges()), i + 1, raw_sig))
		elif rest.begins_with("var ") or rest.begins_with("var\t"):
			# Only annotated vars are outline-worthy; which annotation decides kind.
			var kind := ""
			for a in all_annotations:
				if String(a).begins_with("@export"):
					kind = "export_var"
					break
				if String(a).begins_with("@onready"):
					kind = "onready_var"
			if not in_func and not kind.is_empty():
				symbols.append(_symbol(kind, _ident_prefix(rest.substr(4).strip_edges()), i + 1, raw_sig))

	return symbols


# ── helpers ─────────────────────────────────────────────────────────────────


## Blank comments/strings but PRESERVE newlines (the scanner's mask marks a
## newline inside a docstring as non-code; losing it would shift every
## subsequent line number).
static func _blank_non_code_lines(source: String) -> PackedStringArray:
	var mask := GDScriptLexicalScanner.compute_code_mask(source)
	var out := ""
	for i in range(source.length()):
		var c := source[i]
		if c == "\n":
			out += "\n"
		elif mask[i] == 1:
			out += c
		else:
			out += " "
	return out.split("\n", true)


static func _leading_ws_count(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == " " or line[n] == "\t"):
		n += 1
	return n


## Consume leading `@annotation` / `@annotation(args…)` groups. Returns
## { annotations: Array[String], rest: String }. Runs on blanked text, so
## parens inside annotation string args can't unbalance the scan.
static func _strip_leading_annotations(stripped: String) -> Dictionary:
	var annotations: Array = []
	var s := stripped
	while s.begins_with("@"):
		var j := 1
		while j < s.length() and (GDScriptLexicalScanner._is_ident_part(s[j])):
			j += 1
		if j < s.length() and s[j] == "(":
			var depth := 0
			while j < s.length():
				if s[j] == "(":
					depth += 1
				elif s[j] == ")":
					depth -= 1
					if depth == 0:
						j += 1
						break
				j += 1
		annotations.append(s.substr(0, j))
		s = s.substr(j).strip_edges()
	return {"annotations": annotations, "rest": s}


static func _ident_prefix(s: String) -> String:
	var n := 0
	while n < s.length() and GDScriptLexicalScanner._is_ident_part(s[n]):
		n += 1
	return s.substr(0, n)


## When a func/signal declaration's parens don't close on its own line, append
## the following raw lines (trimmed, space-joined) until they balance — so the
## signature field shows the whole parameter list. Balance is computed on
## blanked lines (a ")" inside a default-value string can't fool it).
static func _join_multiline_signature(raw_sig: String, blanked_stripped: String, blanked_lines: PackedStringArray, raw_lines: PackedStringArray, i: int) -> String:
	var balance := _paren_balance(blanked_stripped)
	var sig := raw_sig
	var j := i + 1
	var appended := 0
	while balance > 0 and j < blanked_lines.size() and appended < MAX_SIGNATURE_CONTINUATION_LINES:
		if j < raw_lines.size():
			sig += " " + raw_lines[j].strip_edges()
		balance += _paren_balance(blanked_lines[j].strip_edges())
		j += 1
		appended += 1
	return sig


static func _paren_balance(s: String) -> int:
	var b := 0
	for k in range(s.length()):
		if s[k] == "(":
			b += 1
		elif s[k] == ")":
			b -= 1
	return b


static func _symbol(kind: String, name: String, line: int, signature: String) -> Dictionary:
	if signature.length() > MAX_SIGNATURE_CHARS:
		signature = signature.substr(0, MAX_SIGNATURE_CHARS)
	return {"kind": kind, "name": name, "line": line, "signature": signature}
