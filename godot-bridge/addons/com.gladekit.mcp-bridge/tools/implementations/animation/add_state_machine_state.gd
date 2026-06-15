extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds one state to an AnimationTree's state machine. A state is an
# AnimationNodeAnimation that plays a single clip registered in the tree's
# bound AnimationPlayer; transitions between states are added separately via
# add_state_machine_transition.
#
# Use this to extend a machine created with seed_states=false, or to add a
# clip that was registered on the player after the tree was built. The new
# state is NOT reachable until a transition points at it — follow this with
# add_state_machine_transition (often from "Start" or from an existing state).
#
# The `animation` must be a play-name the bound AnimationPlayer knows (default
# library: "jump"; named library: "combat/jump"). If the clip isn't registered
# yet, the state is still created but `animation_warning` flags it — register
# the clip via add_animation_to_player so the state has something to play.
#
# Args:
#   tree_path:  String (required) — scene-relative NodePath of the AnimationTree.
#   state_name: String (required) — name of the new state node in the machine.
#   animation:  String — play-name of the clip this state runs. Default:
#                        state_name (the common state-name == clip-name case).
#   position:   "x,y" — graph editor position. Default: auto (right of the
#                       existing states).
#   play_mode:  "forward" | "backward" — clip direction. Default "forward".
#
# Response payload:
#   tree_path, state_name, animation, play_mode, position, state_count,
#   animation_warning (only when the clip isn't registered on the player).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SMUtils = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/state_machine_utils.gd")

const PLAY_MODES := {
	"forward": AnimationNodeAnimation.PLAY_MODE_FORWARD,
	"backward": AnimationNodeAnimation.PLAY_MODE_BACKWARD,
}


func _init() -> void:
	tool_name = "add_state_machine_state"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	for required in ["tree_path", "state_name"]:
		var missing := ToolUtils.require_string(args, required)
		if not missing.is_empty():
			return ToolUtils.error(missing)

	var tree_path: String = ToolUtils.parse_string_arg(args, "tree_path")
	var resolved := SMUtils.resolve_state_machine(tree_path)
	if resolved.has("error"):
		return resolved["error"]
	var tree: AnimationTree = resolved["tree"]
	var sm: AnimationNodeStateMachine = resolved["state_machine"]

	var state_name: String = ToolUtils.parse_string_arg(args, "state_name")
	if SMUtils.is_reserved_state(state_name):
		return ToolUtils.error_with_solutions(
			"'%s' is a reserved state name" % state_name,
			["'Start' and 'End' are built into every state machine — pick another name"]
		)
	if sm.has_node(StringName(state_name)):
		return ToolUtils.error_with_solutions(
			"State '%s' already exists in the state machine" % state_name,
			["Pick a different state_name", "Or wire it with add_state_machine_transition"]
		)

	var play_mode_arg: String = ToolUtils.parse_string_arg(args, "play_mode", "forward").to_lower().strip_edges()
	if not PLAY_MODES.has(play_mode_arg):
		return ToolUtils.error_with_solutions(
			"Unknown play_mode '%s'" % play_mode_arg,
			["Use 'forward' or 'backward'"]
		)

	var animation: String = ToolUtils.parse_string_arg(args, "animation", state_name)

	var state := AnimationNodeAnimation.new()
	state.animation = StringName(animation)
	state.play_mode = PLAY_MODES[play_mode_arg]

	# Default graph position: one column to the right of whatever is there, so
	# states don't stack on top of each other at the origin.
	var position: Vector2
	if args.has("position"):
		position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
	else:
		position = Vector2(sm.get_node_list().size() * 250, 150)

	sm.add_node(StringName(state_name), state, position)

	var payload := {
		"tree_path": tree_path,
		"state_name": state_name,
		"animation": animation,
		"play_mode": play_mode_arg,
		"position": "%d,%d" % [int(position.x), int(position.y)],
		"state_count": sm.get_node_list().size(),
	}

	# Warn (don't fail) if the clip isn't registered yet — the agent may add it
	# to the player afterward, and a hard error would block that ordering.
	# Untyped (=) on purpose: bound_player_play_names returns Array or null, so
	# it has no single inferable type for :=.
	var play_names = SMUtils.bound_player_play_names(tree)
	if play_names != null and not (animation in play_names):
		payload["animation_warning"] = (
			"Clip '%s' is not registered on the bound AnimationPlayer (known: %s). "
			% [animation, ", ".join(play_names) if not play_names.is_empty() else "none"]
			+ "Register it via add_animation_to_player or the state will play nothing."
		)

	return ToolUtils.success(
		"Added state '%s' (plays '%s') to AnimationTree '%s' — save the scene to persist" % [
			state_name, animation, tree_path,
		],
		payload
	)
