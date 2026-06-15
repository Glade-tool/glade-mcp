extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an AnimationTree node driven by an AnimationNodeStateMachine — Godot's
# state-machine animation controller (the analog of Unity's Animator Controller).
# Where an AnimationPlayer just plays one clip by name, a state machine wires
# clips into states with transitions, so a character can blend idle → walk →
# run → jump driven by code that calls travel("run") or flips advance
# conditions. This is the entry point for any "set up a character animation
# state machine" request.
#
# The tree is bound to an existing AnimationPlayer (player_path) whose
# registered animations supply the clips each state plays. Create + populate
# the player FIRST (create_node type=AnimationPlayer, then
# add_animation_to_player for each clip); the state machine references those
# clips by their play-name.
#
# By default (seed_states=true) one AnimationNodeAnimation state is created per
# animation registered in the player, and a Start → <initial_state> transition
# is added so the machine has an entry point — a one-call "wrap my existing
# clips in a state machine" setup. Pass seed_states=false for an empty machine
# you fill with add_state_machine_state / add_state_machine_transition.
#
# Workflow:
#   1. create_node(type="AnimationPlayer", parent_path="Player")
#   2. add_animation_to_player(...) for each clip (idle / walk / run / jump)
#   3. create_animation_tree(player_path="Player/AnimationPlayer")  ← here
#   4. add_state_machine_transition(...) to wire the remaining transitions
#   5. drive it from a script: $AnimationTree.get("parameters/playback").travel("run")
#
# Args:
#   player_path:   String (required) — scene-relative NodePath of the
#                                      AnimationPlayer supplying the clips.
#   name:          String — node name. Default "AnimationTree".
#   parent_path:   String — scene-relative parent. Default: scene root.
#   active:        bool   — process the tree at runtime. Default true. (An
#                          inactive tree is inert — nothing plays.)
#   seed_states:   bool   — create one state per player animation. Default true.
#   initial_state: String — which seeded state gets the Start transition.
#                          Default: the player's first registered animation.
#
# Response payload:
#   node_path, type ("AnimationTree"), player_path (resolved, relative to the
#   tree), active, states (created state names), transitions (entry wiring),
#   seeded (bool).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_animation_tree"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	var missing := ToolUtils.require_string(args, "player_path")
	if not missing.is_empty():
		return ToolUtils.error(missing)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	# Resolve + validate the AnimationPlayer before adding anything.
	var player_path: String = ToolUtils.parse_string_arg(args, "player_path")
	var player_node: Node = ToolUtils.find_node_by_path(player_path)
	if player_node == null:
		return ToolUtils.error_with_solutions(
			"AnimationPlayer '%s' not found in the edited scene" % player_path,
			[
				"Create one first: create_node(type='AnimationPlayer', parent_path='...')",
				"Or check the path with get_scene_tree",
			]
		)
	if not (player_node is AnimationPlayer):
		return ToolUtils.error(
			"Node '%s' is %s, not AnimationPlayer" % [player_path, player_node.get_class()]
		)
	var player: AnimationPlayer = player_node

	# Flatten the player's registered animations into the play-names a state
	# references (default library "" → "anim"; named library → "lib/anim").
	var play_names: Array = _player_play_names(player)

	var state_machine := AnimationNodeStateMachine.new()
	var seed_states: bool = ToolUtils.parse_bool_arg(args, "seed_states", true)
	var created_states: Array = []
	var transitions: Array = []

	if seed_states:
		if play_names.is_empty():
			return ToolUtils.error_with_solutions(
				"seed_states is on but AnimationPlayer '%s' has no animations to seed" % player_path,
				[
					"Register clips first via add_animation_to_player",
					"Or pass seed_states=false to create an empty state machine",
				]
			)
		var col := 0
		for anim_name in play_names:
			var state := AnimationNodeAnimation.new()
			state.animation = StringName(anim_name)
			# Lay states out in a row so the editor graph isn't a pile at origin.
			state_machine.add_node(StringName(anim_name), state, Vector2(col * 250, 0))
			created_states.append(anim_name)
			col += 1

		# Wire an entry transition so the machine actually starts somewhere.
		# initial_state is optional: blank or missing means "the first clip", so a
		# seeded setup needs no animation names from the caller. Only a non-empty
		# value that doesn't match a clip is an error worth surfacing.
		var initial_state: String = ToolUtils.parse_string_arg(args, "initial_state").strip_edges()
		if initial_state.is_empty():
			initial_state = String(play_names[0])
		if not state_machine.has_node(StringName(initial_state)):
			return ToolUtils.error_with_solutions(
				"initial_state '%s' is not one of the player's animations" % initial_state,
				["Pick one of: %s" % ", ".join(play_names), "Or omit initial_state to default to the first clip"]
			)
		state_machine.add_transition(
			StringName("Start"), StringName(initial_state), AnimationNodeStateMachineTransition.new()
		)
		transitions.append({"from": "Start", "to": initial_state})

	var tree := AnimationTree.new()
	tree.tree_root = state_machine
	tree.name = ToolUtils.parse_string_arg(args, "name", "AnimationTree")

	parent.add_child(tree)
	tree.owner = root

	# anim_player is a NodePath relative to the AnimationTree, so compute it only
	# after the tree is in the scene and has a stable path.
	var rel_player_path: NodePath = tree.get_path_to(player)
	tree.anim_player = rel_player_path
	tree.active = ToolUtils.parse_bool_arg(args, "active", true)

	return ToolUtils.success(
		"Created AnimationTree '%s' (%d state%s) bound to '%s' — save the scene to persist" % [
			tree.name, created_states.size(), "" if created_states.size() == 1 else "s", player_path,
		],
		{
			"node_path": ToolUtils.node_relative_path(tree),
			"type": "AnimationTree",
			"player_path": String(rel_player_path),
			"active": tree.active,
			"states": created_states,
			"transitions": transitions,
			"seeded": seed_states,
		}
	)


# Flatten an AnimationPlayer's libraries into the play-names a state machine
# state references: default library "" yields bare "anim"; a named library
# "lib" yields "lib/anim". Mirrors AnimationPlayer.play() name resolution.
func _player_play_names(player: AnimationPlayer) -> Array:
	var names: Array = []
	for lib_name in player.get_animation_library_list():
		var lib: AnimationLibrary = player.get_animation_library(lib_name)
		if lib == null:
			continue
		for anim in lib.get_animation_list():
			var prefix := "" if String(lib_name).is_empty() else "%s/" % String(lib_name)
			names.append("%s%s" % [prefix, String(anim)])
	return names
