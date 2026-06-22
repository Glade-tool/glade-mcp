extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Gives a node the ability to SHOOT in ONE call — the missing combat verb. The
# scene already has enemies (create_enemy_2d/3d) and impact VFX (create_particles_*),
# but nothing could fire at them. This wires up the whole shoot loop: a vetted
# PROJECTILE script (a flying Area that travels, damages, and expires) plus a
# vetted SHOOTER attached to the player/turret that spawns projectiles on an input
# action. Dimension-aware: `space="2d"|"3d"` (inferred from the open scene's root
# when omitted), so a bare call in a 2D scene builds an Area2D projectile + Node2D
# shooter, and in a 3D scene an Area3D + Node3D.
#
# Why a Shooter CHILD node (not a script on the player): a Godot node holds ONE
# script, and the player already runs its movement controller — so the shooter is
# added as a CHILD of the target (default name "Shooter"). It fires from its own
# global position (which equals the parent's), so projectiles leave the player.
#
# How a projectile deals damage: on overlap it looks for `take_damage(amount)` on
# the hit node OR its parent (an enemy is usually a body with a child Hurtbox Area,
# so the overlap reports the Hurtbox whose parent is the enemy). If the target has
# no health method yet, the projectile just frees it (a destroy-on-hit fallback),
# so this is useful before a health system exists and composes cleanly once one
# does. Only nodes in `target_group` (default "enemies") are hit; everything else
# (walls, the shooter itself) is ignored and the projectile flies on until its
# `lifetime` runs out.
#
# Aim:
#   2D — default "mouse" (toward the cursor); also "right"/"left"/"up"/"down".
#   3D — default "forward" (the shooter's -Z); also back/left/right/up/down.
#
# Firing input: registers `input_action` (default "shoot") bound to `key`
# (default "mouse_left" — click to shoot; also accepts mouse_right/middle or any
# keyboard key name like "J"/"Space"), persisted to project.godot and mirrored
# into the live InputMap so it fires the moment the project runs.
#
# The two scripts are written ONCE per project (projectile_<space>.gd /
# shooter_<space>.gd) and reused on every call, so a second turret is just another
# call (or duplicate_node the Shooter).
#
# Args:
#   space:         "2d" | "3d". Default: inferred from the open scene's root.
#   shooter_path:  node the Shooter is parented to. Default: the "player"-group
#                  node if one exists, else the scene root.
#   name:          Shooter node name. Default "Shooter".
#   input_action:  action that fires. Default "shoot".
#   key:           binding for the action — "mouse_left" (default), "mouse_right",
#                  "mouse_middle", or a keyboard key ("J", "Space", ...).
#   aim:           travel direction (see Aim above). Default "mouse" (2D) / "forward" (3D).
#   speed:         projectile speed. Default 600 (2D, px/s) / 24 (3D, m/s).
#   damage:        damage dealt to a hit target. Default 1.
#   lifetime:      seconds before a projectile frees itself. Default 2 (2D) / 3 (3D).
#   cooldown:      minimum seconds between shots. Default 0.25.
#   radius:        projectile size. Default 6 (2D, px) / 0.15 (3D, m).
#   color:         projectile placeholder color. Default warm yellow.
#   target_group:  group a projectile damages. Default "enemies".
#   directory:     res:// folder for the generated scripts. Default "res://scripts".
#   overwrite:     regenerate the shared scripts if they exist. Default false.
#
# Response payload:
#   created_scripts (projectile + shooter), shooter (node path), input_action,
#   key, space, aim, group ("projectiles")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "projectiles"
const _DEFAULT_COLOR := Color(0.96, 0.86, 0.22)  # warm yellow tracer
const _PROJ_TOKEN := "__PROJECTILE_PATH__"

