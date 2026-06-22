extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Produces a complete, playable 2D player in ONE call. It writes a VETTED
# GDScript file VERBATIM — a CharacterBody2D controller in one of two styles —
# then assembles the scene around it: ensures a Player (CharacterBody2D with a
# RectangleShape2D collision + a colored Polygon2D placeholder so you SEE
# something on Play), a follow Camera2D, optionally a ground for platformers,
# adds the Player to the "player" group, attaches the script, and ensures the
# movement/jump input actions exist.
#
# Two styles (the 2D analogs of create_third_person_controller):
#   "platformer" (default) — side-view, gravity + jump. The vetted script ships
#       the three game-feel niceties hand-written controllers almost always omit:
#       COYOTE TIME (jump for a few frames after walking off a ledge), JUMP
#       BUFFERING (a jump pressed just before landing still fires), and VARIABLE
#       JUMP HEIGHT (tap = short hop, hold = full jump). These are the difference
#       between a jump that feels good and one that feels floaty or stiff — and
#       they're exactly the bits a model re-deriving movement from scratch leaves
#       out, so it compiles and looks right but feels wrong only in Play mode.
#   "top_down" — 8-direction movement, NO gravity, diagonals normalized so they
#       aren't faster than cardinal moves; acceleration/friction for a non-stiff
#       feel.
#
# Why a template tool instead of generating the controller from scratch: same
# rationale as the 3D create_third_person_controller — writing known-good code
# verbatim removes a whole class of subtly-broken gameplay code. The script
# sources below are the single source of truth.
#
# Like the 3D tool (and unlike the Unity analog), GDScript needs no compile/reload
# step: the script attaches synchronously via load() right after it is written, so
# this tool is fully atomic — no follow-up "compile then attach" contract.

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

# Input bindings each style references. snake_case names must match the action
# strings in the script sources below character-for-character.
const _PLATFORMER_ACTIONS := {
	"move_left": "A",
	"move_right": "D",
	"jump": "Space",
}
const _TOP_DOWN_ACTIONS := {
	"move_left": "A",
	"move_right": "D",
	"move_up": "W",
	"move_down": "S",
}

# Player placeholder + collision sizes (pixels). Platformer bodies are taller than
# wide; top-down bodies are square. A visible colored Polygon2D stands in until the
# caller assigns real art, so Play mode never shows an invisible player.
const _PLATFORMER_SIZE := Vector2(32, 48)
const _TOP_DOWN_SIZE := Vector2(32, 32)
const _PLACEHOLDER_COLOR := Color(0.36, 0.66, 0.94)  # a friendly blue

# ── Vetted script: 2D platformer (CharacterBody2D) ─────────────────────────
# Side-view gravity + jump with coyote time, jump buffering, variable jump height,
# and accel/friction horizontal movement. Exactly one move_and_slide() per frame.
const PLATFORMER_SRC := """extends CharacterBody2D

# 2D platformer movement with the game-feel niceties hand-written controllers
# usually omit: COYOTE TIME (jump for a moment after walking off a ledge), JUMP
# BUFFERING (a jump pressed just before landing still fires on touchdown), and
# VARIABLE JUMP HEIGHT (tap = short hop, hold = full jump). These three are what
# separate a jump that feels good from one that feels floaty or stiff.

@export var speed: float = 300.0
@export var acceleration: float = 2000.0
@export var friction: float = 2500.0
@export var jump_velocity: float = -600.0  # negative is up (Godot 2D y points down)
@export var coyote_time: float = 0.1
@export var jump_buffer_time: float = 0.1
# Releasing jump while still rising cuts upward velocity to this fraction, giving a
# variable-height jump (tap for a short hop, hold for the full arc).
@export var jump_cut_factor: float = 0.4

var _gravity: float = float(ProjectSettings.get_setting(\"physics/2d/default_gravity\", 980.0))
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0


func _physics_process(delta: float) -> void:
	# Horizontal: accelerate toward the target speed, or brake with friction.
	var direction := Input.get_axis(\"move_left\", \"move_right\")
	if direction != 0.0:
		velocity.x = move_toward(velocity.x, direction * speed, acceleration * delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, friction * delta)

	# Gravity while airborne.
	if not is_on_floor():
		velocity.y += _gravity * delta

	# Coyote time: full while grounded, counts down once we leave the floor.
	if is_on_floor():
		_coyote_timer = coyote_time
	else:
		_coyote_timer -= delta

	# Jump buffer: a press is remembered briefly so it can fire on landing.
	if Input.is_action_just_pressed(\"jump\"):
		_jump_buffer_timer = jump_buffer_time
	else:
		_jump_buffer_timer -= delta

	# Fire a jump when a buffered press meets a (real or coyote) grounded window.
	if _jump_buffer_timer > 0.0 and _coyote_timer > 0.0:
		velocity.y = jump_velocity
		_jump_buffer_timer = 0.0
		_coyote_timer = 0.0

	# Variable height: release early while rising to cut the ascent short.
	if Input.is_action_just_released(\"jump\") and velocity.y < 0.0:
		velocity.y *= jump_cut_factor

	move_and_slide()
"""

