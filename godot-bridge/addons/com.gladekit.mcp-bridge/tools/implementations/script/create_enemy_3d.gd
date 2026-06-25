extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a moving ENEMY to a 3D scene in ONE call: a CharacterBody3D that walks the
# level under gravity and threatens the player. It is the 3D analog of
# create_enemy_2d — same verbs, same "enemies"/"game_manager"/"player" group
# wiring — for projects whose open scene has a Node3D root. Use create_enemy_2d
# for 2D scenes; this tool refuses to run in one (and vice-versa).
#
# Two contact outcomes, decided by where the player hits it (the classic 3D-
# platformer stomp, à la Super Mario 64):
#   - STOMP (player above + falling onto its head): the enemy dies (queue_free),
#     adds `score_value` to the score via the GameManager, and bounces the player
#     up — so jumping on enemies feels right.
#   - SIDE / BELOW touch: costs the player a life via the GameManager's lose_life.
#
# It wires into the manager through the "game_manager" group (no hard reference)
# and degrades gracefully if no manager exists: contact just does nothing. NOTE:
# there is no 3D game-manager scaffolder yet (create_game_manager is 2D-only), so
# in a pure-3D scene scoring/lives won't function until a 3D manager exists or you
# add a node to the "game_manager" group exposing add_score/lose_life. The enemy's
# MOVEMENT + stomp/contact logic works regardless.
#
# Styles (mirror create_enemy_2d):
#   "patrol"  (default) — walks back and forth along X, turning at walls AND at
#     ledges (a downward ray probe ahead) so it never strolls off a platform.
#   "chaser"  — homes in on the player on the XZ plane whenever the player is
#     within `aggro_range`, otherwise eases to a stop. Sees through walls.
#   "guard"   — patrols UNTIL it actually SEES the player: within `vision_range`,
#     inside a forward vision cone (`vision_cone_degrees`), AND with a clear line
#     of sight (a wall between them hides the player). Then it gives chase, and
#     `give_up_time` seconds after losing sight it forgets the player and resumes
#     patrolling. The classic alert-and-pursue guard, with real perception.
#
# Why a template tool: a good enemy is fiddly — gravity + move_and_slide, turning
# at ledges (a raycast probe, not just walls), a stomp test that distinguishes
# "landed on its head" from "ran into its side" (and 3D flips the sign of "falling"
# and "above" vs 2D), and a vision cone + occlusion raycast. The vetted script
# handles all of it.
#
# The vetted script is written ONCE per project (enemy_3d.gd) and reused by every
# call, so you can place many: call this repeatedly, or place one and
# duplicate_node the rest. Each node carries its own exported speed / score / vision.
#
# Args:
#   directory:    res:// folder for the generated script. Default "res://scripts".
#   name:         node name. Default "Enemy".
#   parent_path:  scene-relative parent. Default: the scene root.
#   position:     "x,y,z" placement. Default 0,0,0.
#   style:        "patrol" (default), "chaser", or "guard".
#   pathfinding:  "direct" (default) | "navmesh". "navmesh" gives chaser/guard a
#                 NavigationAgent3D child so they path AROUND obstacles instead of
#                 walking straight at the player — needs a baked NavigationRegion3D
#                 (call bake_navigation_mesh). Ignored for patrol (it never pursues).
#   speed:        move speed in m/s. Default 2.5.
#   score_value:  score added when the player stomps it. Default 1.
#   color:        placeholder mesh color. Default menacing purple.
#   overwrite:    regenerate the shared script if it exists. Default false.
#
# Response payload:
#   created_script, node (path), group ("enemies"), style

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "enemies"
const _RADIUS := 0.4
const _HEIGHT := 1.6
const _DEFAULT_COLOR := Color(0.55, 0.22, 0.65)  # menacing purple
const _VALID_STYLES := ["patrol", "chaser", "guard"]
const _VALID_PATHFINDING := ["direct", "navmesh"]

