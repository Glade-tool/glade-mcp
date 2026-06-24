extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an AnimationTree rooted in an AnimationNodeBlendSpace2D — the standard
# way to drive DIRECTIONAL sprite animation from a single 2D vector. Where a
# state machine (create_animation_tree) is the right tool for distinct states
# wired by transitions (idle → walk → jump), a blend space is the right tool
# when one logical action ("walk") has a different clip per FACING and you want
# the engine to pick/blend between them based on movement direction. Set
# parameters/blend_position to the character's normalized velocity each frame
# and the blend space plays the matching directional clip.
#
# Each blend POINT is an AnimationNodeAnimation placed at a 2D position; the
# canonical 4-direction layout (matching Godot 2D screen-space velocity, where
# +y is DOWN) is:
#       up    → ( 0,-1)
#       down  → ( 0, 1)
#       left  → (-1, 0)
#       right → ( 1, 0)
# so an agent can feed velocity.normalized() straight into blend_position with
# no axis flipping. The default min/max space is (-1,-1)..(1,1), auto-expanded
# if any supplied point falls outside it.
#
# The tree is bound to an existing AnimationPlayer (player_path) whose
# registered clips supply each point's animation — create + populate the player
# FIRST (create_node type=AnimationPlayer, then add_animation_to_player per
# clip). A point whose clip isn't registered is still created, but the response
# flags it under animation_warnings so the agent can register it.
#
# Points can be supplied explicitly via `points` (the precise path), or omitted
# to AUTO-SEED: the player's clips are scanned for directional names (a clip
# containing "up"/"down"/"left"/"right" as a word) and each match is placed at
# its cardinal position. Auto-seed is the one-call "wrap my 4 directional walk
# clips in a blend space" setup; pass `points` when names don't follow the
# convention or you want non-cardinal placement.
#
# Workflow:
#   1. create_node(type="AnimationPlayer", parent_path="Player")
#   2. add_animation_to_player(...) for walk_up / walk_down / walk_left / walk_right
#   3. create_blend_space_2d(player_path="Player/AnimationPlayer")  ← here (auto-seeds)
#   4. drive it: $AnimationTree.set("parameters/blend_position", velocity.normalized())
#
# Args:
#   player_path: String (required) — scene-relative NodePath of the
#                                    AnimationPlayer supplying the clips.
#   points:      Array  — explicit blend points: [{ "anim": "walk_up",
#                         "pos": "0,-1" }, ...]. Omit to auto-seed from
#                         directional clip names.
#   name:        String — node name. Default "AnimationTree".
#   parent_path: String — scene-relative parent. Default: scene root.
#   active:      bool   — process the tree at runtime. Default true.
#   blend_mode:  String — "interpolated" (default, smooth cross-blend),
#                        "discrete" (snap to nearest), "discrete_carry"
#                        (snap but carry playback position across points).
#   sync:        bool   — keep all points playing in sync (advances every
#                        point's time even when not selected). Default false.
#
# Response payload:
#   node_path, type ("AnimationTree"), root_type ("AnimationNodeBlendSpace2D"),
#   player_path (resolved, relative to the tree), active, blend_position_param
#   ("parameters/blend_position"), points (created [{anim, pos}]), min_space,
#   max_space, blend_mode, seeded (bool — true when auto-seeded), and
#   animation_warnings (clips referenced but not registered on the player).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Cardinal placement for auto-seeded directional clips. +y is DOWN to match
# Godot 2D screen-space velocity (so velocity.normalized() feeds in directly).
const _CARDINALS := {
	"up": Vector2(0, -1),
	"down": Vector2(0, 1),
	"left": Vector2(-1, 0),
	"right": Vector2(1, 0),
}

const _BLEND_MODES := {
	"interpolated": AnimationNodeBlendSpace2D.BLEND_MODE_INTERPOLATED,
	"discrete": AnimationNodeBlendSpace2D.BLEND_MODE_DISCRETE,
	"discrete_carry": AnimationNodeBlendSpace2D.BLEND_MODE_DISCRETE_CARRY,
}


