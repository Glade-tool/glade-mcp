extends RefCounted

# Shared helpers for the AnimationTree state-machine tools
# (add_state_machine_state / add_state_machine_transition /
# get_animation_tree_info). create_animation_tree builds the machine inline and
# doesn't need these — these resolve + inspect an EXISTING tree.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# "Start" and "End" are implicit endpoints in every AnimationNodeStateMachine.
# They're valid transition endpoints but can't be created or removed as states.
const RESERVED_STATES := ["Start", "End"]


# Resolve a tree_path to an AnimationTree whose root is a state machine.
# Returns {tree, state_machine} on success, or {error: <error Dictionary>} so
# callers can early-return the structured error verbatim.
static func resolve_state_machine(tree_path: String) -> Dictionary:
	var node: Node = ToolUtils.find_node_by_path(tree_path)
	if node == null:
		return {"error": ToolUtils.error_with_solutions(
			"AnimationTree '%s' not found in the edited scene" % tree_path,
			["Create one with create_animation_tree", "Check the path with get_scene_tree"]
		)}
	if not (node is AnimationTree):
		return {"error": ToolUtils.error(
			"Node '%s' is %s, not AnimationTree" % [tree_path, node.get_class()]
		)}
	var tree: AnimationTree = node
	var root := tree.tree_root
	if root == null or not (root is AnimationNodeStateMachine):
		var root_type := root.get_class() if root != null else "none"
		return {"error": ToolUtils.error_with_solutions(
			"AnimationTree '%s' root is %s, not an AnimationNodeStateMachine" % [tree_path, root_type],
			[
				"create_animation_tree builds a state-machine-rooted tree",
				"These tools only operate on state-machine trees (not blend trees)",
			]
		)}
	return {"tree": tree, "state_machine": root}


static func is_reserved_state(state_name: String) -> bool:
	return state_name in RESERVED_STATES


# Flatten the bound AnimationPlayer's libraries into play-names (default
# library "" → "anim"; named library "lib" → "lib/anim"). Returns null when the
# tree's anim_player can't be resolved (so callers can skip clip validation
# rather than report a false "unknown clip"). Mirrors AnimationPlayer.play()
# name resolution and get_animation_player_info's library walk.
static func bound_player_play_names(tree: AnimationTree):
	var player_path: NodePath = tree.anim_player
	if player_path.is_empty():
		return null
	var player := tree.get_node_or_null(player_path)
	if player == null or not (player is AnimationPlayer):
		return null
	var names: Array = []
	for lib_name in (player as AnimationPlayer).get_animation_library_list():
		var lib: AnimationLibrary = (player as AnimationPlayer).get_animation_library(lib_name)
		if lib == null:
			continue
		for anim in lib.get_animation_list():
			var prefix := "" if String(lib_name).is_empty() else "%s/" % String(lib_name)
			names.append("%s%s" % [prefix, String(anim)])
	return names
