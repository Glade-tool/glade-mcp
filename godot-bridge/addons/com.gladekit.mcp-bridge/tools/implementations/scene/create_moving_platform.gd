extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Builds a MOVING PLATFORM (or sends an existing node patrolling a route) in ONE
# call, in EITHER 2D or 3D: a Path node holding the waypoint curve, a rider that
# travels it at constant speed, and a small PathMover logic-node that drives the
# rider. By default the rider is a freshly scaffolded AnimatableBody (collision +
# visible placeholder) that CARRIES a CharacterBody player; pass `target_path`
# instead to send an existing node (an enemy, a hazard) patrolling the same route.
#
# Dimension is inferred from the open scene's root (Node2D → 2D, Node3D → 3D);
# pass `space` ("2d" | "3d") to override. 2D builds Path2D + AnimatableBody2D +
# a Polygon2D placeholder; 3D builds Path3D + AnimatableBody3D + a BoxMesh
# placeholder.
#
# Why a PathMover that sets the rider's OWN global_position (rather than parenting
# the rider under a moving PathFollow node): an AnimatableBody only reports its
# platform velocity to a resting CharacterBody when its OWN transform changes —
# the same reason the engine's carrying-platform recipe animates the body's
# position directly. Moving a parent node leaves the body's own transform
# constant, so move_and_slide sees no platform velocity and the player is left
# behind (the classic "platform slides out from under the player, who floats in
# the air" bug). Driving the rider's own global_position fixes that and, as a
# bonus, never needs to own the rider's script (so a patrolling enemy keeps its
# own).
#
# Hand-rolled moving platforms are reliably buggy: a StaticBody the player slides
# off instead of riding, a _process mover physics never sees, or a home-grown
# lerp that stutters at the seams. This tool sidesteps all three: AnimatableBody
# (sync_to_physics) for the carry, a vetted mover that runs in _physics_process,
# and Godot's own baked curve for smooth interpolation. loop_mode covers the
# three real cases — "loop" (wrap around), "pingpong" (back and forth), "once"
# (travel then stop).
#
# Args:
#   space:       "2d" | "3d". Default: inferred from the open scene's root.
#   name:        Path node name. Default "MovingPlatform".
#   parent_path: scene-relative parent. Default: the scene root.
#   position:    placement of the Path node (waypoints are relative to it).
#                "x,y" in 2D, "x,y,z" in 3D. Default 0.
#   points:      the route, as waypoints relative to `position`. Accepts
#                [[x,y(,z)], ...], ["x,y(,z)", ...], or a single
#                "x,y(,z);x,y(,z)" string. The first point is the start.
#                Default: a short horizontal sweep so a bare call still moves
#                (2D: 0,0 → 200,0; 3D: 0,0,0 → 4,0,0).
#   speed:       distance per second along the curve (pixels in 2D, metres in
#                3D). Default 80 (2D) / 3 (3D).
#   loop_mode:   "loop" | "pingpong" | "once". Default "loop".
#   wait_time:   seconds to pause at each end (pingpong/once). Default 0.
#   size:        scaffolded platform body size. "w,h" in 2D (default "96,16"),
#                "w,h,d" in 3D (default "2,0.5,2"). Ignored when target_path is
#                given.
#   one_way:     2D only — make the scaffolded platform ONE-WAY (land on top,
#                jump up through from below). Default false. Ignored in 3D and
#                when target_path is given.
#   color:       placeholder fill color for the scaffolded platform.
#   target_path: scene-relative path to an EXISTING node to send along the route
#                instead of scaffolding a platform (Node2D in 2D, Node3D in 3D).
#                Its script is left intact (the PathMover drives its position).
#   directory:   res:// folder for the generated mover script.
#                Default "res://scripts".
#   overwrite:   regenerate the shared mover script if it exists. Default false.
#
# Response payload:
#   created_script, path (Path node path), mover (PathMover node path),
#   rider (the platform/target node path), space, loop_mode, point_count

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _DEFAULT_COLOR := Color(0.55, 0.58, 0.65)  # neutral platform grey
const _VALID_MODES := ["loop", "pingpong", "once"]

