extends GutTest

# Pure tests for gdscript_outline.gd — no editor / scene tree access, safe to
# run headlessly. Covers the block-context contract (inner-class members
# emitted, func-locals excluded) and the line-scan traps: annotations on a
# previous line, `static func`, anonymous enums, multi-line signatures, and
# declaration keywords inside docstrings/comments.

const GDScriptOutline = preload("res://addons/com.gladekit.mcp-bridge/services/gdscript_outline.gd")


static func _src(lines: Array) -> String:
	return "\n".join(PackedStringArray(lines))


static func _find(symbols: Array, kind: String, name: String) -> Dictionary:
	for s in symbols:
		if s["kind"] == kind and s["name"] == name:
			return s
	return {}


static func _kinds_and_names(symbols: Array) -> Array:
	var out: Array = []
	for s in symbols:
		out.append("%s:%s" % [s["kind"], s["name"]])
	return out


# ── script-level basics ───────────────────────────────────────────────────

func test_script_level_declarations() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"class_name Hero",
		"extends CharacterBody2D",
		"",
		"signal died(cause)",
		"enum State { IDLE, RUN }",
		"const MAX_HP := 10",
		"@export var health := 3",
		"@onready var sprite = $Sprite2D",
		"var plain_var := 1",
		"",
		"func _ready():",
		"\tpass",
	]))

	assert_eq(_find(symbols, "class_name", "Hero")["line"], 1)
	assert_eq(_find(symbols, "signal", "died")["line"], 4)
	assert_eq(_find(symbols, "enum", "State")["line"], 5)
	assert_eq(_find(symbols, "const", "MAX_HP")["line"], 6)
	assert_eq(_find(symbols, "export_var", "health")["line"], 7)
	assert_eq(_find(symbols, "onready_var", "sprite")["line"], 8)
	assert_eq(_find(symbols, "func", "_ready")["line"], 11)
	# A plain class-level var is deliberately NOT outline-worthy.
	for s in symbols:
		assert_ne(s["name"], "plain_var", "plain var must not be emitted")
	# `extends` is not a symbol.
	assert_eq(symbols.size(), 7, "exactly the 7 declarations: %s" % [_kinds_and_names(symbols)])


func test_symbols_in_source_order() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"func b():",
		"\tpass",
		"func a():",
		"\tpass",
	]))
	assert_eq(symbols.size(), 2)
	assert_eq(symbols[0]["name"], "b")
	assert_eq(symbols[1]["name"], "a")


# ── annotation on a previous line ─────────────────────────────────────────

func test_annotation_on_previous_line_still_classifies() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"@export",
		"var health := 3",
		"@export_range(0, 10)",
		"var speed := 5",
	]))

	var health := _find(symbols, "export_var", "health")
	assert_eq(health["line"], 2, "line points at the var declaration")
	assert_string_contains(health["signature"], "@export")
	var speed := _find(symbols, "export_var", "speed")
	assert_eq(speed["line"], 4)
	assert_string_contains(speed["signature"], "@export_range(0, 10)")


# ── static func (two tokens) ──────────────────────────────────────────────

func test_static_func_recognized() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"static func helper(a, b):",
		"\treturn a + b",
	]))
	var sym := _find(symbols, "func", "helper")
	assert_eq(sym["line"], 1)
	assert_string_contains(sym["signature"], "static func helper")


# ── anonymous enum ────────────────────────────────────────────────────────

func test_anonymous_enum_has_empty_name() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"enum { A, B }",
	]))
	assert_eq(symbols.size(), 1)
	assert_eq(symbols[0]["kind"], "enum")
	assert_eq(symbols[0]["name"], "")


# ── multi-line signatures ─────────────────────────────────────────────────

func test_multiline_func_signature_joined() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"func long_sig(a: int,",
		"\t\tb: int = 2) -> int:",
		"\treturn a + b",
	]))
	assert_eq(symbols.size(), 1, "continuation line must not produce a phantom symbol")
	var sym := _find(symbols, "func", "long_sig")
	assert_eq(sym["line"], 1)
	assert_string_contains(sym["signature"], "b: int = 2) -> int:")


# ── masked regions (docstrings + comments) ────────────────────────────────

func test_keywords_in_docstring_and_comment_not_emitted() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"func real():",
		"\t\"\"\"",
		"\tfunc fake_in_docstring():",
		"\tsignal fake_signal",
		"\t\"\"\"",
		"\tpass",
		"# func commented_out():",
		"const AFTER := 1",
	]))
	assert_eq(_find(symbols, "func", "fake_in_docstring"), {}, "docstring interior must be masked")
	assert_eq(_find(symbols, "signal", "fake_signal"), {})
	assert_eq(_find(symbols, "func", "commented_out"), {})
	assert_ne(_find(symbols, "func", "real"), {})
	assert_ne(_find(symbols, "const", "AFTER"), {}, "scan must resume after the docstring")


# ── block context: func bodies excluded, inner classes included ───────────

func test_func_local_declarations_excluded() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"func outer():",
		"\tconst LOCAL := 5",
		"\tvar cb = func(x): return x",
		"\treturn LOCAL",
		"const SCRIPT_LEVEL := 9",
	]))
	assert_eq(_find(symbols, "const", "LOCAL"), {}, "func-local const must be excluded")
	assert_eq(_find(symbols, "func", "cb"), {}, "a lambda is not a declaration")
	assert_ne(_find(symbols, "func", "outer"), {})
	assert_ne(_find(symbols, "const", "SCRIPT_LEVEL"), {}, "dedent must pop the func scope")


func test_inner_class_members_emitted_but_their_func_locals_excluded() -> void:
	var symbols := GDScriptOutline.extract(_src([
		"class Inner:",
		"\tconst INNER_CONST := 1",
		"\t@export var inner_exported := 2",
		"\tfunc inner_method():",
		"\t\tconst IN_FUNC := 3",
		"\t\treturn IN_FUNC",
		"",
		"func after_class():",
		"\tpass",
	]))
	assert_eq(_find(symbols, "class", "Inner")["line"], 1)
	assert_eq(_find(symbols, "const", "INNER_CONST")["line"], 2)
	assert_eq(_find(symbols, "export_var", "inner_exported")["line"], 3)
	assert_eq(_find(symbols, "func", "inner_method")["line"], 4)
	assert_eq(_find(symbols, "const", "IN_FUNC"), {}, "inner-class method locals must be excluded")
	assert_eq(_find(symbols, "func", "after_class")["line"], 8, "dedent must pop back to script level")


# ── degenerate inputs ─────────────────────────────────────────────────────

func test_empty_source_yields_no_symbols() -> void:
	assert_eq(GDScriptOutline.extract("").size(), 0)


func test_signature_capped_at_200_chars() -> void:
	var long_tail := "x".repeat(300)
	var symbols := GDScriptOutline.extract("const LONG := \"%s\"" % long_tail)
	assert_eq(symbols.size(), 1)
	assert_true(String(symbols[0]["signature"]).length() <= 200)