# ── Vetted script: Projectile2D (flying, damaging Area2D) ────────────────────
const PROJECTILE_2D_SRC := """extends Area2D

# A flying projectile. Travels in a straight line along `direction` at `speed`,
# damages the first node in `target_group` it overlaps, and frees itself on hit
# or after `lifetime` seconds. Self-assembles its collision circle + a placeholder
# visual in _ready, so the Shooter only sets a handful of values and fires.

@export var speed: float = 600.0
@export var damage: int = 1
@export var lifetime: float = 2.0
@export var radius: float = 6.0
@export var color: Color = Color(0.96, 0.86, 0.22)
@export var target_group: String = \"enemies\"

# Set by the Shooter before the node enters the tree; world-space travel.
var direction: Vector2 = Vector2.RIGHT
var _age: float = 0.0


func _ready() -> void:
	add_to_group(\"projectiles\")
	var col := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	col.shape = circle
	add_child(col)
	# A small filled disc placeholder so the shot is visible without art.
	var vis := Polygon2D.new()
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * float(i) / 12.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	vis.polygon = pts
	vis.color = color
	add_child(vis)
	area_entered.connect(_on_overlap)
	body_entered.connect(_on_overlap)


func _physics_process(delta: float) -> void:
	global_position += direction * speed * delta
	_age += delta
	if _age >= lifetime:
		queue_free()


func _on_overlap(node: Node) -> void:
	var target := _target(node)
	if target == null:
		return
	if target.has_method(\"take_damage\"):
		target.take_damage(damage)
	else:
		target.queue_free()  # no health system yet: destroy on hit
	queue_free()


# The hit node, or its parent, if either is in target_group. An enemy is often a
# body with a child Hurtbox Area, so the overlap reports the Hurtbox.
func _target(node: Node) -> Node:
	if node.is_in_group(target_group):
		return node
	var parent := node.get_parent()
	if parent != null and parent.is_in_group(target_group):
		return parent
	return null
"""

# ── Vetted script: Shooter2D (spawns projectiles on input) ───────────────────
const SHOOTER_2D_SRC := """extends Node2D

# Attached as a CHILD of the shooter (player / turret) so it never replaces the
# parent's script. On `input_action` (respecting `cooldown`) it spawns a
# projectile at this node's global position, aimed per `aim`.

@export var input_action: String = \"shoot\"
@export_enum(\"mouse\", \"right\", \"left\", \"up\", \"down\") var aim: String = \"mouse\"
@export var speed: float = 600.0
@export var damage: int = 1
@export var lifetime: float = 2.0
@export var cooldown: float = 0.25
@export var projectile_radius: float = 6.0
@export var projectile_color: Color = Color(0.96, 0.86, 0.22)
@export var target_group: String = \"enemies\"

const PROJECTILE := preload(\"__PROJECTILE_PATH__\")
var _cooldown_left: float = 0.0


func _process(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left -= delta
	if _cooldown_left <= 0.0 and Input.is_action_pressed(input_action):
		_fire()
		_cooldown_left = cooldown


func _fire() -> void:
	var p := Area2D.new()
	p.set_script(PROJECTILE)
	p.set(\"speed\", speed)
	p.set(\"damage\", damage)
	p.set(\"lifetime\", lifetime)
	p.set(\"radius\", projectile_radius)
	p.set(\"color\", projectile_color)
	p.set(\"target_group\", target_group)
	p.set(\"direction\", _aim_direction())
	# Parent to the running scene (not to this node) so it travels in world space.
	var host := get_tree().current_scene
	if host == null:
		host = get_tree().root
	host.add_child(p)
	p.global_position = global_position


func _aim_direction() -> Vector2:
	match aim:
		\"left\":
			return Vector2.LEFT
		\"up\":
			return Vector2.UP
		\"down\":
			return Vector2.DOWN
		\"right\":
			return Vector2.RIGHT
		_:  # \"mouse\"
			var d := get_global_mouse_position() - global_position
			return d.normalized() if d.length() > 0.001 else Vector2.RIGHT
"""

# ── Vetted script: Projectile3D ──────────────────────────────────────────────
const PROJECTILE_3D_SRC := """extends Area3D

# A flying projectile. Travels in a straight line along `direction` at `speed`,
# damages the first node in `target_group` it overlaps, and frees itself on hit
# or after `lifetime` seconds. Self-assembles its collision sphere + a glowing
# placeholder mesh in _ready, so the Shooter only sets values and fires.

@export var speed: float = 24.0
@export var damage: int = 1
@export var lifetime: float = 3.0
@export var radius: float = 0.15
@export var color: Color = Color(0.96, 0.86, 0.22)
@export var target_group: String = \"enemies\"

var direction: Vector3 = Vector3.FORWARD
var _age: float = 0.0


func _ready() -> void:
	add_to_group(\"projectiles\")
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	col.shape = sphere
	add_child(col)
	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mesh.material_override = mat
	add_child(mesh)
	area_entered.connect(_on_overlap)
	body_entered.connect(_on_overlap)


func _physics_process(delta: float) -> void:
	global_position += direction * speed * delta
	_age += delta
	if _age >= lifetime:
		queue_free()


func _on_overlap(node: Node) -> void:
	var target := _target(node)
	if target == null:
		return
	if target.has_method(\"take_damage\"):
		target.take_damage(damage)
	else:
		target.queue_free()  # no health system yet: destroy on hit
	queue_free()


func _target(node: Node) -> Node:
	if node.is_in_group(target_group):
		return node
	var parent := node.get_parent()
	if parent != null and parent.is_in_group(target_group):
		return parent
	return null
"""