# ── Vetted script: PathMover (2D) ──────────────────────────────────────────
# A plain Node that drives a rider along a Path2D's curve by setting the rider's
# OWN global_position each physics frame. Moving the rider's own transform (not a
# parent's) is what lets an AnimatableBody2D platform carry a CharacterBody2D
# player — equivalent to an AnimationPlayer animating the body. Because it never
# attaches to the rider, an existing patrolling node keeps its own script.
const MOVER_SRC := """extends Node

# Drives `rider` along `path_node`'s Curve2D at a constant speed by setting the
# rider's OWN global_position in _physics_process. That own-transform motion is
# what makes an AnimatableBody2D platform carry a resting CharacterBody2D player;
# moving a parent node instead would leave the player behind.

@export var path_node: NodePath
@export var rider: NodePath
@export var speed: float = 80.0                          # pixels/sec along the curve
@export_enum(\"loop\", \"pingpong\", \"once\") var loop_mode: String = \"loop\"
@export var wait_time: float = 0.0                       # pause (s) at each end

var _progress: float = 0.0
var _dir: int = 1
var _wait: float = 0.0
var _path: Path2D
var _rider: Node2D


func _ready() -> void:
	_path = get_node_or_null(path_node) as Path2D
	_rider = get_node_or_null(rider) as Node2D


func _physics_process(delta: float) -> void:
	if _path == null or _path.curve == null or _rider == null:
		return
	var length := _path.curve.get_baked_length()
	if length <= 0.0:
		return
	if _wait > 0.0:
		_wait -= delta
		return
	_progress += speed * _dir * delta
	match loop_mode:
		\"pingpong\":
			if _progress >= length:
				_progress = length
				_dir = -1
				_wait = wait_time
			elif _progress <= 0.0:
				_progress = 0.0
				_dir = 1
				_wait = wait_time
		\"once\":
			if _progress >= length:
				_progress = length
				set_physics_process(false)
		_:  # \"loop\"
			if _progress >= length:
				_progress -= length
	_rider.global_position = _path.to_global(_path.curve.sample_baked(_progress))
"""

# ── Vetted script: PathMover3D ─────────────────────────────────────────────
# The 3D twin of PathMover. Drives a Node3D rider along a Path3D's Curve3D by
# setting the rider's OWN global_position in _physics_process — the only way an
# AnimatableBody3D reports platform velocity to a resting CharacterBody3D, so the
# player rides it in BOTH directions instead of being left floating at the far
# end of the sweep.
const MOVER3D_SRC := """extends Node

# Drives `rider` along `path_node`'s Curve3D at a constant speed by setting the
# rider's OWN global_position in _physics_process. That own-transform motion is
# what makes an AnimatableBody3D platform carry a resting CharacterBody3D player;
# moving a parent node instead would leave the player behind.

@export var path_node: NodePath
@export var rider: NodePath
@export var speed: float = 3.0                           # metres/sec along the curve
@export_enum(\"loop\", \"pingpong\", \"once\") var loop_mode: String = \"loop\"
@export var wait_time: float = 0.0                       # pause (s) at each end

var _progress: float = 0.0
var _dir: int = 1
var _wait: float = 0.0
var _path: Path3D
var _rider: Node3D


func _ready() -> void:
	_path = get_node_or_null(path_node) as Path3D
	_rider = get_node_or_null(rider) as Node3D


func _physics_process(delta: float) -> void:
	if _path == null or _path.curve == null or _rider == null:
		return
	var length := _path.curve.get_baked_length()
	if length <= 0.0:
		return
	if _wait > 0.0:
		_wait -= delta
		return
	_progress += speed * _dir * delta
	match loop_mode:
		\"pingpong\":
			if _progress >= length:
				_progress = length
				_dir = -1
				_wait = wait_time
			elif _progress <= 0.0:
				_progress = 0.0
				_dir = 1
				_wait = wait_time
		\"once\":
			if _progress >= length:
				_progress = length
				set_physics_process(false)
		_:  # \"loop\"
			if _progress >= length:
				_progress -= length
	_rider.global_position = _path.to_global(_path.curve.sample_baked(_progress))
"""


