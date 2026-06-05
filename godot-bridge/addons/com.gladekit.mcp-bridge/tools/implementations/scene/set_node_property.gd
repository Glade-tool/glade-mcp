extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sets a single non-Resource property to a literal value on any node in the
# edited scene, via Godot's reflection (the node's property list + Object.set).
# This is the generic companion to the specialized setters: where
# set_node_transform owns position/rotation/scale and set_node_resource owns
# Resource-typed (Object) properties, set_node_property covers everything else —
# scalars, vectors, colors, booleans, enums, strings. One tool turns the
# already-generic create_node into a complete "create then configure" workflow:
#
#   AudioStreamPlayer.volume_db / .autoplay / .pitch_scale
#   Camera3D.fov / .current / .cull_mask
#   GPUParticles3D.amount / .lifetime / .emitting / .one_shot
#   RigidBody3D.mass / .gravity_scale / .freeze
#   Light3D.light_energy, OmniLight3D.omni_range, Label.text, ...
#
# Args:
#   node_path: String (required) — target node in the edited scene.
#   property:  String (required) — property name as Godot exposes it
#                                  (snake_case, e.g. "volume_db", "fov", "mass").
#   value:     any (required)    — the new value, coerced to the property's
#                                  declared type:
#                                    bool   ← true/false/"true"/1/0
#                                    int    ← number, numeric string, or enum
#                                             label ("PROCESS_MODE_ALWAYS")
#                                    float  ← number or numeric string
#                                    String ← any value stringified
#                                    Vector2/3 ← "x,y[,z]" | [x,y,z] | {x,y,z}
#                                    Color  ← "#rrggbb[aa]" | [r,g,b,a] | "r,g,b"
#
# Resource-typed (Object) properties are rejected with a redirect to
# set_node_resource (which loads from a res:// path). Unknown properties return
# the node's settable property names + the nearest match for recovery.
#
# Response payload:
#   node_path, property, value (read back after the set), previous_value,
#   value_type (Godot type name, e.g. "float", "Vector3", "bool")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Cap on how many property names we echo back in an error / discovery payload —
# some nodes expose 150+ properties and we don't want to flood the agent.
const _MAX_LISTED_PROPERTIES := 80


func _init() -> void:
	tool_name = "set_node_property"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	if not args.has("node_path"):
		return ToolUtils.error("node_path is required")
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var node: Node = ToolUtils.find_node_by_path(node_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found" % node_path)

	var property: String = ToolUtils.parse_string_arg(args, "property")
	if property.is_empty():
		return ToolUtils.error("property is required (e.g. 'volume_db', 'fov', 'mass')")

	if not args.has("value"):
		return ToolUtils.error_with_solutions(
			"value is required",
			[
				"Pass value as a number, bool, string, 'x,y,z' vector, or '#rrggbb' color",
				"To read current values, call get_node_info with include_properties=true",
			]
		)

	var prop_info: Dictionary = _find_settable_property(node, property)
	if prop_info.is_empty():
		return ToolUtils.error_with_solutions(
			"Node '%s' (%s) has no settable property '%s'" % [node_path, node.get_class(), property],
			_suggestions(node, property),
			{"settable_properties": _settable_property_names(node)}
		)

	var prop_type: int = int(prop_info.get("type", TYPE_NIL))
	if prop_type == TYPE_OBJECT:
		return ToolUtils.error_with_solutions(
			"Property '%s' on %s is Resource-typed, not a literal value" % [property, node.get_class()],
			[
				"Use set_node_resource to assign a res:// resource to '%s'" % property,
				"set_node_property only sets scalars, vectors, colors, bools, and enums",
			]
		)

	var prev = node.get(property)
	var coerced = _coerce(args, "value", prop_type, prop_info, prev)
	node.set(property, coerced)
	# Read back so the response reflects what Godot actually stored (it may
	# clamp, round, or reject — e.g. Camera3D.current toggling another camera).
	var applied = node.get(property)

	return ToolUtils.success(
		"Set %s.%s = %s" % [node_path, property, str(applied)],
		{
			"node_path": node_path,
			"property": property,
			"value": _serialize(applied),
			"previous_value": _serialize(prev),
			"value_type": type_string(prop_type),
		}
	)


# Returns the property-list entry whose name matches and is settable (editor- or
# storage-visible, with a concrete type — skips category/group header rows that
# carry TYPE_NIL). Returns {} when absent.
func _find_settable_property(node: Node, property_name: String) -> Dictionary:
	for p in node.get_property_list():
		if String(p.get("name", "")) != property_name:
			continue
		if int(p.get("type", TYPE_NIL)) == TYPE_NIL:
			continue
		if not _is_settable(p):
			continue
		return p
	return {}


func _is_settable(p: Dictionary) -> bool:
	var usage: int = int(p.get("usage", 0))
	return (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)) != 0