# ── Vetted script: 2D top-down (CharacterBody2D) ───────────────────────────
# 8-direction movement, no gravity. get_vector normalizes the input so diagonals
# aren't faster; accel/friction keep it from feeling stiff.
const TOP_DOWN_SRC := """extends CharacterBody2D

# Top-down 8-direction movement. No gravity. Diagonals are normalized (via
# Input.get_vector) so moving diagonally isn't faster than moving straight, and
# acceleration/friction give it weight instead of an instant-stop stiffness.

@export var speed: float = 300.0
@export var acceleration: float = 2000.0
@export var friction: float = 2500.0


func _physics_process(delta: float) -> void:
	var input_dir := Input.get_vector(\"move_left\", \"move_right\", \"move_up\", \"move_down\")
	if input_dir != Vector2.ZERO:
		velocity = velocity.move_toward(input_dir * speed, acceleration * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, friction * delta)
	move_and_slide()
"""


func _init() -> void:
	tool_name = "create_2d_controller"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)
	# 2D-only: a Node3D root can't host CharacterBody2D children. (A plain Node or
	# Node2D root is fine.) Point 3D callers at the matching template.
	if root is Node3D:
		return ToolUtils.error_with_solutions(
			"create_2d_controller is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root) for a 2D controller",
				"For a 3D player use create_third_person_controller instead",
			]
		)

	var style: String = ToolUtils.parse_string_arg(args, "style", "platformer").to_lower()
	if style == "platform":
		style = "platformer"
	if style == "topdown" or style == "top-down":
		style = "top_down"
	if style != "platformer" and style != "top_down":
		return ToolUtils.error_with_solutions(
			"Unknown style '%s'" % style,
			[
				"Use style='platformer' for side-view gravity + jump (Mario-like)",
				"Use style='top_down' for 8-direction movement, no gravity (Zelda-like)",
			]
		)
	var is_platformer: bool = style == "platformer"
	var actions: Dictionary = _PLATFORMER_ACTIONS if is_platformer else _TOP_DOWN_ACTIONS
	var body_size: Vector2 = _PLATFORMER_SIZE if is_platformer else _TOP_DOWN_SIZE
	var script_src: String = PLATFORMER_SRC if is_platformer else TOP_DOWN_SRC

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
	var create_camera: bool = ToolUtils.parse_bool_arg(args, "create_camera", true)
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	var script_path := directory + "/" + style + "_controller.gd"

	# The controller is a shared, vetted template — not a user asset. When the
	# script already exists, REUSE it (attach to the player) rather than aborting
	# the whole scaffold: that's what lets a second game built in a fresh scene
	# still get its player. Hard-refusing here used to leave the new scene with
	# no player at all whenever the project had built a controller before. Only
	# (re)write the file when it's absent or the caller opts in via overwrite,
	# so a user's manual edits to the script are preserved (reuse never clobbers).
	# Mirrors the write-once-or-reuse policy in create_collectible / create_hazard.
	var script_exists := FileAccess.file_exists(script_path)

	# If a node already occupies player_name, it must be a CharacterBody2D — the
	# controller `extends CharacterBody2D`, so attaching it to anything else is a
	# load error.
	var player: Node = ToolUtils.find_node_by_path(player_name)
	if player != null and not (player is CharacterBody2D):
		return ToolUtils.error_with_solutions(
			"A node named '%s' exists but is a %s, not a CharacterBody2D" % [player_name, player.get_class()],
			[
				"Pass a different player_name so a fresh CharacterBody2D is created",
				"Or delete/replace the existing node first",
			]
		)

	if not script_exists or overwrite:
		# Ensure the target directory exists.
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])

		# Write the vetted script verbatim.
		var werr := _write_file(script_path, script_src)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	# Make the editor register the file so load() resolves it this call.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	var notes: Array = []
	if script_exists and not overwrite:
		notes.append("reused existing vetted controller script '%s' (pass overwrite=true to regenerate)" % script_path)

	# ── Player (CharacterBody2D) ──
	if player == null:
		player = _build_player(root, player_name, body_size)
		notes.append("created Player (CharacterBody2D) with a %dx%d collision box + a placeholder Polygon2D" % [int(body_size.x), int(body_size.y)])
	else:
		notes.append("reused existing CharacterBody2D '%s'" % player_name)
	if not player.is_in_group("player"):
		player.add_to_group("player", true)

	var controller_script = load(script_path)
	if not (controller_script is Script):
		return ToolUtils.error("Wrote controller but could not load it from '%s'" % script_path)
	player.set_script(controller_script)

	# ── Camera (Camera2D, child of the player so it follows automatically) ──
	if create_camera and _find_first(player, "Camera2D") == null and _find_first(root, "Camera2D") == null:
		_build_camera(player)
		notes.append("added a Camera2D child of the Player (smoothed follow)")

	# ── Ground (platformer only — top-down has no gravity to fall onto) ──
	if is_platformer and create_ground and _find_ground(root) == null:
		_build_ground(root, player as Node2D, body_size)
		notes.append("created a wide Ground (StaticBody2D, scene had none)")

	# ── Input actions ──
	var ensured: Array = []
	for action_name in actions:
		if _ensure_input_action(String(action_name), String(actions[action_name])):
			ensured.append(String(action_name))
	if not ensured.is_empty():
		ProjectSettings.save()
		notes.append("ensured input actions: %s" % ", ".join(ensured))

	var feel := (
		"WASD/Arrow-equivalent move + Space to jump (with coyote time, jump buffering, and variable jump height)"
		if is_platformer
		else "WASD 8-direction movement (diagonals normalized, no gravity)"
	)
	return ToolUtils.success(
		"Created a complete, playable 2D %s controller. This tool is ATOMIC: it wrote a VETTED, known-good "
		% style
		+ "CharacterBody2D GDScript VERBATIM, attached it to the Player, added a placeholder visual + collision, a "
		+ "follow Camera2D, %sinput actions, and put the Player in the 'player' group. "
		% ("a ground, " if (is_platformer and create_ground) else "")
		+ "DO NOT hand-write a 2D controller for this request — the vetted template already ships the game-feel "
		+ "details (coyote time / jump buffer / variable jump height for platformers; normalized diagonals for "
		+ "top-down) that hand-written movement usually drops. Replace the placeholder Polygon2D with a Sprite2D or "
		+ "AnimatedSprite2D for real art. Your ONLY remaining step is to call save_scene; then press Play: %s." % feel,
		{
			"created_scripts": [script_path],
			"style": style,
			"player": ToolUtils.node_relative_path(player),
			"scene_setup": notes,
			"input_actions": actions.keys(),
		}
	)