func _init() -> void:
	tool_name = "create_moving_platform"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new scene"]
		)

	# Dimension is inferred from the scene root (Node3D → 3D), or overridden by
	# an explicit `space` arg — same contract as create_physics_body.
	var space: String = ToolUtils.resolve_space(args)
	if space != "2d" and space != "3d":
		return ToolUtils.error_with_solutions(
			"Unknown space '%s'" % space,
			["Use space='3d' for a Path3D + AnimatableBody3D platform", "Use space='2d' for a Path2D + AnimatableBody2D platform"]
		)
	var is_2d: bool = space == "2d"

	var loop_mode: String = ToolUtils.parse_string_arg(args, "loop_mode", "loop").strip_edges().to_lower()
	if loop_mode.is_empty():
		loop_mode = "loop"
	if not _VALID_MODES.has(loop_mode):
		return ToolUtils.error_with_solutions(
			"Invalid loop_mode '%s'" % loop_mode,
			["Use one of: loop (wrap around), pingpong (back and forth), once (travel then stop)"]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var points: Array = _parse_points(args, is_2d)
	if points.size() < 2:
		return ToolUtils.error_with_solutions(
			"A moving platform needs at least 2 waypoints",
			[
				"Pass points like %s (relative to position)" % ("[[0,0],[200,0]]" if is_2d else "[[0,0,0],[4,0,0]]"),
				"Omit points to use the default horizontal sweep",
			]
		)

	# Resolve an optional existing rider BEFORE building anything, so a bad
	# target_path fails cleanly without leaving orphan nodes.
	var target: Node = null
	var target_path: String = ToolUtils.parse_string_arg(args, "target_path")
	if not target_path.is_empty():
		target = ToolUtils.find_node_by_path(target_path)
		if target == null:
			return ToolUtils.error("target_path '%s' not found" % target_path)
		if target == root:
			return ToolUtils.error("target_path can't be the scene root")
		var rider_ok: bool = (target is Node2D) if is_2d else (target is Node3D)
		if not rider_ok:
			return ToolUtils.error_with_solutions(
				"target_path '%s' is a %s, which can't ride a %s path" % [target_path, target.get_class(), space.to_upper()],
				[
					"Pass a %s-derived node (a body, sprite, enemy)" % ("Node2D" if is_2d else "Node3D"),
					"Or omit target_path to scaffold a platform",
				]
			)

	# Write the shared mover script once; reuse it on every subsequent call. The
	# 2D and 3D movers are distinct scripts so a project that has both kinds of
	# platform never has one clobber the other.
	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")
	var script_path := directory + ("/path_mover.gd" if is_2d else "/path_mover_3d.gd")
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, MOVER_SRC if is_2d else MOVER3D_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)
	var mover_script = load(script_path)
	if not (mover_script is Script):
		return ToolUtils.error("Wrote mover script but could not load it from '%s'" % script_path)

	# ── Build Path + curve ──
	# `path` / `curve` are kept UNTYPED (Variant) on purpose so the same assembly
	# code drives the 2D (Path2D/Curve2D) and 3D (Path3D/Curve3D) families; the
	# shared API (curve.add_point, path.to_global, curve.sample_baked,
	# node.global_position) is identical across both but lives on the subclasses,
	# not on Node — static typing as Node would fail to compile on `.curve` etc.
	var path = Path2D.new() if is_2d else Path3D.new()
	path.name = ToolUtils.parse_string_arg(args, "name", "MovingPlatform")
	if path.name == "":
		path.name = "MovingPlatform"
	var curve = Curve2D.new() if is_2d else Curve3D.new()
	for p in points:
		curve.add_point(p)
	path.curve = curve
	parent.add_child(path)
	path.owner = root
	if is_2d:
		path.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)
	else:
		path.position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	# ── Rider: an existing node, or a scaffolded platform ──
	# Untyped for the same reason as `path`: `.global_position` lives on Node2D/
	# Node3D, not on Node.
	var rider = null
	if target != null:
		rider = target
	else:
		rider = _build_platform_2d(args, path, root) if is_2d else _build_platform_3d(args, path, root)
	# Start the rider on the curve so it doesn't visually snap on the first frame.
	rider.global_position = path.to_global(curve.sample_baked(0.0))

	# ── PathMover logic node (drives the rider) ──
	var mover := Node.new()
	mover.name = "PathMover"
	path.add_child(mover)
	mover.owner = root
	mover.set_script(mover_script)
	mover.set("path_node", mover.get_path_to(path))
	mover.set("rider", mover.get_path_to(rider))
	mover.set("speed", max(1.0, ToolUtils.parse_float_arg(args, "speed", 80.0 if is_2d else 3.0)))
	mover.set("loop_mode", loop_mode)
	mover.set("wait_time", max(0.0, ToolUtils.parse_float_arg(args, "wait_time", 0.0)))

	var carry_note: String
	if target != null:
		carry_note = "An existing node now patrols the route (its own script is untouched)."
	elif is_2d:
		carry_note = (
			"The rider is an AnimatableBody2D the PathMover moves by its own transform, so it CARRIES a "
			+ "CharacterBody2D player — a StaticBody2D would not. Replace the Placeholder Polygon2D with a Sprite2D for real art."
		)
	else:
		carry_note = (
			"The rider is an AnimatableBody3D the PathMover moves by its own transform, so it CARRIES a "
			+ "CharacterBody3D player in BOTH directions — a StaticBody3D, or moving a parent node, leaves the player "
			+ "floating when the platform reverses. Replace the Placeholder mesh with real art."
		)

	return ToolUtils.success(
		(
			"Built a %s moving platform '%s' (%s). This tool is ATOMIC: it wrote (once) a VETTED PathMover "
			% [space.to_upper(), path.name, loop_mode]
		)
		+ "script and assembled Path + rider + PathMover. "
		+ carry_note
		+ " Edit the route by moving the Path's curve points; tune speed/loop_mode/wait_time on the PathMover. Then call save_scene.",
		{
			"created_script": script_path,
			"path": ToolUtils.node_relative_path(path),
			"mover": ToolUtils.node_relative_path(mover),
			"rider": ToolUtils.node_relative_path(rider),
			"space": space,
			"loop_mode": loop_mode,
			"point_count": points.size(),
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# Scaffold an AnimatableBody2D platform (collision + visible placeholder) as a
# child of the Path2D. AnimatableBody2D defaults to sync_to_physics = true; the
# PathMover moving its own global_position is what makes a player ride it.
func _build_platform_2d(args: Dictionary, path: Node, root: Node) -> Node2D:
	var size := ToolUtils.parse_vector2_arg(args, "size", Vector2(96, 16))
	if size.x <= 0.0 or size.y <= 0.0:
		size = Vector2(96, 16)
	var color: Color = (
		ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	)

	var body := AnimatableBody2D.new()
	body.name = "Platform"
	body.sync_to_physics = true
	path.add_child(body)
	body.owner = root

	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	var rect := RectangleShape2D.new()
	rect.size = size
	col.shape = rect
	# One-way: a CollisionShape2D blocks from its local up (-Y) when one_way is on,
	# so an unrotated platform is landable on top and passable from below.
	if ToolUtils.parse_bool_arg(args, "one_way", false):
		col.one_way_collision = true
	body.add_child(col)
	col.owner = root

	var half := size * 0.5
	var vis := Polygon2D.new()
	vis.name = "Placeholder"
	vis.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])
	vis.color = color
	body.add_child(vis)
	vis.owner = root
	return body


