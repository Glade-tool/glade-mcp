extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Produces a complete, playable third-person player in ONE call. It writes two
# VETTED GDScript files VERBATIM — third_person_controller.gd (CharacterBody3D
# camera-relative WASD movement + grounded jump) and orbit_camera.gd (a
# decoupled mouse-orbit camera) — then assembles the scene around them: ensures
# a Player (CharacterBody3D with capsule collision + mesh), a Camera3D, a ground
# plane, and a light, adds the Player to the "player" group, attaches both
# scripts, and ensures the WASD/jump input actions exist.
#
# Why a template tool instead of generating the controller from scratch: a model
# asked to hand-write a third-person controller tends to re-derive subtly-broken
# gameplay code — most commonly a self-referential camera (the camera derives its
# orbit angle from its own/the player's rotation while movement is camera-
# relative, forming a feedback loop that spins the view the moment you strafe
# with A/D). It compiles and looks correct, so it only shows up in Play mode.
# Writing known-good code verbatim removes that failure mode. The two scripts
# below are the single source of truth.
#
# Unlike the Unity analog, GDScript needs no compile/reload step: scripts attach
# synchronously via load() right after they are written, so this tool is fully
# atomic — no follow-up "compile then attach" contract for the caller to drop.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

# WASD + jump bindings the controller references. snake_case names must match the
# action strings in PLAYER_CONTROLLER_SRC character-for-character.
const _INPUT_ACTIONS := {
	"move_forward": "W",
	"move_back": "S",
	"move_left": "A",
	"move_right": "D",
	"jump": "Space",
}

# ── Vetted script: CharacterBody3D movement ────────────────────────────────
# Camera-relative WASD flattened to the ground plane; gravity + jump; exactly one
# move_and_slide() per physics frame. The body is NOT rotated here and the camera
# is independent, so A/D strafes in a straight line (no circling).
const PLAYER_CONTROLLER_SRC := """extends CharacterBody3D

# Third-person WASD movement, relative to the camera's facing. Pairs with
# orbit_camera.gd. Pressing W always walks \"into the screen\" regardless of where
# the camera has been orbited. This script never rotates the body and never reads
# the camera's angle back into the camera, so strafing with A/D moves in a
# straight line instead of circling.

@export var speed: float = 6.0
@export var jump_velocity: float = 5.0

var _gravity: float = float(ProjectSettings.get_setting(\"physics/3d/default_gravity\", 9.8))


func _physics_process(delta: float) -> void:
	# Camera-relative basis, flattened onto the ground plane. Falls back to world
	# axes until an active camera exists.
	var cam := get_viewport().get_camera_3d()
	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT
	if cam != null:
		forward = -cam.global_transform.basis.z
		right = cam.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized()
	right = right.normalized()

	var input_dir := Input.get_vector(\"move_left\", \"move_right\", \"move_forward\", \"move_back\")
	var direction := (right * input_dir.x) + (forward * -input_dir.y)
	if direction.length() > 0.01:
		direction = direction.normalized()
	else:
		direction = Vector3.ZERO

	velocity.x = direction.x * speed
	velocity.z = direction.z * speed

	if not is_on_floor():
		velocity.y -= _gravity * delta
	if Input.is_action_just_pressed(\"jump\") and is_on_floor():
		velocity.y = jump_velocity

	move_and_slide()
"""

# ── Vetted script: decoupled orbit camera ──────────────────────────────────
# Follows the target's POSITION and orbits via mouse look. The orbit angle is
# explicit yaw/pitch that ONLY changes on mouse input — the camera never derives
# its angle from its own transform or the player's rotation, so there is no
# feedback loop that spins the view while strafing.
const ORBIT_CAMERA_SRC := """extends Camera3D

# Decoupled third-person orbit camera. Resolves its target by the \"player\" group
# (then by a node named \"Player\"), follows its position, and orbits on mouse
# look. Because the orbit angle is stored state that only the mouse changes, and
# the camera position is computed from that state plus the target position (never
# from the camera's own basis), there is no rotational feedback loop — the view
# stays put while you strafe.

@export var distance: float = 5.0
@export var height: float = 1.5
@export var mouse_sensitivity: float = 0.005
@export var min_pitch: float = -1.3
@export var max_pitch: float = 0.4

var _yaw: float = 0.0
var _pitch: float = -0.35
var _target: Node3D = null


func _ready() -> void:
	_target = _resolve_target()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _resolve_target() -> Node3D:
	for n in get_tree().get_nodes_in_group(\"player\"):
		if n is Node3D:
			return n
	var scene := get_tree().current_scene
	if scene != null:
		var found := scene.find_child(\"Player\", true, false)
		if found is Node3D:
			return found
	return null


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		_yaw -= motion.relative.x * mouse_sensitivity
		_pitch -= motion.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, min_pitch, max_pitch)
	elif event.is_action_pressed(\"ui_cancel\"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(_delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		_target = _resolve_target()
		if _target == null:
			return
	var pivot := _target.global_position + Vector3.UP * height
	var orbit := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	global_position = pivot + orbit * Vector3(0.0, 0.0, distance)
	look_at(pivot, Vector3.UP)
"""