# ── Vetted script: Enemy3D (moving, stompable threat) ───────────────────────
const ENEMY_SRC := """extends CharacterBody3D

# A moving 3D enemy. It walks under gravity and threatens the player two ways,
# decided by HOW the player touches it:
#   - Stomp (player drops onto its head): it dies, scores, and bounces the player.
#   - Side/below touch: it costs the player a life via the GameManager.
# Wires into the manager through the \"game_manager\" group; if no manager exists
# yet, contact simply does nothing. Reacts only to nodes in the \"player\" group.

@export_enum(\"patrol\", \"chaser\", \"guard\") var style: String = \"patrol\"
@export var speed: float = 2.5
# Score awarded to the GameManager when the player stomps this enemy.
@export var score_value: int = 1
# Chaser only: how close (m) the player must be before the enemy gives chase.
# (The chaser \"sees\" through walls — for line-of-sight perception use style=guard.)
@export var aggro_range: float = 12.0
# Guard only: how far (m) it can see.
@export var vision_range: float = 16.0
# Guard only: half-angle (degrees) of the forward vision cone. The player is only
# spotted when within this many degrees of the way the guard is facing.
@export var vision_cone_degrees: float = 60.0
# Guard only: seconds after losing sight of the player before the guard gives up
# the chase and returns to patrolling.
@export var give_up_time: float = 2.5
# Upward velocity given to the player on a successful stomp (m/s, positive = up).
# Player must be a CharacterBody3D (has a `velocity`).
@export var stomp_bounce: float = 5.0

var _gravity: float = float(ProjectSettings.get_setting(\"physics/3d/default_gravity\", 9.8))
var _dir: int = -1  # patrol facing along X: -1 toward -X, +1 toward +X
var _facing: Vector3 = Vector3(-1.0, 0.0, 0.0)  # logical horizontal facing (vision cone)
var _dead: bool = false
var _alerted: bool = false  # guard: currently aware of / chasing the player
var _lost_sight_for: float = 0.0  # guard: seconds since the player was last seen
var _agent: NavigationAgent3D = null  # set in _ready; when present, pursuit follows the navmesh


func _ready() -> void:
	add_to_group(\"enemies\")
	var hurtbox := get_node_or_null(\"Hurtbox\")
	if hurtbox != null:
		hurtbox.body_entered.connect(_on_touch)
		hurtbox.area_entered.connect(_on_touch)
	# When the scene placed a NavigationAgent3D under us, pursuit follows the baked
	# navmesh AROUND obstacles instead of a straight line. No child → straight line.
	_agent = get_node_or_null(\"NavigationAgent3D\")


func _physics_process(delta: float) -> void:
	if _dead:
		return

	# Gravity so the enemy rests on the ground / floor.
	if not is_on_floor():
		velocity.y -= _gravity * delta

	if style == \"chaser\":
		_move_toward_player(aggro_range)
	elif style == \"guard\":
		_update_alert(delta)
		if _alerted:
			_move_toward_player(INF)
		else:
			_patrol()
	else:
		_patrol()

	move_and_slide()

	# Patrolling enemies turn at a wall or before walking off a ledge. Pursuing
	# enemies steer straight at the player, so they don't use _dir.
	var patrolling: bool = style == \"patrol\" or (style == \"guard\" and not _alerted)
	if patrolling and is_on_floor() and (is_on_wall() or not _ground_ahead()):
		_dir *= -1


func _patrol() -> void:
	velocity.x = _dir * speed
	velocity.z = 0.0
	_facing = Vector3(_dir, 0.0, 0.0)


# Pursue the player on the XZ plane when within max_range; ease to a stop
# otherwise. INF range = always pursue (used by an alerted guard). With a
# NavigationAgent3D child the pursuit follows a baked navmesh path AROUND
# obstacles; without one it makes a straight line (the through-walls chaser).
# _facing is updated either way so the guard's vision cone keeps working.
func _move_toward_player(max_range: float) -> void:
	var player := _player()
	if player == null:
		_brake()
		return
	var to: Vector3 = player.global_position - global_position
	to.y = 0.0
	var dist: float = to.length()
	if dist > max_range or dist <= 0.001:
		_brake()
		return
	if _agent != null:
		_pursue_navmesh(player)
	else:
		var d: Vector3 = to / dist
		_facing = d
		velocity.x = d.x * speed
		velocity.z = d.z * speed


# Follow the navmesh toward the player. The target is refreshed every frame (the
# player moves), then we step toward the next path point. Needs a baked
# NavigationRegion3D in the scene; with none the agent reports the path finished
# immediately and the enemy simply brakes — a missing bake fails safe.
func _pursue_navmesh(player: Node3D) -> void:
	_agent.target_position = player.global_position
	if _agent.is_navigation_finished():
		_brake()
		return
	var to: Vector3 = _agent.get_next_path_position() - global_position
	to.y = 0.0
	var dist: float = to.length()
	if dist <= 0.001:
		_brake()
		return
	var d: Vector3 = to / dist
	_facing = d
	velocity.x = d.x * speed
	velocity.z = d.z * speed


func _brake() -> void:
	velocity.x = move_toward(velocity.x, 0.0, speed)
	velocity.z = move_toward(velocity.z, 0.0, speed)


# Guard alertness: become/stay alerted while the player is in sight; once sight is
# lost, count up and give up the chase after give_up_time so the guard returns to
# its patrol instead of homing forever.
func _update_alert(delta: float) -> void:
	if _can_see_player():
		_alerted = true
		_lost_sight_for = 0.0
	elif _alerted:
		_lost_sight_for += delta
		if _lost_sight_for >= give_up_time:
			_alerted = false


# Guard perception: the player is seen when within vision_range, inside the forward
# vision cone (vision_cone_degrees off the facing direction on the XZ plane), AND
# with a clear line of sight — a wall between the two hides the player.
func _can_see_player() -> bool:
	var player := _player()
	if player == null:
		return false
	var to: Vector3 = player.global_position - global_position
	var dist: float = to.length()
	if dist > vision_range or dist < 0.001:
		return false
	# Forward cone on the XZ plane. Vector3.angle_to is unsigned in [0, PI].
	var flat := Vector3(to.x, 0.0, to.z)
	var facing_flat := Vector3(_facing.x, 0.0, _facing.z)
	if flat.length() < 0.001 or facing_flat.length() < 0.001:
		return false
	if facing_flat.angle_to(flat) > deg_to_rad(vision_cone_degrees):
		return false
	# Line of sight: raycast eye-to-eye against solid bodies (not areas), so walls
	# block it. Visible if the ray reaches the player unobstructed.
	var space := get_world_3d().direct_space_state
	var eye := global_position + Vector3.UP * 0.8
	var target := player.global_position + Vector3.UP * 0.8
	var query := PhysicsRayQueryParameters3D.create(eye, target)
	query.exclude = [get_rid()]  # exclude is Array[RID]; skip our own body
	var hit := space.intersect_ray(query)
	return hit.is_empty() or hit.get(\"collider\") == player


# True if there is solid ground just ahead in the current patrol direction. A short
# ray cast down from a point in front of the feet — keeps a patroller on its
# platform instead of marching into the void.
func _ground_ahead() -> bool:
	var space := get_world_3d().direct_space_state
	var ahead := global_position + Vector3(_dir, 0.0, 0.0) * 0.8
	var query := PhysicsRayQueryParameters3D.create(ahead, ahead + Vector3.DOWN * 1.5)
	query.exclude = [get_rid()]
	return not space.intersect_ray(query).is_empty()


func _on_touch(node: Node) -> void:
	if _dead or not node.is_in_group(\"player\"):
		return
	if _is_stomp(node):
		_die_by_stomp(node)
	else:
		var gm := get_tree().get_first_node_in_group(\"game_manager\")
		if gm != null and gm.has_method(\"lose_life\"):
			gm.lose_life()


# A stomp = the player is above this enemy AND moving downward onto it. In 3D, up
# is +Y, so \"falling\" is velocity.y < 0 (the opposite of 2D's y-down convention).
func _is_stomp(player: Node) -> bool:
	var above: bool = player.global_position.y > global_position.y + 0.4
	var falling: bool = (\"velocity\" in player) and player.velocity.y < 0.0
	return above and falling


func _die_by_stomp(player: Node) -> void:
	_dead = true
	if \"velocity\" in player:
		player.velocity.y = stomp_bounce  # positive = up in 3D
	var gm := get_tree().get_first_node_in_group(\"game_manager\")
	if gm != null and gm.has_method(\"add_score\") and score_value > 0:
		gm.add_score(score_value)
	queue_free()


func _player() -> Node3D:
	var p := get_tree().get_first_node_in_group(\"player\")
	return p if p is Node3D else null
"""


