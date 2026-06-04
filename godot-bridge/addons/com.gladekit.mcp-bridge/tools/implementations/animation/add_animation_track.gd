extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a track to an Animation resource. Each track binds to a specific
# node + property combination; keyframes are added separately via
# add_animation_keyframe(track_index=...).
#
# Track types and their NodePath conventions:
#   "value"       — animates any node property. node_path "Player",
#                   property "position" → animation path "Player:position".
#                   Use for things position_3d/rotation_3d/scale_3d don't
#                   cover (modulate, custom shader params, exported floats).
#   "position_3d" — Node3D position. node_path "Player" alone (no property).
#                   More efficient than a value track for transform animation.
#   "rotation_3d" — Node3D rotation (Quaternion).
#   "scale_3d"    — Node3D scale.
#   "method"      — calls a method on the node at each keyframe. Each key
#                   carries {method, args} via add_animation_keyframe.
#
# The animation path the AnimationPlayer uses to resolve the target node is
# relative to the player's root_node (default "..", i.e. the player's
# parent). When animating a sibling (the player is a child of Player and
# you want to animate Player), node_path is "." — get_animation_player_info
# returns root_node for inspection.
#
# Args:
#   animation_path: String (required) — res:// path to .tres Animation file
#   track_type:     String (required) — one of "value", "position_3d",
#                                       "rotation_3d", "scale_3d", "method"
#   node_path:      String (required) — node path relative to the player's
#                                       root_node (use "." to target the
#                                       parent default)
#   property:       String            — property name for "value" tracks
#                                       (required; ignored for other types).
#                                       Supports nested paths like
#                                       "modulate:a" for color alpha.
#
# Response payload:
#   animation_path, track_index, track_type, track_path, track_count.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const TRACK_TYPES := {
	"value": Animation.TYPE_VALUE,
	"position_3d": Animation.TYPE_POSITION_3D,
	"rotation_3d": Animation.TYPE_ROTATION_3D,
	"scale_3d": Animation.TYPE_SCALE_3D,
	"method": Animation.TYPE_METHOD,
}


func _init() -> void:
	tool_name = "add_animation_track"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	for required in ["animation_path", "track_type", "node_path"]:
		var missing := ToolUtils.require_string(args, required)
		if not missing.is_empty():
			return ToolUtils.error(missing)

	var animation_path: String = ToolUtils.parse_path_arg(args, "animation_path")
	var track_type: String = ToolUtils.parse_string_arg(args, "track_type").to_lower().strip_edges()
	var node_path: String = ToolUtils.parse_string_arg(args, "node_path")
	var property: String = ToolUtils.parse_string_arg(args, "property", "")

	if not TRACK_TYPES.has(track_type):
		return ToolUtils.error_with_solutions(
			"Unknown track_type '%s'" % track_type,
			["Pick one of: %s" % ", ".join(TRACK_TYPES.keys())]
		)

	if track_type == "value" and property.is_empty():
		return ToolUtils.error_with_solutions(
			"track_type 'value' requires a 'property' arg",
			[
				"For position animation use track_type='position_3d' (no property needed)",
				"For modulate use property='modulate' or 'modulate:a' for alpha only",
				"For a script-exported property pass the property name as it appears in the inspector",
			]
		)

	if not FileAccess.file_exists(animation_path):
		return ToolUtils.error("Animation file not found at '%s'" % animation_path)
	var anim_res = ResourceLoader.load(animation_path)
	if anim_res == null:
		return ToolUtils.error("Failed to load resource at '%s'" % animation_path)
	if not (anim_res is Animation):
		return ToolUtils.error("Resource at '%s' is not an Animation" % animation_path)
	var animation: Animation = anim_res

	var track_index := animation.add_track(TRACK_TYPES[track_type])

	# Value tracks address `node_path:property`; transform tracks address just
	# the node. Method tracks address the node and pull method name from keys.
	var track_path := node_path
	if track_type == "value":
		track_path = "%s:%s" % [node_path, property]
	animation.track_set_path(track_index, NodePath(track_path))

	var save_err := ResourceSaver.save(animation, animation_path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [animation_path, save_err])

	return ToolUtils.success(
		"Added %s track [%d] at '%s' on Animation '%s'" % [track_type, track_index, track_path, animation_path],
		{
			"animation_path": animation_path,
			"track_index": track_index,
			"track_type": track_type,
			"track_path": track_path,
			"track_count": animation.get_track_count(),
		}
	)