func _init() -> void:
	tool_name = "create_third_person_controller"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 3D scene"]
		)
	if root is Node2D:
		return ToolUtils.error_with_solutions(
			"create_third_person_controller is 3D-only, but the open scene's root is 2D (Node2D)",
			[
				"Open or create a 3D scene (Node3D root) for a third-person camera",
				"For a 2D character use create_physics_body + create_script instead",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var player_name: String = ToolUtils.parse_string_arg(args, "player_name", "Player")
	if player_name.is_empty():
		player_name = "Player"
	var create_ground: bool = ToolUtils.parse_bool_arg(args, "create_ground", true)
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	var controller_path := directory + "/third_person_controller.gd"
	var camera_path := directory + "/orbit_camera.gd"

	# The controller + camera are shared, vetted templates — not user assets.
	# When they already exist, REUSE them rather than aborting the scaffold, so a
	# second 3D game built in a fresh scene still gets its player + camera. Only
	# (re)write each file when absent or overwrite=true, so a user's manual edits
	# survive. Mirrors the write-once-or-reuse policy in create_collectible.
	var controller_exists := FileAccess.file_exists(controller_path)
	var camera_exists := FileAccess.file_exists(camera_path)

	# If a node already occupies player_name, it must be a CharacterBody3D — the
	# controller `extends CharacterBody3D`, so attaching it to anything else is a
	# load error.
	var player: Node = ToolUtils.find_node_by_path(player_name)
	if player != null and not (player is CharacterBody3D):
		return ToolUtils.error_with_solutions(
			"A node named '%s' exists but is a %s, not a CharacterBody3D" % [player_name, player.get_class()],
			[
				"Pass a different player_name so a fresh CharacterBody3D is created",
				"Or delete/replace the existing node first",
			]
		)

	# Ensure the target directory exists (only needed when we're about to write).
	if not controller_exists or not camera_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])

	# Write each vetted script verbatim, skipping any that already exist (reuse).
	if not controller_exists or overwrite:
		var werr := _write_file(controller_path, PLAYER_CONTROLLER_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not controller_exists:
			SessionTracker.mark_created(controller_path)
	if not camera_exists or overwrite:
		var werr2 := _write_file(camera_path, ORBIT_CAMERA_SRC)
		if werr2 != "":
			return ToolUtils.error(werr2)
		if not camera_exists:
			SessionTracker.mark_created(camera_path)

	# Make the editor register the files so load() resolves them this call.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(controller_path)
		fs.update_file(camera_path)

	var notes: Array = []

	# ── Player (CharacterBody3D) ──
	if player == null:
		player = _build_player(root, player_name)
		notes.append("created Player (CharacterBody3D) with capsule collision + mesh at (0, 1, 0)")
	else:
		notes.append("reused existing CharacterBody3D '%s'" % player_name)
	if not player.is_in_group("player"):
		player.add_to_group("player", true)

	var controller_script = load(controller_path)
	if not (controller_script is Script):
		return ToolUtils.error("Wrote controller but could not load it from '%s'" % controller_path)
	player.set_script(controller_script)

	# ── Camera (Camera3D) ──
	var camera: Node = _find_first(root, "Camera3D")
	if camera == null:
		camera = _build_camera(root)
		notes.append("created Camera3D (set current)")
	else:
		notes.append("reused existing camera '%s'" % camera.name)
	var camera_script = load(camera_path)
	if not (camera_script is Script):
		return ToolUtils.error("Wrote camera script but could not load it from '%s'" % camera_path)
	camera.set_script(camera_script)

	# ── Ground ──
	if create_ground and _find_ground(root) == null:
		_build_ground(root)
		notes.append("created a 50x50 Ground (StaticBody3D, scene had none)")

	# ── Light (so the player is visible in a fresh scene) ──
	if _find_first(root, "Light3D") == null:
		_build_light(root)
		notes.append("added a DirectionalLight3D (scene had no light)")

	# ── Input actions ──
	var ensured: Array = []
	for action_name in _INPUT_ACTIONS:
		if _ensure_input_action(String(action_name), String(_INPUT_ACTIONS[action_name])):
			ensured.append(String(action_name))
	if not ensured.is_empty():
		ProjectSettings.save()
		notes.append("ensured input actions: %s" % ", ".join(ensured))

	return ToolUtils.success(
		"Created a complete, playable third-person controller. This tool is ATOMIC: it wrote two VETTED, "
		+ "known-good GDScript files (third_person_controller.gd + orbit_camera.gd) VERBATIM, attached them to "
		+ "the Player and the Camera3D, ensured a ground + light + WASD/jump input actions, and added the Player "
		+ "to the 'player' group so the camera resolves it. DO NOT hand-write a controller or camera script for "
		+ "this request — the vetted templates already avoid the self-referential-camera bug (view spinning while "
		+ "you strafe). Your ONLY remaining step is to call save_scene; then press Play: WASD moves the player "
		+ "camera-relative, the mouse orbits the camera (Esc frees the cursor), and Space jumps.",
		{
			"created_scripts": [controller_path, camera_path],
			"player": ToolUtils.node_relative_path(player),
			"camera": ToolUtils.node_relative_path(camera),
			"scene_setup": notes,
			"input_actions": _INPUT_ACTIONS.keys(),
		}
	)


# ── Scene-assembly helpers ─────────────────────────────────────────────────

func _build_player(root: Node, player_name: String) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = player_name
	root.add_child(body)
	body.owner = root
	body.position = Vector3(0, 1, 0)

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.5
	cap.height = 2.0
	col.shape = cap
	col.name = "CollisionShape3D"
	body.add_child(col)
	col.owner = root

	var mesh := MeshInstance3D.new()
	var capmesh := CapsuleMesh.new()
	capmesh.radius = 0.5
	capmesh.height = 2.0
	mesh.mesh = capmesh
	mesh.name = "MeshInstance3D"
	body.add_child(mesh)
	mesh.owner = root
	return body


func _build_camera(root: Node) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	root.add_child(cam)
	cam.owner = root
	cam.position = Vector3(0, 3, 5)
	cam.current = true
	return cam


func _build_ground(root: Node) -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	root.add_child(ground)
	ground.owner = root

	var gcol := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(50, 1, 50)
	gcol.shape = gbox
	gcol.name = "CollisionShape3D"
	gcol.position = Vector3(0, -0.5, 0)
	ground.add_child(gcol)
	gcol.owner = root

	var gmesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(50, 50)
	gmesh.mesh = plane
	gmesh.name = "MeshInstance3D"
	ground.add_child(gmesh)
	gmesh.owner = root


func _build_light(root: Node) -> void:
	var light := DirectionalLight3D.new()
	light.name = "DirectionalLight3D"
	root.add_child(light)
	light.owner = root
	light.rotation_degrees = Vector3(-50, -30, 0)


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


func _find_ground(root: Node) -> Node:
	for n in root.find_children("*", "", true, false):
		var ln := String(n.name).to_lower()
		if ln.contains("ground") or ln.contains("floor") or ln.contains("terrain"):
			return n
	return null


# Ensure an InputMap action exists (persisted to project.godot + mirrored into
# the live InputMap). Leaves an already-defined action untouched so user bindings
# are never clobbered. Returns true if a new action was created.
func _ensure_input_action(action_name: String, key_name: String) -> bool:
	var setting := "input/" + action_name
	if ProjectSettings.has_setting(setting):
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		return false
	var keycode := OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		return false
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	ProjectSettings.set_setting(setting, {"deadzone": 0.5, "events": [ev]})
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	else:
		InputMap.action_erase_events(action_name)
	InputMap.action_add_event(action_name, ev)
	return true