# ── Vetted script: Shooter3D ─────────────────────────────────────────────────
const SHOOTER_3D_SRC := """extends Node3D

# Attached as a CHILD of the shooter so it never replaces the parent's script. On
# `input_action` (respecting `cooldown`) it spawns a projectile at this node's
# global position, aimed per `aim` relative to the shooter's facing.

@export var input_action: String = \"shoot\"
@export_enum(\"forward\", \"back\", \"left\", \"right\", \"up\", \"down\") var aim: String = \"forward\"
@export var speed: float = 24.0
@export var damage: int = 1
@export var lifetime: float = 3.0
@export var cooldown: float = 0.25
@export var projectile_radius: float = 0.15
@export var projectile_color: Color = Color(0.96, 0.86, 0.22)
@export var target_group: String = \"enemies\"

const PROJECTILE := preload(\"__PROJECTILE_PATH__\")
var _cooldown_left: float = 0.0


func _process(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left -= delta
	if _cooldown_left <= 0.0 and Input.is_action_pressed(input_action):
		_fire()
		_cooldown_left = cooldown


func _fire() -> void:
	var p := Area3D.new()
	p.set_script(PROJECTILE)
	p.set(\"speed\", speed)
	p.set(\"damage\", damage)
	p.set(\"lifetime\", lifetime)
	p.set(\"radius\", projectile_radius)
	p.set(\"color\", projectile_color)
	p.set(\"target_group\", target_group)
	p.set(\"direction\", _aim_direction())
	var host := get_tree().current_scene
	if host == null:
		host = get_tree().root
	host.add_child(p)
	p.global_position = global_position


func _aim_direction() -> Vector3:
	var b := global_transform.basis
	match aim:
		\"back\":
			return b.z.normalized()
		\"left\":
			return (-b.x).normalized()
		\"right\":
			return b.x.normalized()
		\"up\":
			return b.y.normalized()
		\"down\":
			return (-b.y).normalized()
		_:  # \"forward\"
			return (-b.z).normalized()
"""


