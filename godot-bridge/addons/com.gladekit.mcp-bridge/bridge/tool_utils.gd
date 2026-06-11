extends RefCounted

# Static helpers for tool implementations: response builders and defensive
# arg parsing. JSON over the wire arrives loosely typed (numbers may be int
# or float, booleans may be strings, etc.) so we coerce explicitly.


# ── Response builders ──────────────────────────────────────────────────────

static func success(message: String, extras: Dictionary = {}) -> Dictionary:
	var result := {"success": true, "message": message}
	for key in extras:
		result[key] = extras[key]
	return result


static func error(message: String, extras: Dictionary = {}) -> Dictionary:
	var result := {"success": false, "error": message, "message": message}
	for key in extras:
		result[key] = extras[key]
	return result


# error_with_solutions builds an error response that includes a
# `possible_solutions` array — short, ordered hints the agent can act on
# to recover. Pattern lifted (with MIT attribution) from godot-mcp's
# createErrorResponse at src/index.ts:181-202; that project's eval
# experience showed agents recover meaningfully faster when each error
# tells them what to try next.
static func error_with_solutions(
	message: String,
	possible_solutions: Array,
	extras: Dictionary = {}
) -> Dictionary:
	var result := error(message, extras)
	result["possible_solutions"] = possible_solutions
	return result


# ── Arg parsers (defensive against loose JSON typing) ──────────────────────

static func parse_string_arg(args: Dictionary, key: String, default_value: String = "") -> String:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	return str(v)


static func parse_int_arg(args: Dictionary, key: String, default_value: int = 0) -> int:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String:
		var s: String = v.strip_edges()
		if s.is_valid_int():
			return int(s)
	return default_value


static func parse_float_arg(args: Dictionary, key: String, default_value: float = 0.0) -> float:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String:
		var s: String = v.strip_edges()
		if s.is_valid_float():
			return float(s)
	return default_value


static func parse_bool_arg(args: Dictionary, key: String, default_value: bool = false) -> bool:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		var s: String = v.strip_edges().to_lower()
		return s == "true" or s == "1" or s == "yes"
	return default_value


# Normalize a project-relative path to a res:// URI. Leaves res:// and
# user:// paths untouched. Empty or null returns the default.
static func parse_path_arg(args: Dictionary, key: String, default_value: String = "") -> String:
	var path: String = parse_string_arg(args, key, default_value)
	if path.is_empty():
		return default_value
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	if path.begins_with("/"):
		path = path.substr(1)
	return "res://" + path


# Common requirement check: arg must be present and non-empty.
# Returns "" if valid, otherwise an error message describing what's missing.
static func require_string(args: Dictionary, key: String) -> String:
	if not args.has(key):
		return "Missing required arg '%s'" % key
	var v = args[key]
	if v == null:
		return "Required arg '%s' is null" % key
	if v is String and (v as String).is_empty():
		return "Required arg '%s' is empty" % key
	return ""


# ── Vector3 parsing ────────────────────────────────────────────────────────
# Tolerates three wire shapes:
#   "x,y,z" string  — matches the Unity bridge wire form
#   [x, y, z] array
#   {"x":..,"y":..,"z":..} dict
static func parse_vector3_arg(args: Dictionary, key: String, default_value: Vector3 = Vector3.ZERO) -> Vector3:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	if v is Vector3:
		return v
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() != 3:
			return default_value
		var out := Vector3.ZERO
		for i in 3:
			var p: String = parts[i].strip_edges()
			if not p.is_valid_float():
				return default_value
			out[i] = float(p)
		return out
	if v is Array:
		var arr: Array = v
		if arr.size() != 3:
			return default_value
		return Vector3(_num(arr[0]), _num(arr[1]), _num(arr[2]))
	if v is Dictionary:
		var d: Dictionary = v
		return Vector3(_num(d.get("x", 0.0)), _num(d.get("y", 0.0)), _num(d.get("z", 0.0)))
	return default_value


static func parse_vector2_arg(args: Dictionary, key: String, default_value: Vector2 = Vector2.ZERO) -> Vector2:
	if not args.has(key):
		return default_value
	var v = args[key]
	if v == null:
		return default_value
	if v is Vector2:
		return v
	if v is Vector2i:
		return Vector2(v.x, v.y)
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() < 2:
			return default_value
		var x: String = parts[0].strip_edges()
		var y: String = parts[1].strip_edges()
		if not x.is_valid_float() or not y.is_valid_float():
			return default_value
		return Vector2(float(x), float(y))
	if v is Array:
		var arr: Array = v
		if arr.size() < 2:
			return default_value
		return Vector2(_num(arr[0]), _num(arr[1]))
	if v is Dictionary:
		var d: Dictionary = v
		return Vector2(_num(d.get("x", 0.0)), _num(d.get("y", 0.0)))
	return default_value


