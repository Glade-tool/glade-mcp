extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Read-only inspection of an AnimationTree — its bound AnimationPlayer, active
# flag, and the contents of its root node. Two root families are described in
# full:
#
#   • State machine (AnimationNodeStateMachine) — the states (with the clip
#     each plays) and the transitions between them. Start here before extending
#     a machine with add_state_machine_state / add_state_machine_transition: it
#     returns the exact state names you pass as from_state / to_state, and
#     surfaces clips that reference an animation the bound player doesn't have.
#
#   • Blend space (AnimationNodeBlendSpace1D / 2D) — the blend points (the clip
#     at each position), the min/max space bounds, blend_mode, and the
#     parameters/blend_position param you drive at runtime. The read-back twin
#     of create_blend_space_1d / create_blend_space_2d.
#
# Any other root (e.g. a freeform AnimationNodeBlendTree) reports its type but
# no contents.
#
# Args:
#   tree_path: String (required) — scene-relative NodePath of an AnimationTree.
#
# Response payload (always): tree_path, type ("AnimationTree"), root_type,
#   active, anim_player (resolved relative path), anim_player_found (bool).
#   State-machine roots add: states (list of {name, type, animation, play_mode,
#   animation_registered}), state_count, transitions (list of {from, to,
#   switch_mode, xfade_time, advance_mode, advance_condition}), transition_count.
#   Blend-space roots add: blend_points (list of {type, animation, pos,
#   animation_registered}), blend_point_count, min_space, max_space (float for
#   1D, "x,y" for 2D), blend_mode, sync, blend_position_param, and value_label
#   (1D only) or x_label/y_label (2D only).

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

# AnimationNodeBlendSpace1D and 2D share the same BLEND_MODE_* integer values
# (0/1/2), so one int-keyed map serves both.
const BLEND_SPACE_MODE_NAMES := {
	AnimationNodeBlendSpace1D.BLEND_MODE_INTERPOLATED: "interpolated",
	AnimationNodeBlendSpace1D.BLEND_MODE_DISCRETE: "discrete",
	AnimationNodeBlendSpace1D.BLEND_MODE_DISCRETE_CARRY: "discrete_carry",
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

	# Blend-space roots (1D/2D) carry blend points + bounds instead of states.
	if root is AnimationNodeBlendSpace1D or root is AnimationNodeBlendSpace2D:
		return _describe_blend_space(root, tree_path, SMUtils.bound_player_play_names(tree), payload)

	# Only a state-machine root has states/transitions to enumerate.
	if not (root is AnimationNodeStateMachine):
		return ToolUtils.success(
			"AnimationTree '%s' root is %s (not a state machine or blend space)" % [tree_path, root_type],
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


# Enumerate a 1D/2D blend space's points + bounds into the payload. `root` is
# guaranteed to be an AnimationNodeBlendSpace1D or 2D by the caller. Positions
# and bounds serialize per dimension: a 1D space reports floats, a 2D space
# reports "x,y" strings (matching create_blend_space_1d / _2d), plus the axis
# label(s). play_names is the bound player's clip list (null if unresolved) —
# used to flag points referencing an unregistered clip.
func _describe_blend_space(root, tree_path: String, play_names, payload: Dictionary) -> Dictionary:
	var is_2d := root is AnimationNodeBlendSpace2D

	var blend_points: Array = []
	for i in root.get_blend_point_count():
		var sub = root.get_blend_point_node(i)
		var raw_pos = root.get_blend_point_position(i)
		var pos = ToolUtils.serialize_vector2(raw_pos) if is_2d else raw_pos
		var entry := {
			"type": sub.get_class() if sub != null else "null",
			"pos": pos,
		}
		# Our create_blend_space_* tools place AnimationNodeAnimation at each
		# point; read the clip it references (dynamic access after the `is` check).
		if sub is AnimationNodeAnimation:
			var clip := String(sub.animation)
			entry["animation"] = clip
			if play_names != null:
				entry["animation_registered"] = clip in play_names
		blend_points.append(entry)

	payload["blend_points"] = blend_points
	payload["blend_point_count"] = blend_points.size()
	payload["blend_mode"] = BLEND_SPACE_MODE_NAMES.get(root.blend_mode, "interpolated")
	payload["sync"] = root.sync
	payload["blend_position_param"] = "parameters/blend_position"
	if is_2d:
		payload["min_space"] = ToolUtils.serialize_vector2(root.min_space)
		payload["max_space"] = ToolUtils.serialize_vector2(root.max_space)
		payload["x_label"] = root.x_label
		payload["y_label"] = root.y_label
	else:
		payload["min_space"] = root.min_space
		payload["max_space"] = root.max_space
		payload["value_label"] = root.value_label

	var dim := "2D" if is_2d else "1D"
	return ToolUtils.success(
		"AnimationTree '%s': %s blend space, %d point%s (%s)" % [
			tree_path, dim,
			blend_points.size(), "" if blend_points.size() == 1 else "s",
			"active" if payload["active"] else "inactive",
		],
		payload
	)
