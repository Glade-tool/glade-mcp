extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Inserts a keyframe into an Animation track at a given time. The value's
# expected shape depends on the track's type (which this tool reads from the
# Animation resource — the agent only knows the track_index returned by
# add_animation_track):
#
#   value         pass-through (number, string, color "x,y,z", etc.).
#                 Type must match the underlying property's variant type.
#   position_3d   Vector3. Accepts "x,y,z" string, [x,y,z] array, or
#                 {"x":..,"y":..,"z":..} dict.
#   rotation_3d   Quaternion. Accepts:
#                   - "x,y,z" Euler degrees (matches set_node_transform's
#                     rotation arg — the natural form for the agent)
#                   - [x,y,z,w] Quaternion array
#                 Euler input is auto-converted to Quaternion via
#                 Quaternion.from_euler(radians).
#   scale_3d      Vector3, same parsing as position_3d.
#   method        Dictionary {"method": String, "args": Array}. The method
#                 is called on the track's target node at this time with
#                 the given args.
#
# Args:
#   animation_path: String  (required) — .tres Animation resource.
#   track_index:    int     (required) — index returned from add_animation_track.
#   time:           float   (required) — seconds from animation start.
#   value:          varies  (required) — see parsing rules above.
#   transition:     float              — easing curve power for VALUE / METHOD
#                                        tracks (default 1.0 = linear). > 1
#                                        is ease-out, between 0 and 1 is
#                                        ease-in. Ignored for transform tracks
#                                        (they always use linear blend).
#
# Response payload:
#   animation_path, track_index, key_index, time, key_count.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "add_animation_keyframe"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path_err := ToolUtils.require_string(args, "animation_path")
	if not path_err.is_empty():
		return ToolUtils.error(path_err)
	if not args.has("track_index"):
		return ToolUtils.error("track_index is required")
	if not args.has("time"):
		return ToolUtils.error("time is required")
	if not args.has("value"):
		return ToolUtils.error("value is required")

	var animation_path: String = ToolUtils.parse_path_arg(args, "animation_path")
	var track_index: int = ToolUtils.parse_int_arg(args, "track_index", -1)
	var time: float = ToolUtils.parse_float_arg(args, "time")
	var transition: float = ToolUtils.parse_float_arg(args, "transition", 1.0)

	if not FileAccess.file_exists(animation_path):
		return ToolUtils.error("Animation file not found at '%s'" % animation_path)
	var anim_res = ResourceLoader.load(animation_path)
	if not (anim_res is Animation):
		return ToolUtils.error("Resource at '%s' is not an Animation" % animation_path)
	var animation: Animation = anim_res

	if track_index < 0 or track_index >= animation.get_track_count():
		return ToolUtils.error(
			"track_index %d out of range (animation has %d track(s))" % [track_index, animation.get_track_count()]
		)
	if time < 0:
		return ToolUtils.error("time must be >= 0 (got %f)" % time)

	var track_type := animation.track_get_type(track_index)
	var key_index := -1
	match track_type:
		Animation.TYPE_POSITION_3D:
			var v_pos := ToolUtils.parse_vector3_arg(args, "value", Vector3.ZERO)
			key_index = animation.position_track_insert_key(track_index, time, v_pos)
		Animation.TYPE_SCALE_3D:
			var v_scale := ToolUtils.parse_vector3_arg(args, "value", Vector3.ONE)
			key_index = animation.scale_track_insert_key(track_index, time, v_scale)
		Animation.TYPE_ROTATION_3D:
			var q := _parse_rotation_value(args["value"])
			key_index = animation.rotation_track_insert_key(track_index, time, q)
		Animation.TYPE_VALUE:
			key_index = animation.track_insert_key(track_index, time, args["value"], transition)
		Animation.TYPE_METHOD:
			var raw = args["value"]
			if not (raw is Dictionary):
				return ToolUtils.error_with_solutions(
					"method track value must be a Dictionary {method, args}",
					["Example: value={\"method\": \"queue_free\", \"args\": []}"]
				)
			key_index = animation.track_insert_key(track_index, time, raw, transition)
		_:
			return ToolUtils.error(
				"Track %d has unsupported type (%d). Supported: value, position_3d, rotation_3d, scale_3d, method"
				% [track_index, track_type]
			)

	var save_err := ResourceSaver.save(animation, animation_path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [animation_path, save_err])

	return ToolUtils.success(
		"Inserted key at t=%.3fs on track %d (key_index=%d)" % [time, track_index, key_index],
		{
			"animation_path": animation_path,
			"track_index": track_index,
			"key_index": key_index,
			"time": time,
			"key_count": animation.track_get_key_count(track_index),
		}
	)


# Quaternion parser tuned for agents — they think in Euler degrees because
# that's what set_node_transform / the Godot editor inspector expose. We
# accept the natural form and convert internally.
func _parse_rotation_value(v) -> Quaternion:
	if v is Quaternion:
		return v
	if v is Array and (v as Array).size() == 4:
		var arr: Array = v
		return Quaternion(_f(arr[0]), _f(arr[1]), _f(arr[2]), _f(arr[3]))
	# Treat as Euler degrees. parse_vector3_arg's API is keyed on a Dictionary,
	# so we wrap the raw value in a one-off dict before delegating.
	var euler_deg := ToolUtils.parse_vector3_arg({"r": v}, "r", Vector3.ZERO)
	var euler_rad := Vector3(deg_to_rad(euler_deg.x), deg_to_rad(euler_deg.y), deg_to_rad(euler_deg.z))
	return Quaternion.from_euler(euler_rad)


func _f(v) -> float:
	if v is float or v is int:
		return float(v)
	if v is String and (v as String).strip_edges().is_valid_float():
		return float(v)
	return 0.0