static func _num(v) -> float:
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String and (v as String).strip_edges().is_valid_float():
		return float(v)
	return 0.0


static func serialize_vector3(v: Vector3) -> String:
	return "%s,%s,%s" % [v.x, v.y, v.z]


# ── Color parsing ──────────────────────────────────────────────────────────
# Tolerates four wire shapes:
#   Color object        — passed through
#   "#rrggbb[aa]" hex   — parsed via Color.html (returns default on invalid)
#   "r,g,b[,a]" CSV     — comma-separated floats
#   [r, g, b[, a]] array — typically 0..1 floats
# Returns the default when input is null, empty, or unrecognized — callers
# decide whether to treat that as "leave existing color alone" (pass current
# value as default) or as an error (compare against a sentinel default).
static func parse_color_arg(v, default_value: Color = Color.WHITE) -> Color:
	if v == null:
		return default_value
	if v is Color:
		return v
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_empty():
			return default_value
		if s.begins_with("#"):
			return Color.html(s) if Color.html_is_valid(s) else default_value
		var parts: PackedStringArray = s.split(",", false)
		if parts.size() < 3:
			return default_value
		var a := 1.0 if parts.size() < 4 else float(parts[3])
		return Color(float(parts[0]), float(parts[1]), float(parts[2]), a)
	if v is Array:
		var arr: Array = v
		if arr.size() < 3:
			return default_value
		var a2 := 1.0 if arr.size() < 4 else _num(arr[3])
		return Color(_num(arr[0]), _num(arr[1]), _num(arr[2]), a2)
	return default_value


# ── Levenshtein edit distance ──────────────────────────────────────────────
# Iterative two-row Levenshtein. O(m*n) time, O(n) memory. Used by
# error-recovery code paths (signal connect, resource class lookup) to suggest
# the closest typo'd name; inputs are short (<32 chars) so this is trivial.
static func levenshtein(a: String, b: String) -> int:
	var m: int = a.length()
	var n: int = b.length()
	if m == 0:
		return n
	if n == 0:
		return m
	var prev := PackedInt32Array()
	prev.resize(n + 1)
	for j in range(n + 1):
		prev[j] = j
	for i in range(1, m + 1):
		var curr := PackedInt32Array()
		curr.resize(n + 1)
		curr[0] = i
		for j in range(1, n + 1):
			var cost: int = 0 if a[i - 1] == b[j - 1] else 1
			curr[j] = min(min(prev[j] + 1, curr[j - 1] + 1), prev[j - 1] + cost)
		prev = curr
	return prev[n]


# Safely resolve the EditorInterface singleton. Returns null in non-editor
# contexts (e.g. GUT runs tests via play_custom_scene or gut_cmdln where
# EditorInterface isn't available).
#
# Two engine quirks make this helper necessary:
#
# 1. GDScript parses the bare identifier `EditorInterface` at compile time
#    as a class reference. In non-editor contexts that class has no
#    instance methods, so `EditorInterface.<anything>` raises "Nonexistent
#    function in base 'EditorInterface'" — even when the call is gated by
#    Engine.has_singleton(), because the parse-time resolution doesn't
#    depend on runtime singleton state. Fetching via Engine.get_singleton()
#    and calling through the returned variable defers method lookup to
#    runtime, against the actual instance.
#
# 2. On Godot 4.6+, Engine.has_singleton("EditorInterface") returns true
#    even in game-runtime/headless contexts, but Engine.get_singleton()
#    then raises a C++ "Can't retrieve singleton 'EditorInterface' outside
#    of editor" error (engine.cpp get_singleton_object). The
#    Engine.is_editor_hint() gate short-circuits before that call so test
#    runs stay error-free.
static func get_editor_interface_safe() -> Object:
	if not Engine.is_editor_hint():
		return null
	if not Engine.has_singleton("EditorInterface"):
		return null
	return Engine.get_singleton("EditorInterface")


# Safely resolve the currently-edited scene root. Returns null in
# non-editor contexts. See get_editor_interface_safe for the rationale.
static func get_edited_scene_root_safe() -> Node:
	var ei: Object = get_editor_interface_safe()
	if ei == null:
		return null
	return ei.get_edited_scene_root()