# Settable, non-Resource property names — the set this tool can actually write,
# used both for error recovery and for get_node_info's include_properties view.
func _settable_property_names(node: Node) -> Array:
	var out: Array = []
	for p in node.get_property_list():
		var t: int = int(p.get("type", TYPE_NIL))
		if t == TYPE_NIL or t == TYPE_OBJECT:
			continue
		if not _is_settable(p):
			continue
		out.append(String(p.get("name", "")))
		if out.size() >= _MAX_LISTED_PROPERTIES:
			break
	return out


func _suggestions(node: Node, property_name: String) -> Array:
	var names: Array = _settable_property_names(node)
	var best: String = ""
	var best_dist: int = 1 << 30
	for n in names:
		var d: int = ToolUtils.levenshtein(property_name, String(n))
		if d < best_dist:
			best_dist = d
			best = String(n)
	var hints: Array = []
	# Only suggest a near-match when it's actually close — an unrelated nearest
	# string is noise, not a hint.
	if not best.is_empty() and best_dist <= 3:
		hints.append("Did you mean '%s'?" % best)
	hints.append("Pick a name from settable_properties below")
	hints.append("For a Resource property (mesh/texture/stream/...) use set_node_resource")
	return hints


# Coerces the raw incoming value to the property's declared Variant type. Reuses
# the shared arg parsers so behaviour matches the rest of the bridge.
func _coerce(args: Dictionary, key: String, prop_type: int, prop_info: Dictionary, current):
	var value = args.get(key)
	match prop_type:
		TYPE_BOOL:
			return ToolUtils.parse_bool_arg(args, key, bool(current) if current is bool else false)
		TYPE_INT:
			var enum_val: int = _resolve_enum(value, prop_info)
			if enum_val != -0x7FFFFFFF:
				return enum_val
			return ToolUtils.parse_int_arg(args, key, int(current) if (current is int or current is float) else 0)
		TYPE_FLOAT:
			return ToolUtils.parse_float_arg(args, key, float(current) if (current is int or current is float) else 0.0)
		TYPE_STRING:
			return String(value)
		TYPE_STRING_NAME:
			return StringName(String(value))
		TYPE_NODE_PATH:
			return NodePath(String(value))
		TYPE_VECTOR2:
			var a2 := _vec_components(value, 2, current)
			return Vector2(a2[0], a2[1])
		TYPE_VECTOR2I:
			var a2i := _vec_components(value, 2, current)
			return Vector2i(roundi(a2i[0]), roundi(a2i[1]))
		TYPE_VECTOR3:
			var a3 := _vec_components(value, 3, current)
			return Vector3(a3[0], a3[1], a3[2])
		TYPE_VECTOR3I:
			var a3i := _vec_components(value, 3, current)
			return Vector3i(roundi(a3i[0]), roundi(a3i[1]), roundi(a3i[2]))
		TYPE_VECTOR4:
			var a4 := _vec_components(value, 4, current)
			return Vector4(a4[0], a4[1], a4[2], a4[3])
		TYPE_COLOR:
			return ToolUtils.parse_color_arg(value, current if current is Color else Color.WHITE)
		_:
			# Best-effort for everything else (rects, quats, arrays, dicts):
			# let Godot convert, falling back to the raw value.
			var converted = type_convert(value, prop_type)
			return converted if converted != null else value