# Scaffold an AnimatableBody3D platform (collision + visible BoxMesh placeholder)
# as a child of the Path3D. AnimatableBody3D defaults to sync_to_physics = true
# (set explicitly here for clarity); the PathMover moving its own global_position
# is what makes a CharacterBody3D player ride it.
func _build_platform_3d(args: Dictionary, path: Node, root: Node) -> Node3D:
	var size := ToolUtils.parse_vector3_arg(args, "size", Vector3(2, 0.5, 2))
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		size = Vector3(2, 0.5, 2)
	var color: Color = (
		ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	)

	var body := AnimatableBody3D.new()
	body.name = "Platform"
	body.sync_to_physics = true
	path.add_child(body)
	body.owner = root

	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	col.owner = root

	var vis := MeshInstance3D.new()
	vis.name = "Placeholder"
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material = mat
	vis.mesh = mesh
	body.add_child(vis)
	vis.owner = root
	return body


# Parse the route into a plain Array of Vector2 (2D) or Vector3 (3D) points.
# A plain Array (not a Packed* array) is used so one code path covers both
# dimensions; Curve2D/Curve3D.add_point accept the per-element Vector at runtime.
# Accepts an array of [x,y(,z)] arrays, an array of "x,y(,z)" strings, or a
# single "x,y(,z);..." string. Defaults to a short horizontal sweep so a bare
# call still produces motion.
func _parse_points(args: Dictionary, is_2d: bool) -> Array:
	var out: Array = []
	if not args.has("points") or args["points"] == null:
		return _default_points(is_2d)
	var v = args["points"]
	if v is String:
		for chunk in (v as String).split(";", false):
			var pt = _str_to_vec(chunk, is_2d)
			if pt != null:
				out.append(pt)
	elif v is Array:
		for item in (v as Array):
			if item is String:
				var pt2 = _str_to_vec(item, is_2d)
				if pt2 != null:
					out.append(pt2)
			elif item is Array and (item as Array).size() >= 2:
				out.append(_arr_to_vec(item, is_2d))
			elif item is Dictionary:
				out.append(_dict_to_vec(item, is_2d))
	if out.is_empty():
		return _default_points(is_2d)
	return out


