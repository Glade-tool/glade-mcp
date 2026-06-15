extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Read-only inspection of an AnimationTree's state machine — its bound
# AnimationPlayer, active flag, the states (with the clip each plays), and the
# transitions between them. Start here before extending a machine with
# add_state_machine_state / add_state_machine_transition: it returns the exact
# state names you pass as from_state / to_state, and surfaces clips that
# reference an animation the bound player doesn't have.
#
# Only state-machine-rooted trees are described in full; a blend-tree root
# reports its type but not states/transitions (those tools are state-machine
# only).
#
# Args:
#   tree_path: String (required) — scene-relative NodePath of an AnimationTree.
#
# Response payload:
#   tree_path, type ("AnimationTree"), root_type, active, anim_player (the
#   resolved relative path), anim_player_found (bool), states (list of
#   {name, animation, play_mode, animation_registered}), state_count,
#   transitions (list of {from, to, switch_mode, xfade_time, advance_mode,
#   advance_condition}), transition_count.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SMUtils = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/animation/state_machine_utils.gd")

const SWITCH_MODE_NAMES := {
	AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE: "immediate",
	AnimationNodeStateMachineTransition.SWITCH_MODE_SYNC: "sync",
	AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END: "at_end",
}

const ADVANCE_MODE_NAMES := {
	AnimationNodeStateMachineTransition.ADVANCE_MODE_DISABLED: "disabled",
	AnimationNodeStateMachineTransition.ADVANCE_MODE_ENABLED: "enabled",
	AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO: "auto",
}

const PLAY_MODE_NAMES := {
	AnimationNodeAnimation.PLAY_MODE_FORWARD: "forward",
	AnimationNodeAnimation.PLAY_MODE_BACKWARD: "backward",
}


func _init() -> void:
	tool_name = "get_animation_tree_info"
	# Read-only — safe in play mode as well.
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var missing := ToolUtils.require_string(args, "tree_path")
	if not missing.is_empty():
		return ToolUtils.error(missing)

	var tree_path: String = ToolUtils.parse_string_arg(args, "tree_path")
	var node: Node = ToolUtils.find_node_by_path(tree_path)
	if node == null:
		return ToolUtils.error("AnimationTree '%s' not found in the edited scene" % tree_path)
	if not (node is AnimationTree):
		return ToolUtils.error("Node '%s' is %s, not AnimationTree" % [tree_path, node.get_class()])
	var tree: AnimationTree = node

	var root := tree.tree_root
	var root_type: String = root.get_class() if root != null else "none"
	var player_path: NodePath = tree.anim_player
	var player: Node = null
	if not player_path.is_empty():
		player = tree.get_node_or_null(player_path)
	var player_found: bool = player != null and (player is AnimationPlayer)

	var payload := {
		"tree_path": tree_path,
		"type": "AnimationTree",
		"root_type": root_type,
		"active": tree.active,
		"anim_player": String(player_path),
		"anim_player_found": player_found,
		"states": [],
		"state_count": 0,
		"transitions": [],
		"transition_count": 0,
	}

	# Only a state-machine root has states/transitions to enumerate.
	if not (root is AnimationNodeStateMachine):
		return ToolUtils.success(
			"AnimationTree '%s' root is %s (not a state machine)" % [tree_path, root_type],
			payload
		)
	var sm: AnimationNodeStateMachine = root

	var play_names = SMUtils.bound_player_play_names(tree)

	var states: Array = []
	for state_name in sm.get_node_list():
		# Untyped on purpose: get_node returns the AnimationNode base, but we
		# read AnimationNodeAnimation-only properties (animation, play_mode)
		# after an `is` check — dynamic access avoids a static-type compile error.
		var sub = sm.get_node(state_name)
		var entry := {
			"name": String(state_name),
			"type": sub.get_class() if sub != null else "null",
		}
		if sub is AnimationNodeAnimation:
			var clip := String(sub.animation)
			entry["animation"] = clip
			entry["play_mode"] = PLAY_MODE_NAMES.get(sub.play_mode, "forward")
			# null play_names → couldn't resolve the player, so don't claim
			# the clip is missing.
			if play_names != null:
				entry["animation_registered"] = clip in play_names
		states.append(entry)

	var transitions: Array = []
	for i in sm.get_transition_count():
		var t := sm.get_transition(i)
		transitions.append({
			"from": String(sm.get_transition_from(i)),
			"to": String(sm.get_transition_to(i)),
			"switch_mode": SWITCH_MODE_NAMES.get(t.switch_mode, "immediate"),
			"xfade_time": t.xfade_time,
			"advance_mode": ADVANCE_MODE_NAMES.get(t.advance_mode, "enabled"),
			"advance_condition": String(t.advance_condition),
		})

	payload["states"] = states
	payload["state_count"] = states.size()
	payload["transitions"] = transitions
	payload["transition_count"] = transitions.size()

	return ToolUtils.success(
		"AnimationTree '%s': %d state%s, %d transition%s (%s)" % [
			tree_path,
			states.size(), "" if states.size() == 1 else "s",
			transitions.size(), "" if transitions.size() == 1 else "s",
			"active" if tree.active else "inactive",
		],
		payload
	)