# ── Scene-assembly helpers ─────────────────────────────────────────────────

func _build_player(root: Node, player_name: String, size: Vector2) -> CharacterBody2D:
	var body := CharacterBody2D.new()
	body.name = player_name
	root.add_child(body)
	body.owner = root
	body.position = Vector2.ZERO

	var col := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = size
	col.shape = rect
	col.name = "CollisionShape2D"
	body.add_child(col)
	col.owner = root

	# Visible placeholder so Play mode shows the player even before real art is
	# assigned. Centered on the body, matching the collision box.
	var vis := Polygon2D.new()
	vis.name = "Placeholder"
	var half := size * 0.5
	vis.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])
	vis.color = _PLACEHOLDER_COLOR
	body.add_child(vis)
	vis.owner = root
	return body


func _build_camera(player: Node) -> void:
	var cam := Camera2D.new()
	cam.name = "Camera2D"
	cam.position_smoothing_enabled = true
	player.add_child(cam)
	cam.owner = player.owner if player.owner != null else player


func _build_ground(root: Node, player: Node2D, body_size: Vector2) -> void:
	var ground := StaticBody2D.new()
	ground.name = "Ground"
	root.add_child(ground)
	ground.owner = root
	# Sit the ground's top just below the player's feet.
	var feet_y: float = (player.position.y if player != null else 0.0) + body_size.y * 0.5
	var ground_size := Vector2(2000, 100)
	ground.position = Vector2(0, feet_y + ground_size.y * 0.5)

	var gcol := CollisionShape2D.new()
	var grect := RectangleShape2D.new()
	grect.size = ground_size
	gcol.shape = grect
	gcol.name = "CollisionShape2D"
	ground.add_child(gcol)
	gcol.owner = root

	var gvis := Polygon2D.new()
	gvis.name = "Placeholder"
	var gh := ground_size * 0.5
	gvis.polygon = PackedVector2Array([
		Vector2(-gh.x, -gh.y),
		Vector2(gh.x, -gh.y),
		Vector2(gh.x, gh.y),
		Vector2(-gh.x, gh.y),
	])
	gvis.color = Color(0.27, 0.30, 0.36)
	ground.add_child(gvis)
	gvis.owner = root


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


# Ensure an InputMap action exists (persisted to project.godot + mirrored into the
# live InputMap). Leaves an already-defined action untouched so user bindings are
# never clobbered. Returns true if a new action was created.
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
