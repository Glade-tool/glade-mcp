extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Sets top-level properties on an Animation resource — length, loop_mode,
# and step. All args are optional but at least one must be present (an
# empty call is refused noisily to avoid the silent-no-op pattern that
# bit set_node_transform pre-0.5.8).
#
# Args:
#   animation_path: String (required) — .tres Animation resource.
#   length:        float   — total length in seconds. If keys exist past
#                            this length they're preserved on disk but
#                            playback clips to length. Must be >= 0.
#   loop_mode:     String  — "none" (default; stops at end), "linear"
#                            (loops start→end→start), "ping_pong" (forward
#                            then reverse). Also accepts 0/1/2 ints.
#   step:          float   — editor key-snap quantization (display only,
#                            does not affect playback). Default 1/30s.
#                            Must be > 0.
#
# Response payload:
#   animation_path, applied (dict of {property: new_value} for the
#   properties that were actually changed).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const LOOP_MODES := {
	"none": 0,
	"linear": 1,
	"ping_pong": 2,
	"pingpong": 2,  # tolerate the no-underscore spelling
}


func _init() -> void:
	tool_name = "set_animation_properties"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var path_err := ToolUtils.require_string(args, "animation_path")
	if not path_err.is_empty():
		return ToolUtils.error(path_err)

	# Empty call → noisy refusal, matching set_node_transform's 0.5.8 fix.
	if not (args.has("length") or args.has("loop_mode") or args.has("step")):
		return ToolUtils.error_with_solutions(
			"set_animation_properties needs at least one of length, loop_mode, or step",
			[
				"Pass length as a float (animation duration in seconds)",
				"Pass loop_mode as 'none' | 'linear' | 'ping_pong'",
				"Pass step as a float (editor key-snap quantization)",
				"To inspect current values, load the .tres directly via find_assets",
			]
		)

	var animation_path: String = ToolUtils.parse_path_arg(args, "animation_path")
	if not FileAccess.file_exists(animation_path):
		return ToolUtils.error("Animation file not found at '%s'" % animation_path)
	var anim_res = ResourceLoader.load(animation_path)
	if not (anim_res is Animation):
		return ToolUtils.error("Resource at '%s' is not an Animation" % animation_path)
	var animation: Animation = anim_res

	var applied: Dictionary = {}

	if args.has("length"):
		var new_length: float = ToolUtils.parse_float_arg(args, "length")
		if new_length < 0:
			return ToolUtils.error("length must be >= 0 (got %f)" % new_length)
		animation.length = new_length
		applied["length"] = new_length

	if args.has("loop_mode"):
		var raw = args["loop_mode"]
		var mode_int := -1
		if raw is int:
			mode_int = raw
		elif raw is float:
			mode_int = int(raw)
		elif raw is String:
			var key: String = (raw as String).strip_edges().to_lower()
			if LOOP_MODES.has(key):
				mode_int = LOOP_MODES[key]
		if mode_int < 0 or mode_int > 2:
			return ToolUtils.error_with_solutions(
				"Invalid loop_mode '%s'" % raw,
				["Pick one of: none, linear, ping_pong (or 0, 1, 2)"]
			)
		animation.loop_mode = mode_int
		applied["loop_mode"] = mode_int

	if args.has("step"):
		var new_step: float = ToolUtils.parse_float_arg(args, "step")
		if new_step <= 0:
			return ToolUtils.error("step must be > 0 (got %f)" % new_step)
		animation.step = new_step
		applied["step"] = new_step

	var save_err := ResourceSaver.save(animation, animation_path)
	if save_err != OK:
		return ToolUtils.error("ResourceSaver.save failed for '%s' (err %d)" % [animation_path, save_err])

	return ToolUtils.success(
		"Updated %d propert%s on '%s'" % [applied.size(), "y" if applied.size() == 1 else "ies", animation_path],
		{
			"animation_path": animation_path,
			"applied": applied,
		}
	)
