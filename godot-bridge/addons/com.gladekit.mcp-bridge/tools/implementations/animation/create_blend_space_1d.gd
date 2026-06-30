extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an AnimationTree rooted in an AnimationNodeBlendSpace1D — the standard
# way to drive LOCOMOTION animation from a single scalar (typically speed). Where
# create_blend_space_2d blends a character's per-FACING clips from a 2D velocity,
# a 1D blend space blends along ONE axis: the canonical setup is idle → walk →
# run picked by the character's speed. Set parameters/blend_position to a single
# float each frame (e.g. velocity.length() / max_speed) and the blend space plays
# / cross-blends the matching tier.
#
# Each blend POINT is an AnimationNodeAnimation placed at a float position. The
# default range is 0..1 — the natural speed axis — auto-expanded to enclose any
# supplied point (so a symmetric strafe setup with a point at -1 grows min_space
# to -1). The auto-seed tiers land at:
#       idle / stand / still → 0.0
#       walk                 → 0.5
#       run / sprint         → 1.0
#
# The tree is bound to an existing AnimationPlayer (player_path) whose registered
# clips supply each point's animation — create + populate the player FIRST
# (create_node type=AnimationPlayer, then add_animation_to_player per clip). A
# point whose clip isn't registered is still created, but the response flags it
# under animation_warnings so the agent can register it.
#
# Points can be supplied explicitly via `points` (precise placement), or omitted
# to AUTO-SEED: the player's clips are scanned for locomotion-tier names (a clip
# containing "idle"/"walk"/"run" etc. as a word) and each match is placed at its
# tier position. Auto-seed is the one-call "wrap my idle/walk/run clips in a
# speed blend space" setup; pass `points` when names don't follow the convention
# or you want non-default placement.
#
# Workflow:
#   1. create_node(type="AnimationPlayer", parent_path="Player")
#   2. add_animation_to_player(...) for idle / walk / run
#   3. create_blend_space_1d(player_path="Player/AnimationPlayer")  ← here (auto-seeds)
#   4. drive it: $AnimationTree.set("parameters/blend_position", velocity.length() / SPEED)
#
# Args:
#   player_path: String (required) — scene-relative NodePath of the
#                                    AnimationPlayer supplying the clips.
#   points:      Array  — explicit blend points: [{ "anim": "walk",
#                         "pos": 0.5 }, ...]. Omit to auto-seed from
#                         locomotion-tier clip names.
#   name:        String — node name. Default "AnimationTree".
#   parent_path: String — scene-relative parent. Default: scene root.
#   active:      bool   — process the tree at runtime. Default true.
#   blend_mode:  String — "interpolated" (default, smooth cross-blend),
#                        "discrete" (snap to nearest), "discrete_carry"
#                        (snap but carry playback position across points).
#   sync:        bool   — keep all points playing in sync (advances every
#                        point's time even when not selected). Default false.
#   value_label: String — editor axis label for the blend value. Default "speed".
#
# Response payload:
#   node_path, type ("AnimationTree"), root_type ("AnimationNodeBlendSpace1D"),
#   player_path (resolved, relative to the tree), active, blend_position_param
#   ("parameters/blend_position"), points (created [{anim, pos}]), min_space,
#   max_space (floats), blend_mode, value_label, seeded (bool — true when
#   auto-seeded), and animation_warnings (clips referenced but not registered).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Auto-seed locomotion tiers, ordered by increasing speed. Each tier matches the
# first clip whose name contains one of `keys` as a word-bounded token.
const _TIERS := [
	{"keys": ["idle", "stand", "still"], "pos": 0.0},
	{"keys": ["walk"], "pos": 0.5},
	{"keys": ["run", "sprint"], "pos": 1.0},
]

const _BLEND_MODES := {
	"interpolated": AnimationNodeBlendSpace1D.BLEND_MODE_INTERPOLATED,
	"discrete": AnimationNodeBlendSpace1D.BLEND_MODE_DISCRETE,
	"discrete_carry": AnimationNodeBlendSpace1D.BLEND_MODE_DISCRETE_CARRY,
}


