extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds trauma-based screen shake to a 2D camera in ONE call by writing a VETTED
# GDScript verbatim and attaching it to a Camera2D (found, or created if the
# scene has none). Screen shake is the other half of "juice" alongside particles
# — a camera kick on impact/landing/explosion is what makes a hit feel like it
# connected.
#
# Why a template tool: hand-written screen shake is reliably bad. The common
# mistakes are (a) pure per-frame random jitter (looks like cheap static, not a
# kick), (b) shake that's linear in intensity (so it can't be both subtle for a
# footstep and violent for an explosion), (c) shake that never decays or decays
# frame-rate-dependently, and (d) shaking `position`, which fights a camera that
# follows a target. The vetted script avoids all four: TRAUMA-based (intensity =
# trauma², so small hits barely shake and big hits really do), smooth-noise
# driven (FastNoiseLite, not random()), decays to zero on its own in seconds, and
# shakes via `offset` + `rotation` so it composes with a Camera2D that's also
# following the player by position.
#
# Trigger it from anywhere in gameplay code (the script joins the "screen_shake"
# group):
#     get_tree().get_first_node_in_group("screen_shake").shake(0.5)
# Bigger amount = bigger kick (0..1). Call it on a hit, a death, a hard landing,
# or right where you emit explosion particles.
#
# Args:
#   directory:   res:// folder for the generated script. Default "res://scripts".
#   camera_path: scene-relative path to the Camera2D to shake. Default: the first
#                Camera2D in the scene; if none exists, one is created (current).
#   overwrite:   overwrite the generated script if it already exists. Default
#                false (refuses rather than clobber).
#
# Response payload:
#   created_script, camera (node path), group ("screen_shake"),
#   trigger (the one-liner to call from gameplay)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "screen_shake"
const _TRIGGER := "get_tree().get_first_node_in_group(\"screen_shake\").shake(0.5)"

# ── Vetted script: trauma-based Camera2D shake ─────────────────────────────
const SHAKE_SRC := """extends Camera2D

# Trauma-based screen shake (the \"Art of Screenshake\" approach). Call shake()
# to add trauma; the visible shake is trauma SQUARED so small hits barely move
# the camera and big hits really kick, it decays to zero on its own, and it uses
# smooth noise (not per-frame random) so it reads as a kick instead of static.
# Applied through `offset` and `rotation`, so it layers cleanly on top of a
# camera that is also following a target by position.
#
# Trigger from anywhere:
#     get_tree().get_first_node_in_group(\"screen_shake\").shake(0.5)

@export var decay: float = 1.6                      # trauma lost per second
@export var max_offset: Vector2 = Vector2(24, 16)   # pixels at full trauma
@export var max_roll: float = 0.08                  # radians at full trauma
@export var noise_speed: float = 32.0

var _trauma: float = 0.0
var _t: float = 0.0
var _noise := FastNoiseLite.new()


func _ready() -> void:
	add_to_group(\"screen_shake\")
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.5
	_noise.seed = randi()


# Add trauma (0..1). Call on hits, explosions, hard landings. Stacks, so rapid
# calls build up and then decay together.
func shake(amount: float = 0.5) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)


func _process(delta: float) -> void:
	if _trauma <= 0.0:
		# Settle back to neutral so a following camera isn't left nudged.
		offset = Vector2.ZERO
		rotation = 0.0
		return
	_trauma = maxf(_trauma - decay * delta, 0.0)
	_t += delta * noise_speed
	var power := _trauma * _trauma
	offset = Vector2(
		max_offset.x * power * _noise.get_noise_2d(_t, 0.0),
		max_offset.y * power * _noise.get_noise_2d(0.0, _t),
	)
	rotation = max_roll * power * _noise.get_noise_2d(_t, _t)
"""


func _init() -> void:
	tool_name = "create_screen_shake"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)
	# The vetted script `extends Camera2D`; a 3D scene has no Camera2D to attach
	# it to. (3D screen shake is a separate, different implementation.)
	if root is Node3D:
		return ToolUtils.error_with_solutions(
			"create_screen_shake targets a Camera2D, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root)",
				"3D camera shake isn't supported by this tool yet",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var script_path := directory + "/screen_shake_camera.gd"
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)
	if FileAccess.file_exists(script_path) and not overwrite:
		return ToolUtils.error_with_solutions(
			"Refused to overwrite existing script '%s'" % script_path,
			[
				"Pass overwrite=true to regenerate the vetted script",
				"Pass a different 'directory' so the existing file isn't clobbered",
			]
		)

	# Resolve the target camera: an explicit path, else the first Camera2D, else
	# create one. A given path must actually be a Camera2D (the script extends it).
	var camera: Node = null
	var created_camera := false
	var camera_path: String = ToolUtils.parse_string_arg(args, "camera_path")
	if not camera_path.is_empty():
		camera = ToolUtils.find_node_by_path(camera_path)
		if camera == null:
			return ToolUtils.error("Camera '%s' not found" % camera_path)
		if not (camera is Camera2D):
			return ToolUtils.error_with_solutions(
				"Node '%s' is a %s, not a Camera2D" % [camera_path, camera.get_class()],
				["Pass the path to a Camera2D", "Or omit camera_path to use/create one automatically"]
			)
	else:
		camera = _find_first(root, "Camera2D")
		if camera == null:
			camera = _build_camera(root)
			created_camera = true

	# Ensure the target directory exists, then write the vetted script verbatim.
	var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if make_err != OK and make_err != ERR_ALREADY_EXISTS:
		return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
	var werr := _write_file(script_path, SHAKE_SRC)
	if werr != "":
		return ToolUtils.error(werr)
	SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	var shake_script = load(script_path)
	if not (shake_script is Script):
		return ToolUtils.error("Wrote script but could not load it from '%s'" % script_path)
	camera.set_script(shake_script)
	if not camera.is_in_group(_GROUP):
		camera.add_to_group(_GROUP, true)

	var notes: Array = []
	if created_camera:
		notes.append("created a Camera2D (scene had none) and set it current")
	else:
		notes.append("attached the shake script to existing camera '%s'" % camera.name)

	return ToolUtils.success(
		"Added trauma-based screen shake to '%s'. This tool is ATOMIC: it wrote a VETTED, known-good "
		% camera.name
		+ "Camera2D shake script VERBATIM and attached it. DO NOT hand-write screen shake — the template "
		+ "already avoids the usual failures (random jitter, no decay, shaking position instead of offset). "
		+ "It shakes via `offset`/`rotation`, so it composes with a camera that follows the player. To make "
		+ "something feel like it hit, call this ONE line wherever the impact happens (a hit, death, landing, "
		+ "or right where you emit explosion particles): %s — bigger amount (0..1) = bigger kick. "
		% _TRIGGER
		+ "Then call save_scene.",
		{
			"created_script": script_path,
			"camera": ToolUtils.node_relative_path(camera),
			"group": _GROUP,
			"trigger": _TRIGGER,
			"scene_setup": notes,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

func _build_camera(root: Node) -> Camera2D:
	var cam := Camera2D.new()
	cam.name = "Camera2D"
	root.add_child(cam)
	cam.owner = root
	return cam


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""


func _find_first(root: Node, type_name: String) -> Node:
	var matches := root.find_children("*", type_name, true, false)
	if matches.is_empty():
		return null
	return matches[0]