func _init() -> void:
	tool_name = "create_blend_space_2d"
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
	var play_names: Array = _player_play_names(player)

	# Blend mode validation (explicit value that isn't recognized is an error).
	var blend_mode_key: String = ToolUtils.parse_string_arg(args, "blend_mode", "interpolated").strip_edges().to_lower()
	if not _BLEND_MODES.has(blend_mode_key):
		return ToolUtils.error_with_solutions(
			"Unknown blend_mode '%s'" % blend_mode_key,
			["Use one of: interpolated, discrete, discrete_carry"]
		)

	# Resolve the blend points: explicit `points` arg, else auto-seed from the
	# player's directional clip names.
	var seeded := false
	var points: Array = _parse_points(args.get("points"))
	if points.is_empty():
		points = _auto_seed_points(play_names)
		seeded = true
		if points.is_empty():
			return ToolUtils.error_with_solutions(
				"No blend points given and no directional clips (up/down/left/right) found on '%s'" % player_path,
				[
					"Pass points explicitly: points=[{\"anim\":\"walk_up\",\"pos\":\"0,-1\"}, ...]",
					"Or register directional clips (e.g. walk_up, walk_down) via add_animation_to_player first",
				]
			)

	var blend_space := AnimationNodeBlendSpace2D.new()
	blend_space.blend_mode = _BLEND_MODES[blend_mode_key]
	blend_space.sync = ToolUtils.parse_bool_arg(args, "sync", false)

	# Grow the default (-1,-1)..(1,1) bounds to enclose every supplied point so a
	# point outside the unit square is still reachable by blend_position.
	var min_space := Vector2(-1, -1)
	var max_space := Vector2(1, 1)
	for p in points:
		var pos: Vector2 = p["pos"]
		min_space.x = min(min_space.x, pos.x)
		min_space.y = min(min_space.y, pos.y)
		max_space.x = max(max_space.x, pos.x)
		max_space.y = max(max_space.y, pos.y)
	blend_space.min_space = min_space
	blend_space.max_space = max_space

	var created_points: Array = []
	var animation_warnings: Array = []
	for p in points:
		var anim_name: String = p["anim"]
		var pos: Vector2 = p["pos"]
		var node := AnimationNodeAnimation.new()
		node.animation = StringName(anim_name)
		blend_space.add_blend_point(node, pos)
		created_points.append({"anim": anim_name, "pos": ToolUtils.serialize_vector2(pos)})
		if not play_names.has(anim_name):
			animation_warnings.append(anim_name)

	var tree := AnimationTree.new()
	tree.tree_root = blend_space
	tree.name = ToolUtils.parse_string_arg(args, "name", "AnimationTree")

	parent.add_child(tree)
	tree.owner = root

	# anim_player is a NodePath relative to the AnimationTree, so compute it only
	# after the tree is in the scene and has a stable path.
	var rel_player_path: NodePath = tree.get_path_to(player)
	tree.anim_player = rel_player_path
	tree.active = ToolUtils.parse_bool_arg(args, "active", true)

	var warn_suffix := ""
	if not animation_warnings.is_empty():
		warn_suffix = " (%d clip%s not yet registered on the player — register via add_animation_to_player)" % [
			animation_warnings.size(), "" if animation_warnings.size() == 1 else "s",
		]

	return ToolUtils.success(
		"Created AnimationTree '%s' with a 2D blend space (%d point%s) bound to '%s'%s — save the scene to persist" % [
			tree.name, created_points.size(), "" if created_points.size() == 1 else "s", player_path, warn_suffix,
		],
		{
			"node_path": ToolUtils.node_relative_path(tree),
			"type": "AnimationTree",
			"root_type": "AnimationNodeBlendSpace2D",
			"player_path": String(rel_player_path),
			"active": tree.active,
			"blend_position_param": "parameters/blend_position",
			"points": created_points,
			"min_space": ToolUtils.serialize_vector2(min_space),
			"max_space": ToolUtils.serialize_vector2(max_space),
			"blend_mode": blend_mode_key,
			"seeded": seeded,
			"animation_warnings": animation_warnings,
		}
	)


# Parse the explicit `points` arg into [{ "anim": String, "pos": Vector2 }].
# Tolerates the loose JSON wire shape: each entry is a Dictionary with an
# "anim" (or "animation") clip name and a "pos" (Vector2 in any of the shapes
# parse_vector2_arg accepts). Entries missing a clip name are skipped.
func _parse_points(raw) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for entry in raw:
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		var anim: String = str(d.get("anim", d.get("animation", ""))).strip_edges()
		if anim.is_empty():
			continue
		var pos: Vector2 = ToolUtils.parse_vector2_arg(d, "pos", Vector2.ZERO)
		out.append({"anim": anim, "pos": pos})
	return out


# Auto-seed directional blend points by scanning the player's clips for ones
# whose name contains a cardinal direction as a word-ish token (so "walk_up"
# and "idle-down" match but "supply" does not). The first clip matching each
# direction wins; directions with no match are simply absent.
func _auto_seed_points(play_names: Array) -> Array:
	var picked: Dictionary = {}
	for direction in _CARDINALS:
		for name in play_names:
			if _name_has_direction(String(name), direction):
				picked[direction] = String(name)
				break
	var out: Array = []
	for direction in _CARDINALS:
		if picked.has(direction):
			out.append({"anim": picked[direction], "pos": _CARDINALS[direction]})
	return out


# True when `direction` ("up"/"down"/...) appears in `clip_name` bounded by a
# non-alphanumeric edge (start/end or a separator like "_"/"-"/"/"), so "walk_up"
# matches "up" but "supply" and "download" do not falsely match "up"/"down".
func _name_has_direction(clip_name: String, direction: String) -> bool:
	var lower := clip_name.to_lower()
	var from := 0
	while true:
		var idx := lower.find(direction, from)
		if idx == -1:
			return false
		var before_ok := idx == 0 or not _is_alnum(lower[idx - 1])
		var after_idx := idx + direction.length()
		var after_ok := after_idx >= lower.length() or not _is_alnum(lower[after_idx])
		if before_ok and after_ok:
			return true
		from = idx + 1
	return false


func _is_alnum(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "0" and c <= "9")


# Flatten an AnimationPlayer's libraries into the play-names a blend point
# references: default library "" yields bare "anim"; a named library "lib"
# yields "lib/anim". Mirrors AnimationPlayer.play() name resolution.
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
