extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Create any built-in Godot Resource subclass and save it as a .tres file.
# Composition partner to set_node_resource: create here, then assign there.
#
# Out of scope (each has a dedicated tool with specialized args):
#   * Material / StandardMaterial3D / ShaderMaterial → create_material
#   * Script  / GDScript / CSharpScript            → create_script
#
# Args:
#   path:       String   (required) — res:// path for the .tres file. Auto-
#                                     appends .tres if no extension.
#   type:       String   (required) — Godot class name (PascalCase). Must be
#                                     a concrete Resource subclass registered
#                                     in ClassDB.
#   properties: Dictionary (optional) — initial property values, keyed by
#                                       property name. Auto-parses Vector2/3/4
#                                       (from "x,y,z" or [x,y,z]), Color
#                                       (from "#rrggbb" / "r,g,b"), and primitives.
#                                       Unknown keys land in unapplied_properties
#                                       with a reason so the agent can retry.
#
# Validation (short-circuits with error_with_solutions on failure):
#   1. ClassDB.class_exists(type) — unknown class returns 5 edit-distance suggestions
#   2. is_subclass_of(type, "Resource") — Node/non-Resource types redirect
#   3. type not in SPECIALIZED_REDIRECT — Material/Script redirect to their tools
#   4. ClassDB.can_instantiate(type) — abstract types return concrete subclasses
#   5. DemoAssetsGuard.check_write(path) — protects demo content
#   6. !FileAccess.file_exists(path) — refuses overwrite (no in-place edit)
#
# Response payload (success):
#   path, type, applied_properties [name], unapplied_properties [{name, reason}]

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const DemoAssetsGuard = preload("res://addons/com.gladekit.mcp-bridge/services/demo_assets_guard.gd")

const MAX_SUGGESTIONS := 5

# Types that have dedicated tools. Routing here saves the agent a wrong call
# and keeps the three resource creators (this, create_material, create_script)
# cleanly partitioned.
const SPECIALIZED_REDIRECT := {
	"Material": "create_material",
	"StandardMaterial3D": "create_material",
	"ORMMaterial3D": "create_material",
	"ShaderMaterial": "create_material (set material_type='shader')",
	"CanvasItemMaterial": "create_material",
	"Script": "create_script",
	"GDScript": "create_script",
	"CSharpScript": "create_script",
}


func _init() -> void:
	tool_name = "create_resource"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path: String = ToolUtils.parse_path_arg(args, "path")
	if path.is_empty():
		return ToolUtils.error("path is required (res:// URI for the .tres file)")
	if path.get_extension().is_empty():
		path += ".tres"

	var type_name: String = ToolUtils.parse_string_arg(args, "type")
	if type_name.is_empty():
		return ToolUtils.error(
			"type is required (Godot class name, e.g. 'BoxMesh', 'BoxShape3D', 'Curve')"
		)

	# Redirect specialized types to their dedicated tools.
	if SPECIALIZED_REDIRECT.has(type_name):
		var dedicated: String = SPECIALIZED_REDIRECT[type_name]
		return ToolUtils.error_with_solutions(
			"%s has a dedicated tool — use %s instead" % [type_name, dedicated],
			["Call %s, which exposes the right args for this class" % dedicated]
		)

	# Class registration check.
	if not ClassDB.class_exists(type_name):
		return ToolUtils.error_with_solutions(
			"Unknown Godot class '%s'" % type_name,
			[
				"Check spelling — Godot class names are PascalCase (e.g. 'BoxMesh' not 'box_mesh')",
				"Pick from the suggestions below",
			],
			{"suggestions": _suggest_resource_classes(type_name)}
		)

	# Must be a Resource subclass. Node/Object types redirect to create_node.
	if not ClassDB.is_parent_class(type_name, "Resource"):
		return ToolUtils.error_with_solutions(
			"'%s' is not a Resource subclass — create_resource only handles Resource types" % type_name,
			[
				"For scene nodes, use create_node",
				"For a MeshInstance3D with inline primitive mesh, use create_primitive_3d",
			]
		)

	# Abstract types can't be instantiated — surface concrete subclasses.
	if not ClassDB.can_instantiate(type_name):
		return ToolUtils.error_with_solutions(
			"'%s' is abstract and cannot be instantiated directly" % type_name,
			["Pick a concrete subclass — see suggestions below"],
			{"suggestions": _concrete_subclasses(type_name, MAX_SUGGESTIONS)}
		)

	var guard_err := DemoAssetsGuard.check_write(path)
	if not guard_err.is_empty():
		return ToolUtils.error(guard_err)

	if FileAccess.file_exists(path):
		return ToolUtils.error_with_solutions(
			"File already exists at '%s'" % path,
			[
				"Pick a different path",
				"Or delete the file via the editor first — create_resource never overwrites in place",
			]
		)

	# Instantiate.
	var res = ClassDB.instantiate(type_name)
	if not (res is Resource):
		# Belt-and-suspenders — should be caught by is_parent_class above.
		return ToolUtils.error("ClassDB.instantiate('%s') did not return a Resource" % type_name)

	# Apply caller-provided properties, recording which stuck and which didn't.
	var applied: Array = []
	var unapplied: Array = []
	if args.has("properties") and args["properties"] != null:
		var props = args["properties"]
		if not (props is Dictionary):
			return ToolUtils.error(
				"properties must be an object/dictionary (got %s). " % typeof(props)
				+ "Example: {\"size\": \"2,2,2\", \"radius\": 0.5}"
			)
		_apply_properties(res, props, applied, unapplied)

	# Save to disk. Mirror create_material's flow: ensure dir, save, refresh.
	var dir_path := path.get_base_dir()
	if not dir_path.is_empty():
		var derr := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
		if derr != OK and derr != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (err %d)" % [dir_path, derr])

	var save_err := ResourceSaver.save(res, path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [path, save_err])

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)

	return ToolUtils.success(
		"Created %s at '%s' (%d propert%s applied)" % [
			type_name, path, applied.size(), "y" if applied.size() == 1 else "ies"
		],
		{
			"path": path,
			"type": type_name,
			"applied_properties": applied,
			"unapplied_properties": unapplied,
		}
	)


