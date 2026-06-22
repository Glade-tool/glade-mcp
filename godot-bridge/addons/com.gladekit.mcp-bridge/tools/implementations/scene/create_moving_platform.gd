extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Builds a MOVING PLATFORM (or sends an existing node patrolling a route) in ONE
# call: a Path2D holding the waypoint curve, a rider that travels it at constant
# speed, and a small PathMover logic-node that drives the rider. By default the
# rider is a freshly scaffolded AnimatableBody2D platform (collision + visible
# placeholder) that CARRIES a CharacterBody2D player; pass `target_path` instead
# to send an existing Node2D (an enemy, a hazard) patrolling the same route.
#
# Why a PathMover that sets the rider's OWN global_position (rather than parenting
# the rider under a moving PathFollow2D): an AnimatableBody2D only reports its
# platform velocity to a resting CharacterBody2D when its OWN transform changes —
# the same reason the engine's carrying-platform recipe animates the body's
# position directly. Moving a parent node leaves the body's own transform
# constant, so move_and_slide sees no platform velocity and the player is left
# behind. Driving the rider's own global_position fixes that and, as a bonus,
# never needs to own the rider's script (so a patrolling enemy keeps its own).
#
# Hand-rolled moving platforms are reliably buggy: a StaticBody2D the player
# slides off instead of riding, a _process mover physics never sees, or a
# home-grown lerp that stutters at the seams. This tool sidesteps all three:
# AnimatableBody2D (sync_to_physics) for the carry, a vetted mover that runs in
# _physics_process, and Godot's own baked curve for smooth interpolation.
# loop_mode covers the three real cases — "loop" (wrap around), "pingpong" (back
# and forth), "once" (travel then stop).
#
# Args:
#   name:        Path2D node name. Default "MovingPlatform".
#   parent_path: scene-relative parent. Default: the scene root.
#   position:    "x,y" placement of the Path2D (waypoints are relative to it).
#                Default 0,0.
#   points:      the route, as waypoints relative to `position`. Accepts
#                [[x,y], ...], ["x,y", ...], or a single "x,y;x,y" string. The
#                first point is the start. Default: [[0,0], [200,0]] (a short
#                horizontal sweep) so a bare call still moves.
#   speed:       pixels per second along the curve. Default 80.
#   loop_mode:   "loop" | "pingpong" | "once". Default "loop".
#   wait_time:   seconds to pause at each end (pingpong/once). Default 0.
#   size:        "w,h" of the scaffolded platform body. Default "96,16".
#                Ignored when target_path is given.
#   one_way:     make the scaffolded platform ONE-WAY — the player lands on top
#                but jumps up through it from below. Default false. Ignored when
#                target_path is given.
#   color:       placeholder fill color for the scaffolded platform.
#   target_path: scene-relative path to an EXISTING Node2D to send along the
#                route instead of scaffolding a platform. Its script is left
#                intact (the PathMover drives its position, not its script).
#   directory:   res:// folder for the generated mover script.
#                Default "res://scripts".
#   overwrite:   regenerate the shared mover script if it exists. Default false.
#
# Response payload:
#   created_script, path (Path2D node path), mover (PathMover node path),
#   rider (the platform/target node path), loop_mode, point_count

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _DEFAULT_COLOR := Color(0.55, 0.58, 0.65)  # neutral platform grey
const _VALID_MODES := ["loop", "pingpong", "once"]

# ── Vetted script: PathMover ───────────────────────────────────────────────
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


