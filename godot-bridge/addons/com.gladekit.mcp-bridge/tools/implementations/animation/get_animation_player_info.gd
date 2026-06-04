extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Read-only inspection of an AnimationPlayer's state — which libraries +
# animations are registered, current playback state, and the player's
# top-level properties (autoplay, speed, default_blend_time, root_node).
#
# For per-animation details (length, loop_mode, tracks, key counts) the
# agent should load the Animation .tres directly — those values are stored
# on the resource, not on the player.
#
# Args:
#   player_path: String (required) — scene-relative NodePath of an
#                                    AnimationPlayer node.
#
# Response payload:
#   player_path, libraries (dict library_name → [animation_names]),
#   library_count, total_animations, current_animation, autoplay,
#   is_playing, speed_scale, root_node, playback_default_blend_time.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "get_animation_player_info"
	# Read-only — safe in play mode as well.
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var missing := ToolUtils.require_string(args, "player_path")
	if not missing.is_empty():
		return ToolUtils.error(missing)

	var player_path: String = ToolUtils.parse_string_arg(args, "player_path")
	var node: Node = ToolUtils.find_node_by_path(player_path)
	if node == null:
		return ToolUtils.error("Node '%s' not found in the edited scene" % player_path)
	if not (node is AnimationPlayer):
		return ToolUtils.error("Node '%s' is %s, not AnimationPlayer" % [player_path, node.get_class()])
	var player: AnimationPlayer = node

	var libraries: Dictionary = {}
	var total := 0
	for lib_name in player.get_animation_library_list():
		var lib: AnimationLibrary = player.get_animation_library(lib_name)
		var anim_names: Array = []
		if lib != null:
			# AnimationLibrary.get_animation_list returns StringNames; stringify
			# for JSON round-trip.
			for n in lib.get_animation_list():
				anim_names.append(String(n))
			total += anim_names.size()
		libraries[String(lib_name)] = anim_names

	return ToolUtils.success(
		"AnimationPlayer '%s' has %d animation%s across %d librar%s" % [
			player_path,
			total, "" if total == 1 else "s",
			libraries.size(), "y" if libraries.size() == 1 else "ies",
		],
		{
			"player_path": player_path,
			"libraries": libraries,
			"library_count": libraries.size(),
			"total_animations": total,
			"current_animation": player.current_animation,
			"autoplay": player.autoplay,
			"is_playing": player.is_playing(),
			"speed_scale": player.speed_scale,
			"root_node": String(player.root_node),
			"playback_default_blend_time": player.playback_default_blend_time,
		}
	)