func _default_points(is_2d: bool) -> Array:
	if is_2d:
		return [Vector2.ZERO, Vector2(200, 0)]
	return [Vector3.ZERO, Vector3(4, 0, 0)]


func _arr_to_vec(item: Array, is_2d: bool):
	if is_2d:
		return Vector2(ToolUtils._num(item[0]), ToolUtils._num(item[1]))
	var z := ToolUtils._num(item[2]) if item.size() >= 3 else 0.0
	return Vector3(ToolUtils._num(item[0]), ToolUtils._num(item[1]), z)


func _dict_to_vec(d: Dictionary, is_2d: bool):
	if is_2d:
		return Vector2(ToolUtils._num(d.get("x", 0.0)), ToolUtils._num(d.get("y", 0.0)))
	return Vector3(ToolUtils._num(d.get("x", 0.0)), ToolUtils._num(d.get("y", 0.0)), ToolUtils._num(d.get("z", 0.0)))


# Parse "x,y" (2D) / "x,y,z" (3D) → Vector, or null when malformed. In 3D a
# missing third component defaults z to 0 (a horizontal sweep).
func _str_to_vec(s: String, is_2d: bool):
	var parts: PackedStringArray = s.split(",", false)
	if parts.size() < 2:
		return null
	var x: String = parts[0].strip_edges()
	var y: String = parts[1].strip_edges()
	if not x.is_valid_float() or not y.is_valid_float():
		return null
	if is_2d:
		return Vector2(float(x), float(y))
	var z := 0.0
	if parts.size() >= 3 and parts[2].strip_edges().is_valid_float():
		z = float(parts[2].strip_edges())
	return Vector3(float(x), float(y), z)


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
