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
	var root: Node = EditorInterface.get_edited_scene_root()
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
		return root.get_node_or_null(p)
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
	var root: Node = EditorInterface.get_edited_scene_root()
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