# Clear a node (and any selected descendants) from the editor selection
# before it is freed. Freeing a node while the scene-tree dock / inspector
# holds it selected leaves them pointing at a dead object until the editor
# revalidates — the dangling-reference class that delete/revert paths must
# avoid. Call immediately before remove_child()/free(). No-op outside the
# editor or when nothing relevant is selected.
#
# The parameter is deliberately untyped: the contract includes tolerating
# an already-freed node (delete/revert paths may double-handle), and on
# Godot 4.6+ passing a freed instance to a `Node`-typed parameter raises
# "Invalid type ... previously freed" at the call boundary, before the
# body's is_instance_valid check could run.
static func deselect_before_free(node) -> void:
	if node == null or not is_instance_valid(node) or not (node is Node):
		return
	var ei: Object = get_editor_interface_safe()
	if ei == null:
		return
	var selection: Object = ei.get_selection()
	if selection == null:
		return
	for selected: Node in selection.get_selected_nodes():
		if selected == node or node.is_ancestor_of(selected):
			selection.remove_node(selected)


# ── Node-path resolution ───────────────────────────────────────────────────
# Looks up a node within the currently-edited scene by either an explicit
# NodePath ("Player/Sprite", "/root/Main/Player") or a node name to search
# recursively. Returns null if not found.
#
# Resolution order:
#   1. Empty/"." → the edited scene root itself
#   2. Path containing "/" → get_node_or_null relative to root (or absolute)
#   3. Single token → root.find_child(name, recursive=true, owned=false)
static func find_node_by_path(node_path: String) -> Node:
	var root: Node = get_edited_scene_root_safe()
	if root == null:
		return null
	var p: String = node_path.strip_edges()
	if p.is_empty() or p == ".":
		return root
	if p.begins_with("/root/"):
		# Absolute NodePath. EditorInterface only owns the edited scene, not
		# the live root tree; trim to the scene-relative portion.
		var relative := p.substr(6)  # strip "/root/"
		var slash_index := relative.find("/")
		if slash_index == -1:
			# Whole path was just "/root/<sceneRoot>" — return root if names match.
			if relative == String(root.name):
				return root
			return null
		var scene_root_name := relative.substr(0, slash_index)
		if scene_root_name != String(root.name):
			return null
		var rest := relative.substr(slash_index + 1)
		return root.get_node_or_null(rest)
	if p.contains("/"):
		# Agents frequently prefix a scene-relative path with the root's own
		# name (e.g. "Main/Player" when the edited scene root is "Main").
		# A NodePath relative to root must NOT include the root segment, so
		# get_node_or_null("Main/Player") would miss. Strip a leading
		# root-name segment before resolving.
		var first_slash := p.find("/")
		if p.substr(0, first_slash) == String(root.name):
			var rest := p.substr(first_slash + 1)
			return root if rest.is_empty() else root.get_node_or_null(rest)
		return root.get_node_or_null(p)
	# Bare name. get_scene_tree renders the scene root flush-left as
	# "<Name> (<Type>)", so agents routinely pass the root's own name as a
	# parent/target. find_child searches descendants only and never matches
	# the root itself — resolve the root name here before falling back to a
	# descendant search.
	if p == String(root.name):
		return root
	return root.find_child(p, true, false)


# ── Args normalization (camelCase ↔ snake_case) ────────────────────────────
# Agents trained on JS/TS-heavy MCP servers (including the popular
# godot-mcp) often emit camelCase keys (`nodePath`, `parentPath`,
# `scriptPath`). Our tools are documented in snake_case. Normalize every
# inbound arg to snake_case in one place so each tool's execute() sees a
# consistent shape and doesn't have to dual-check.
#
# Original-key precedence is preserved: if both `node_path` and `nodePath`
# arrive in the same dict, snake_case wins (the documented form). This
# avoids surprises when an agent mixes styles in a single call.
#
# Pattern adopted from godot-mcp (src/index.ts:424-475, MIT). Our version
# operates on the GDScript side instead of the MCP-server side so the
# normalization is uniform regardless of which client called us
# (Cursor / Claude Code / curl / the GladeKit desktop app).
static func normalize_args(args: Dictionary) -> Dictionary:
	if args == null or args.is_empty():
		return args
	var out: Dictionary = {}
	# First pass: copy snake_case keys verbatim, so they take precedence.
	for key in args.keys():
		var k: String = str(key)
		if not _has_uppercase(k):
			out[k] = args[key]
	# Second pass: convert camelCase keys, but skip when snake_case version
	# already won.
	for key in args.keys():
		var k: String = str(key)
		if not _has_uppercase(k):
			continue
		var snake := _camel_to_snake(k)
		if not out.has(snake):
			out[snake] = args[key]
	return out


static func _has_uppercase(s: String) -> bool:
	for i in s.length():
		var c := s[i]
		if c >= "A" and c <= "Z":
			return true
	return false


static func _camel_to_snake(s: String) -> String:
	var out := ""
	for i in s.length():
		var c := s[i]
		if c >= "A" and c <= "Z":
			if i > 0:
				out += "_"
			out += c.to_lower()
		else:
			out += c
	return out