func _init() -> void:
	tool_name = "create_blend_space_1d"
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
	# player's locomotion-tier clip names.
	var seeded := false
	var points: Array = _parse_points(args.get("points"))
	if points.is_empty():
		points = _auto_seed_points(play_names)
		seeded = true
		if points.is_empty():
			return ToolUtils.error_with_solutions(
				"No blend points given and no locomotion clips (idle/walk/run) found on '%s'" % player_path,
				[
					"Pass points explicitly: points=[{\"anim\":\"walk\",\"pos\":0.5}, ...]",
					"Or register locomotion clips (e.g. idle, walk, run) via add_animation_to_player first",
				]
			)

	var blend_space := AnimationNodeBlendSpace1D.new()
	blend_space.blend_mode = _BLEND_MODES[blend_mode_key]
	blend_space.sync = ToolUtils.parse_bool_arg(args, "sync", false)
	blend_space.value_label = ToolUtils.parse_string_arg(args, "value_label", "speed")

	# Grow the default 0..1 (speed-axis) bounds to enclose every supplied point so
	# a point outside that range is still reachable by blend_position.
	var min_space := 0.0
	var max_space := 1.0
	for p in points:
		var pos: float = p["pos"]
		min_space = min(min_space, pos)
		max_space = max(max_space, pos)
	blend_space.min_space = min_space
	blend_space.max_space = max_space

	var created_points: Array = []
	var animation_warnings: Array = []
	for p in points:
		var anim_name: String = p["anim"]
		var pos: float = p["pos"]
		var node := AnimationNodeAnimation.new()
		node.animation = StringName(anim_name)
		blend_space.add_blend_point(node, pos)
		created_points.append({"anim": anim_name, "pos": pos})
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
		"Created AnimationTree '%s' with a 1D blend space (%d point%s) bound to '%s'%s — save the scene to persist" % [
			tree.name, created_points.size(), "" if created_points.size() == 1 else "s", player_path, warn_suffix,
		],
		{
			"node_path": ToolUtils.node_relative_path(tree),
			"type": "AnimationTree",
			"root_type": "AnimationNodeBlendSpace1D",
			"player_path": String(rel_player_path),
			"active": tree.active,
			"blend_position_param": "parameters/blend_position",
			"points": created_points,
			"min_space": min_space,
			"max_space": max_space,
			"blend_mode": blend_mode_key,
			"value_label": blend_space.value_label,
			"seeded": seeded,
			"animation_warnings": animation_warnings,
		}
	)


# Parse the explicit `points` arg into [{ "anim": String, "pos": float }].
# Tolerates the loose JSON wire shape: each entry is a Dictionary with an
# "anim" (or "animation") clip name and a "pos" (float as number or string).
# Entries missing a clip name are skipped.
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
		var pos: float = ToolUtils.parse_float_arg(d, "pos", 0.0)
		out.append({"anim": anim, "pos": pos})
	return out


# Auto-seed locomotion blend points by scanning the player's clips for ones whose
# name contains a tier keyword as a word-ish token (so "walk_loop" and "run-fwd"
# match but "drunk" does not falsely match "run"). The first clip matching each
# tier wins; tiers with no match are simply absent. Output is ordered by tier.
func _auto_seed_points(play_names: Array) -> Array:
	var out: Array = []
	for tier in _TIERS:
		for name in play_names:
			if _name_has_any_keyword(String(name), tier["keys"]):
				out.append({"anim": String(name), "pos": float(tier["pos"])})
				break
	return out


# True when any keyword in `keys` appears in `clip_name` bounded by a
# non-alphanumeric edge (start/end or a separator like "_"/"-"/"/"), so "walk_loop"
# matches "walk" but "drunk" does not falsely match "run".
func _name_has_any_keyword(clip_name: String, keys: Array) -> bool:
	var lower := clip_name.to_lower()
	for key in keys:
		var k: String = String(key)
		var from := 0
		while true:
			var idx := lower.find(k, from)
			if idx == -1:
				break
			var before_ok := idx == 0 or not _is_alnum(lower[idx - 1])
			var after_idx := idx + k.length()
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