# For an enum-hinted int property, resolve a string label ("PROCESS_MODE_ALWAYS")
# or a label from the hint_string ("Disabled:0,Inherit:1,...") to its int value.
# Returns the sentinel -0x7FFFFFFF when no enum resolution applies, so the caller
# falls through to plain int parsing.
func _resolve_enum(value, prop_info: Dictionary) -> int:
	if not (value is String):
		return -0x7FFFFFFF
	if int(prop_info.get("hint", 0)) != PROPERTY_HINT_ENUM:
		return -0x7FFFFFFF
	var label: String = String(value).strip_edges()
	if label.is_valid_int():
		return -0x7FFFFFFF  # numeric string — let parse_int_arg handle it
	var hint_string: String = String(prop_info.get("hint_string", ""))
	var implicit: int = 0
	for entry in hint_string.split(",", false):
		var name_part: String = entry
		var val_part: int = implicit
		var colon: int = entry.rfind(":")
		if colon != -1:
			name_part = entry.substr(0, colon)
			var maybe := entry.substr(colon + 1).strip_edges()
			if maybe.is_valid_int():
				val_part = int(maybe)
		if name_part.strip_edges().to_lower() == label.to_lower():
			return val_part
		implicit = val_part + 1
	return -0x7FFFFFFF


# Extracts `dim` float components for a vector-typed property from the raw
# value, defaulting any unspecified component to the current value's. Accepts
# "x,y[,z[,w]]" strings, [x,y,...] arrays, {x,y,...} dicts, or a bare number
# (sets the first component only). Unlike ToolUtils.parse_vector3_arg this is
# not pinned to exactly 3 components, so Vector2 / Vector4 properties work and
# partial updates ("5" onto a Vector2 keeps y) are honoured.
func _vec_components(value, dim: int, current) -> Array:
	var out: Array = _vec_from(current).slice(0, dim)
	var parsed: Array = []
	if value is String:
		for part in String(value).split(",", false):
			var s: String = part.strip_edges()
			if s.is_valid_float():
				parsed.append(float(s))
	elif value is Array:
		for x in value:
			parsed.append(ToolUtils._num(x))
	elif value is Dictionary:
		var keys: Array = ["x", "y", "z", "w"]
		for i in dim:
			if value.has(keys[i]):
				out[i] = float(value[keys[i]])
		return out
	elif value is float or value is int:
		parsed.append(float(value))
	for i in range(min(dim, parsed.size())):
		out[i] = parsed[i]
	return out


# Current vector value flattened to [x, y, z, w] floats (zero-padded), so a
# partial update can preserve the components the caller didn't supply.
func _vec_from(current) -> Array:
	if current is Vector2 or current is Vector2i:
		return [float(current.x), float(current.y), 0.0, 0.0]
	if current is Vector3 or current is Vector3i:
		return [float(current.x), float(current.y), float(current.z), 0.0]
	if current is Vector4:
		return [current.x, current.y, current.z, current.w]
	return [0.0, 0.0, 0.0, 0.0]


# Renders a stored value into a JSON-safe form (the response is serialized to
# the wire — raw Vector/Color objects can't cross it).
static func _serialize(v):
	if v is bool or v is int or v is float or v is String:
		return v
	if v is Vector2 or v is Vector2i:
		return "%s,%s" % [v.x, v.y]
	if v is Vector3 or v is Vector3i:
		return "%s,%s,%s" % [v.x, v.y, v.z]
	if v is Color:
		return "#" + v.to_html(true)
	if v == null:
		return null
	return str(v)