# ── Class instantiation (safe, supports user class_names) ──────────────────
#
# Adapted from godot-mcp src/scripts/godot_operations.gd:95-162 (MIT, see
# godot-bridge/NOTICE). Two-step resolution:
#   1. Strict regex against agent-supplied class name to prevent injection
#      through `ClassDB.instantiate(<arbitrary>)`.
#   2. Try ClassDB first (built-in types: CharacterBody3D, Sprite2D, ...).
#      Fall back to ProjectSettings.get_global_class_list() to resolve
#      user-declared `class_name MyEnemy` scripts — for these, instantiate
#      the script's base class then attach the script.
#
# Returns:
#   { "instance": Object|null, "error": String, "source": "class_db"|"user_script"|"" }
# `instance` is null on any failure; check `error` for the reason.
const _CLASS_NAME_REGEX := "^[A-Za-z_][A-Za-z0-9_]*$"

static func safe_instantiate_class(class_name_in: String) -> Dictionary:
	if class_name_in.is_empty():
		return {"instance": null, "error": "class name is empty", "source": ""}
	var re := RegEx.new()
	re.compile(_CLASS_NAME_REGEX)
	if re.search(class_name_in) == null:
		return {
			"instance": null,
			"error": "class name '%s' contains invalid characters (must match %s)" % [class_name_in, _CLASS_NAME_REGEX],
			"source": "",
		}

	if ClassDB.class_exists(class_name_in):
		if not ClassDB.can_instantiate(class_name_in):
			return {
				"instance": null,
				"error": "class '%s' exists in ClassDB but is not instantiable (abstract / singleton)" % class_name_in,
				"source": "class_db",
			}
		var inst = ClassDB.instantiate(class_name_in)
		if inst == null:
			return {"instance": null, "error": "ClassDB.instantiate('%s') returned null" % class_name_in, "source": "class_db"}
		return {"instance": inst, "error": "", "source": "class_db"}

	# Not a built-in class — search user-declared `class_name` scripts.
	for entry in ProjectSettings.get_global_class_list():
		if not (entry is Dictionary):
			continue
		if String(entry.get("class", "")) != class_name_in:
			continue
		var script_path := String(entry.get("path", ""))
		var base_class := String(entry.get("base", ""))
		if script_path.is_empty() or base_class.is_empty():
			return {
				"instance": null,
				"error": "user class '%s' is registered but missing path/base metadata" % class_name_in,
				"source": "user_script",
			}
		var script := load(script_path)
		if not (script is Script):
			return {
				"instance": null,
				"error": "user class '%s' did not load as a Script (got %s)" % [class_name_in, script_path],
				"source": "user_script",
			}
		# Instantiate the base class; attach the user script.
		var base_inst = ClassDB.instantiate(base_class)
		if base_inst == null:
			return {
				"instance": null,
				"error": "base class '%s' for user class '%s' could not be instantiated" % [base_class, class_name_in],
				"source": "user_script",
			}
		base_inst.set_script(script)
		return {"instance": base_inst, "error": "", "source": "user_script"}

	return {
		"instance": null,
		"error": "no class '%s' found in ClassDB or user-declared global_class_list" % class_name_in,
		"source": "",
	}


# ── Godot version comparison ──────────────────────────────────────────────
# Compares semver-style "X.Y" or "X.Y.Z" strings. Returns:
#   -1 if a < b,  0 if equal,  1 if a > b
# Missing components are treated as 0 (so "4.4" < "4.4.1").
static func compare_versions(a: String, b: String) -> int:
	var pa := _split_version(a)
	var pb := _split_version(b)
	var n: int = max(pa.size(), pb.size())
	for i in n:
		var ai: int = pa[i] if i < pa.size() else 0
		var bi: int = pb[i] if i < pb.size() else 0
		if ai < bi:
			return -1
		if ai > bi:
			return 1
	return 0


static func _split_version(v: String) -> Array:
	var parts: Array = []
	for token in v.split(".", false):
		if String(token).strip_edges().is_valid_int():
			parts.append(int(token))
		else:
			parts.append(0)
	return parts


# Build a scene-relative path string for a node ("Player/Sprite"). Returns ""
# if the node is the scene root, or null/not in the edited scene.
static func node_relative_path(node: Node) -> String:
	if node == null:
		return ""
	var root: Node = get_edited_scene_root_safe()
	if root == null or node == root:
		return ""
	var parts: PackedStringArray = []
	var current: Node = node
	while current != null and current != root:
		parts.insert(0, String(current.name))
		current = current.get_parent()
	if current != root:
		return ""  # node is not a descendant of the edited scene root
	return "/".join(parts)