func _init() -> void:
	tool_name = "create_projectile"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new scene"]
		)

	var space: String = ToolUtils.resolve_space(args, ToolUtils.classify_node_space(root))
	if space != "2d" and space != "3d":
		space = "3d" if root is Node3D else "2d"

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Shooter")
	if node_name.is_empty():
		node_name = "Shooter"

	# Parent the Shooter to the player by default (or to the given node, or root).
	var shooter_path: String = ToolUtils.parse_string_arg(args, "shooter_path")
	var parent: Node
	if not shooter_path.is_empty():
		parent = ToolUtils.find_node_by_path(shooter_path)
		if parent == null:
			return ToolUtils.error("shooter_path '%s' not found" % shooter_path)
	else:
		parent = _find_in_group(root, "player")
		if parent == null:
			parent = root

	# A Node2D shooter belongs on a 2D host; a Node3D on a 3D host. Guard against a
	# 3D projectile request hanging off a 2D parent and vice-versa.
	if space == "3d" and (parent is Node2D or parent is CanvasItem):
		return ToolUtils.error_with_solutions(
			"space=3d but the shooter would attach to a 2D node ('%s')" % parent.name,
			["Pass shooter_path to a Node3D", "Or use space=2d for a 2D scene"]
		)
	if space == "2d" and parent is Node3D:
		return ToolUtils.error_with_solutions(
			"space=2d but the shooter would attach to a 3D node ('%s')" % parent.name,
			["Pass shooter_path to a Node2D", "Or use space=3d for a 3D scene"]
		)

	var input_action: String = ToolUtils.parse_string_arg(args, "input_action", "shoot")
	if input_action.is_empty():
		input_action = "shoot"
	var key: String = ToolUtils.parse_string_arg(args, "key", "mouse_left")
	if key.is_empty():
		key = "mouse_left"

	var default_aim := "mouse" if space == "2d" else "forward"
	var aim: String = ToolUtils.parse_string_arg(args, "aim", default_aim).to_lower()

	var default_speed := 600.0 if space == "2d" else 24.0
	var default_lifetime := 2.0 if space == "2d" else 3.0
	var default_radius := 6.0 if space == "2d" else 0.15
	var speed: float = max(0.0, ToolUtils.parse_float_arg(args, "speed", default_speed))
	var damage: int = ToolUtils.parse_int_arg(args, "damage", 1)
	var lifetime: float = max(0.05, ToolUtils.parse_float_arg(args, "lifetime", default_lifetime))
	var cooldown: float = max(0.0, ToolUtils.parse_float_arg(args, "cooldown", 0.25))
	var radius: float = max(0.001, ToolUtils.parse_float_arg(args, "radius", default_radius))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var target_group: String = ToolUtils.parse_string_arg(args, "target_group", "enemies")
	if target_group.is_empty():
		target_group = "enemies"
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# ── Write the two shared scripts (once, unless overwrite) ──
	var suffix := space
	var projectile_path := directory + "/projectile_%s.gd" % suffix
	var shooter_script_path := directory + "/shooter_%s.gd" % suffix
	var projectile_src: String = PROJECTILE_2D_SRC if space == "2d" else PROJECTILE_3D_SRC
	var shooter_src: String = SHOOTER_2D_SRC if space == "2d" else SHOOTER_3D_SRC
	# Point the shooter's preload at the real projectile path (directory is configurable).
	shooter_src = shooter_src.replace(_PROJ_TOKEN, projectile_path)

	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, dir_err])

	for pair in [[projectile_path, projectile_src], [shooter_script_path, shooter_src]]:
		var path: String = pair[0]
		var existed := FileAccess.file_exists(path)
		if not existed or overwrite:
			var werr := _write_file(path, pair[1])
			if werr != "":
				return ToolUtils.error(werr)
			if not existed:
				SessionTracker.mark_created(path)

	# Import both so load()/preload() resolve immediately.
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(projectile_path)
		fs.update_file(shooter_script_path)

	# ── Build the Shooter child node ──
	var shooter: Node = Node2D.new() if space == "2d" else Node3D.new()
	shooter.name = node_name
	parent.add_child(shooter)
	shooter.owner = root

	var shooter_script = load(shooter_script_path)
	if not (shooter_script is Script):
		return ToolUtils.error("Wrote shooter script but could not load it from '%s'" % shooter_script_path)
	shooter.set_script(shooter_script)
	shooter.set("input_action", input_action)
	shooter.set("aim", aim)
	shooter.set("speed", speed)
	shooter.set("damage", damage)
	shooter.set("lifetime", lifetime)
	shooter.set("cooldown", cooldown)
	shooter.set("projectile_radius", radius)
	shooter.set("projectile_color", color)
	shooter.set("target_group", target_group)

	# ── Register the fire action ──
	var action_added := _ensure_fire_action(input_action, key)
	if action_added:
		ProjectSettings.save()

	return ToolUtils.success(
		"Added a %s shooter on '%s'. This tool is ATOMIC: it wrote (once) two VETTED scripts — a projectile that "
		% [space.to_upper(), parent.name]
		+ "flies along its aim, damages the first '%s'-group node it overlaps (calling take_damage(amount) if present, " % target_group
		+ "else freeing it), and self-frees on hit or after lifetime; and a Shooter child node that spawns one on the "
		+ "'%s' action (bound to %s), aimed '%s'. Place more turrets by calling again or duplicate_node the Shooter. " % [input_action, key, aim]
		+ "Pair with create_health on the targets for real HP, and create_particles_%s for an impact burst. Then call save_scene." % space,
		{
			"created_scripts": [projectile_path, shooter_script_path],
			"shooter": ToolUtils.node_relative_path(shooter),
			"input_action": input_action,
			"key": key,
			"space": space,
			"aim": aim,
			"group": _GROUP,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# Recursive search of the edited scene for a node in `group` (the live tree's
# get_first_node_in_group doesn't see the edited scene, which isn't in /root).
func _find_in_group(node: Node, group: String) -> Node:
	if node.is_in_group(group):
		return node
	for child in node.get_children():
		var found := _find_in_group(child, group)
		if found != null:
			return found
	return null


# Define (or leave intact) the fire action, binding either a mouse button
# ("mouse_left"/"mouse_right"/"mouse_middle") or a physical keyboard key. Returns
# true when a new setting was written (so the caller saves ProjectSettings).
func _ensure_fire_action(action_name: String, key_name: String) -> bool:
	var setting := "input/" + action_name
	if ProjectSettings.has_setting(setting):
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		return false

	var ev: InputEvent = _make_event(key_name)
	if ev == null:
		return false
	ProjectSettings.set_setting(setting, {"deadzone": 0.5, "events": [ev]})
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	else:
		InputMap.action_erase_events(action_name)
	InputMap.action_add_event(action_name, ev)
	return true


# Build the input event for a binding name: a mouse button for "mouse_*", else a
# physical-key event (so WASD-style bindings survive non-QWERTY layouts).
func _make_event(key_name: String) -> InputEvent:
	match key_name.to_lower():
		"mouse_left":
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			return e
		"mouse_right":
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_RIGHT
			return e
		"mouse_middle":
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_MIDDLE
			return e
		_:
			var keycode := OS.find_keycode_from_string(key_name)
			if keycode == KEY_NONE:
				return null
			var k := InputEventKey.new()
			k.physical_keycode = keycode
			return k


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