# ── Property application ─────────────────────────────────────────────────────

# Set each caller-provided property on the resource, converting common scalar
# types (Vector2/3/4, Color, primitives) to match the property's declared type.
# Unknown property names land in `unapplied` with a reason — agents use this
# to retry with the correct name on the next call instead of silently dropping.
func _apply_properties(res: Resource, props: Dictionary, applied: Array, unapplied: Array) -> void:
	# Build name → expected-variant-type map once, then iterate caller props.
	var prop_types: Dictionary = {}
	for p in res.get_property_list():
		prop_types[String(p.get("name", ""))] = int(p.get("type", TYPE_NIL))

	for key in props:
		var name := String(key)
		if not prop_types.has(name):
			unapplied.append({
				"name": name,
				"reason": "property does not exist on %s" % res.get_class(),
			})
			continue
		var converted = _convert_for_type(props[key], prop_types[name])
		res.set(name, converted)
		applied.append(name)


# Convert a raw arg value to the property's expected Godot variant type.
# Pass-through for types we don't specifically handle — Godot's variant system
# will coerce numerically-compatible values and reject the rest at save time.
func _convert_for_type(value, expected_type: int):
	match expected_type:
		TYPE_VECTOR2:
			return _vec2_from(value)
		TYPE_VECTOR3:
			return _vec3_from(value)
		TYPE_VECTOR4:
			return _vec4_from(value)
		TYPE_COLOR:
			return _color_from(value)
		TYPE_INT:
			if value is int:
				return value
			if value is float:
				return int(value)
			if value is String and (value as String).strip_edges().is_valid_int():
				return int((value as String).strip_edges())
			return value
		TYPE_FLOAT:
			if value is float:
				return value
			if value is int:
				return float(value)
			if value is String and (value as String).strip_edges().is_valid_float():
				return float((value as String).strip_edges())
			return value
		TYPE_BOOL:
			return _bool_from(value)
		TYPE_STRING:
			return str(value)
		_:
			return value


# ── Type discovery helpers (token-efficient error recovery) ─────────────────

# Top-N edit-distance ranked concrete Resource subclasses. Cures typos and
# wrong-pluralization (e.g. 'BoxMeshes' → 'BoxMesh') without enumerating the
# full ~200-class ClassDB to the agent.
func _suggest_resource_classes(query: String) -> Array:
	var resource_classes: PackedStringArray = ClassDB.get_inheriters_from_class("Resource")
	var scored: Array = []
	var ql := query.to_lower()
	for c in resource_classes:
		if not ClassDB.can_instantiate(c):
			continue
		var dist := _levenshtein(ql, String(c).to_lower())
		scored.append([dist, String(c)])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	var out: Array = []
	for i in range(min(MAX_SUGGESTIONS, scored.size())):
		out.append(scored[i][1])
	return out


# Direct concrete subclasses of an abstract type, capped at `limit`.
func _concrete_subclasses(abstract_type: String, limit: int) -> Array:
	var children: PackedStringArray = ClassDB.get_inheriters_from_class(abstract_type)
	var out: Array = []
	for c in children:
		if ClassDB.can_instantiate(c):
			out.append(String(c))
		if out.size() >= limit:
			break
	return out


# Two-row Levenshtein. Good enough for short class names — we never compare
# strings longer than ~30 chars here so the O(n*m) cost is trivial.
func _levenshtein(a: String, b: String) -> int:
	var n := a.length()
	var m := b.length()
	if n == 0:
		return m
	if m == 0:
		return n
	var prev := PackedInt32Array()
	prev.resize(m + 1)
	for j in range(m + 1):
		prev[j] = j
	for i in range(1, n + 1):
		var curr := PackedInt32Array()
		curr.resize(m + 1)
		curr[0] = i
		for j in range(1, m + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			curr[j] = min(curr[j - 1] + 1, min(prev[j] + 1, prev[j - 1] + cost))
		prev = curr
	return prev[m]


# ── Value converters (agent-friendly string forms) ───────────────────────────

func _vec2_from(v) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() >= 2:
			return Vector2(float(parts[0]), float(parts[1]))
	return Vector2.ZERO


func _vec3_from(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() >= 3:
			return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
	return Vector3.ZERO


func _vec4_from(v) -> Vector4:
	if v is Vector4:
		return v
	if v is Array and v.size() >= 4:
		return Vector4(float(v[0]), float(v[1]), float(v[2]), float(v[3]))
	if v is String:
		var parts: PackedStringArray = (v as String).split(",", false)
		if parts.size() >= 4:
			return Vector4(float(parts[0]), float(parts[1]), float(parts[2]), float(parts[3]))
	return Vector4.ZERO


func _color_from(v) -> Color:
	if v is Color:
		return v
	if v is String:
		var s: String = (v as String).strip_edges()
		if s.is_empty():
			return Color.WHITE
		if s.begins_with("#"):
			return Color.html(s) if Color.html_is_valid(s) else Color.WHITE
		var parts: PackedStringArray = s.split(",", false)
		if parts.size() >= 3:
			var a := 1.0 if parts.size() < 4 else float(parts[3])
			return Color(float(parts[0]), float(parts[1]), float(parts[2]), a)
	return Color.WHITE


func _bool_from(v) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		var s: String = (v as String).strip_edges().to_lower()
		return s == "true" or s == "1" or s == "yes"
	return false