func _init() -> void:
	tool_name = "create_enemy_3d"
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
			"create_enemy_3d is 3D-only, but the open scene's root is 2D (Node2D)",
			[
				"Use create_enemy_2d for a 2D scene",
				"Open or create a 3D scene (Node3D root) for a 3D enemy",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Enemy")
	if node_name.is_empty():
		node_name = "Enemy"

	var style: String = ToolUtils.parse_string_arg(args, "style", "patrol").to_lower()
	if not _VALID_STYLES.has(style):
		return ToolUtils.error_with_solutions(
			"Unknown style '%s'" % style,
			[
				"Use style='patrol' for an enemy that walks back and forth (turns at walls and ledges)",
				"Use style='chaser' for an enemy that homes in on the player when near",
				"Use style='guard' for an enemy that patrols until it SEES the player (vision cone + line of sight), then gives chase and gives up when it loses sight",
			]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var pathfinding: String = ToolUtils.parse_string_arg(args, "pathfinding", "direct").to_lower()
	if not _VALID_PATHFINDING.has(pathfinding):
		return ToolUtils.error_with_solutions(
			"Unknown pathfinding '%s'" % pathfinding,
			[
				"Use pathfinding='direct' (default) for straight-line pursuit",
				"Use pathfinding='navmesh' so chaser/guard path around obstacles (needs a baked NavigationRegion3D)",
			]
		)
	# patrol never pursues, so a NavigationAgent3D would be inert there.
	var use_navmesh: bool = pathfinding == "navmesh" and style != "patrol"

	var speed: float = max(0.0, ToolUtils.parse_float_arg(args, "speed", 2.5))
	var score_value: int = max(0, ToolUtils.parse_int_arg(args, "score_value", 1))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# Write the shared script once; reuse it on every subsequent call.
	var script_path := directory + "/enemy_3d.gd"
	var script_exists := FileAccess.file_exists(script_path)
	# A navmesh enemy needs the navmesh-aware script. If an OLDER enemy_3d.gd (no
	# NavigationAgent3D support) is already on disk, regenerate it — the upgrade is
	# backward-compatible (straight-line enemies have no agent child, so unaffected).
	var upgraded_script := false
	if use_navmesh and script_exists and not overwrite and not _file_supports_navmesh(script_path):
		overwrite = true
		upgraded_script = true
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, ENEMY_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the CharacterBody3D + body collision + mesh + Hurtbox ──
	var enemy := CharacterBody3D.new()
	enemy.name = node_name
	parent.add_child(enemy)
	enemy.owner = root
	enemy.position = ToolUtils.parse_vector3_arg(args, "position", Vector3.ZERO)

	# Solid body collision: lets the enemy walk the floor and the player collide
	# with it like a moving wall.
	var body_col := CollisionShape3D.new()
	body_col.name = "CollisionShape3D"
	var body_capsule := CapsuleShape3D.new()
	body_capsule.radius = _RADIUS
	body_capsule.height = _HEIGHT
	body_col.shape = body_capsule
	enemy.add_child(body_col)
	body_col.owner = root

	# A purple capsule placeholder so the enemy reads as a threat without art.
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var capmesh := CapsuleMesh.new()
	capmesh.radius = _RADIUS
	capmesh.height = _HEIGHT
	mesh.mesh = capmesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	enemy.add_child(mesh)
	mesh.owner = root

	# Hurtbox: a slightly inflated Area3D that detects the player so we get overlap
	# signals (a CharacterBody3D alone never reports who touched it).
	var hurtbox := Area3D.new()
	hurtbox.name = "Hurtbox"
	enemy.add_child(hurtbox)
	hurtbox.owner = root
	var hurt_col := CollisionShape3D.new()
	hurt_col.name = "CollisionShape3D"
	var hurt_capsule := CapsuleShape3D.new()
	hurt_capsule.radius = _RADIUS + 0.15
	hurt_capsule.height = _HEIGHT + 0.15
	hurt_col.shape = hurt_capsule
	hurtbox.add_child(hurt_col)
	hurt_col.owner = root

	# Navmesh pursuit: a NavigationAgent3D lets chaser/guard path around obstacles.
	# The vetted script auto-detects this child (see _ready) and routes pursuit
	# through it; without it the enemy pursues in a straight line.
	if use_navmesh:
		var agent := NavigationAgent3D.new()
		agent.name = "NavigationAgent3D"
		agent.radius = _RADIUS
		agent.height = _HEIGHT
		agent.path_desired_distance = 0.5
		agent.target_desired_distance = 1.0  # stop ~1m short so it doesn't jitter on the player
		agent.max_speed = speed
		enemy.add_child(agent)
		agent.owner = root

	var enemy_script = load(script_path)
	if not (enemy_script is Script):
		return ToolUtils.error("Wrote enemy script but could not load it from '%s'" % script_path)
	enemy.set_script(enemy_script)
	var dropped := ToolUtils.apply_script_properties(enemy, {
		"style": style,
		"speed": speed,
		"score_value": score_value,
	})
	var warning := "" if dropped.is_empty() else " " + ToolUtils.reused_script_warning(dropped, script_path)
	if not enemy.is_in_group(_GROUP):
		enemy.add_to_group(_GROUP, true)

	var hint := "It patrols back and forth along X, turning at walls and ledges."
	if style == "chaser":
		hint = "It chases the player on the XZ plane whenever they come within aggro_range."
	elif style == "guard":
		hint = (
			"It patrols until it SEES the player (vision cone + clear line of sight, "
			+ "so walls hide the player), then gives chase and gives up give_up_time "
			+ "seconds after losing sight. Tune vision_range/vision_cone_degrees/give_up_time in the inspector."
		)

	var payload := {
		"created_script": script_path,
		"node": ToolUtils.node_relative_path(enemy),
		"group": _GROUP,
		"style": style,
		"pathfinding": "navmesh" if use_navmesh else "direct",
		"dropped_properties": dropped,
	}

	# Navmesh guidance: surface whether the runtime prerequisite (a baked region) is
	# in place, so the full "chase across the navmesh" flow is unambiguous. nav_msg
	# begins with a space when non-empty so it slots after the style hint.
	var nav_msg := ""
	if use_navmesh:
		var navmesh_ready: bool = _scene_has_baked_navmesh(root)
		payload["navigation_agent"] = ToolUtils.node_relative_path(enemy) + "/NavigationAgent3D"
		payload["navmesh_ready"] = navmesh_ready
		nav_msg = " It pursues via a NavigationAgent3D, pathing AROUND obstacles."
		if upgraded_script:
			nav_msg += " (Regenerated enemy_3d.gd to add navmesh support — backward-compatible.)"
		if navmesh_ready:
			nav_msg += " A baked NavigationRegion3D is present, so pathfinding is ready."
		else:
			nav_msg += " IMPORTANT: no baked NavigationRegion3D found yet — call bake_navigation_mesh once the floor geometry exists, or the enemy will stand still when pursuing."
	elif pathfinding == "navmesh" and style == "patrol":
		nav_msg = " NOTE: pathfinding='navmesh' is ignored for style='patrol' (a patroller never pursues) — use style='chaser' or 'guard'."

	return ToolUtils.success(
		"Added a %s 3D enemy. %s" % [style, hint]
		+ nav_msg
		+ " This tool is ATOMIC: it wrote (once) a VETTED CharacterBody3D enemy script and built "
		+ "the node with a capsule collision shape, a placeholder mesh, and a Hurtbox. STOMPING it (dropping onto its "
		+ "head) kills it, adds score_value via the GameManager, and bounces the player; a SIDE touch calls lose_life. "
		+ "NOTE: create_game_manager is 2D-only, so in a pure-3D scene scoring/lives stay inert until a node joins the "
		+ "'game_manager' group exposing add_score/lose_life — the movement + stomp/contact logic works regardless. "
		+ "Place more by calling this again (the script is reused) or by duplicate_node. Replace the Mesh with real "
		+ "art, and ensure the player is in the 'player' group. Then call save_scene."
		+ warning,
		payload
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# True if the on-disk shared script already has navmesh-pursuit support. Used to
# transparently upgrade an older enemy_3d.gd when a navmesh enemy is requested.
func _file_supports_navmesh(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	return text.find("NavigationAgent3D") != -1


# True if the scene already has a NavigationRegion3D whose mesh has been baked
# (polygons > 0) — the runtime prerequisite for navmesh pursuit.
func _scene_has_baked_navmesh(node: Node) -> bool:
	if node is NavigationRegion3D:
		var nm := (node as NavigationRegion3D).navigation_mesh
		if nm != null and nm.get_polygon_count() > 0:
			return true
	for child in node.get_children():
		if _scene_has_baked_navmesh(child):
			return true
	return false

func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