func _init() -> void:
	tool_name = "create_moving_platform"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)
	# Path2D / AnimatableBody2D are 2D nodes.
	if root is Node3D:
		return ToolUtils.error_with_solutions(
			"create_moving_platform is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root)",
				"3D moving platforms aren't supported by this tool yet",
			]
		)

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

	var points := _parse_points(args)
	if points.size() < 2:
		return ToolUtils.error_with_solutions(
			"A moving platform needs at least 2 waypoints",
			["Pass points like [[0,0],[200,0]] (relative to position)", "Omit points to use the default horizontal sweep"]
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
		if not (target is Node2D):
			return ToolUtils.error_with_solutions(
				"target_path '%s' is a %s, not a Node2D — it can't ride a 2D path" % [target_path, target.get_class()],
				["Pass a Node2D-derived node (a body, sprite, enemy)", "Or omit target_path to scaffold a platform"]
			)

	# Write the shared mover script once; reuse it on every subsequent call.
	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")
	var script_path := directory + "/path_mover.gd"
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, MOVER_SRC)
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

	# ── Build Path2D + curve ──
	var path := Path2D.new()
	path.name = ToolUtils.parse_string_arg(args, "name", "MovingPlatform")
	if path.name == "":
		path.name = "MovingPlatform"
	var curve := Curve2D.new()
	for p in points:
		curve.add_point(p)
	path.curve = curve
	parent.add_child(path)
	path.owner = root
	path.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	# ── Rider: an existing node, or a scaffolded platform ──
	var rider: Node2D = null
	if target != null:
		rider = target as Node2D
	else:
		rider = _build_platform(args, path, root)
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
	mover.set("speed", max(1.0, ToolUtils.parse_float_arg(args, "speed", 80.0)))
	mover.set("loop_mode", loop_mode)
	mover.set("wait_time", max(0.0, ToolUtils.parse_float_arg(args, "wait_time", 0.0)))

	return ToolUtils.success(
		(
			"Built a moving platform '%s' (%s). This tool is ATOMIC: it wrote (once) a VETTED PathMover "
			% [path.name, loop_mode]
		)
		+ "script and assembled Path2D + rider + PathMover. "
		+ (
			"An existing node now patrols the route (its own script is untouched)."
			if target != null
			else "The rider is an AnimatableBody2D the PathMover moves by its own transform, so it CARRIES a CharacterBody2D player — a StaticBody2D would not. Replace the Placeholder Polygon2D with a Sprite2D for real art."
		)
		+ " Edit the route by moving the Path2D's curve points; tune speed/loop_mode/wait_time on the PathMover. Then call save_scene.",
		{
			"created_script": script_path,
			"path": ToolUtils.node_relative_path(path),
			"mover": ToolUtils.node_relative_path(mover),
			"rider": ToolUtils.node_relative_path(rider),
			"loop_mode": loop_mode,
			"point_count": points.size(),
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# Scaffold an AnimatableBody2D platform (collision + visible placeholder) as a
# child of the Path2D. AnimatableBody2D defaults to sync_to_physics = true; the
# PathMover moving its own global_position is what makes a player ride it.
func _build_platform(args: Dictionary, path: Node, root: Node) -> Node2D:
	var size := ToolUtils.parse_vector2_arg(args, "size", Vector2(96, 16))
	if size.x <= 0.0 or size.y <= 0.0:
		size = Vector2(96, 16)
	var color: Color = (
		ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	)

	var body := AnimatableBody2D.new()
	body.name = "Platform"
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


# Parse the route into a PackedVector2Array. Accepts an array of [x,y] arrays,
# an array of "x,y" strings, or a single "x,y;x,y;..." string. Defaults to a
# short horizontal sweep so a bare call still produces motion.
func _parse_points(args: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not args.has("points") or args["points"] == null:
		return PackedVector2Array([Vector2.ZERO, Vector2(200, 0)])
	var v = args["points"]
	if v is String:
		for chunk in (v as String).split(";", false):
			var pt = _str_to_vec2(chunk)
			if pt != null:
				out.append(pt)
	elif v is Array:
		for item in (v as Array):
			if item is String:
				var pt2 = _str_to_vec2(item)
				if pt2 != null:
					out.append(pt2)
			elif item is Array and (item as Array).size() >= 2:
				out.append(Vector2(ToolUtils._num(item[0]), ToolUtils._num(item[1])))
			elif item is Dictionary:
				out.append(Vector2(ToolUtils._num(item.get("x", 0.0)), ToolUtils._num(item.get("y", 0.0))))
	if out.is_empty():
		return PackedVector2Array([Vector2.ZERO, Vector2(200, 0)])
	return out


# Parse "x,y" → Vector2, or null when malformed.
func _str_to_vec2(s: String):
	var parts: PackedStringArray = s.split(",", false)
	if parts.size() < 2:
		return null
	var x: String = parts[0].strip_edges()
	var y: String = parts[1].strip_edges()
	if not x.is_valid_float() or not y.is_valid_float():
		return null
	return Vector2(float(x), float(y))


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
