extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a moving ENEMY (a goomba / patrolling guard / chaser) to the scene in ONE
# call: a CharacterBody2D that walks the level under gravity and threatens the
# player. Unlike create_hazard (a STATIC Area2D damage volume), an enemy MOVES —
# it patrols a platform or chases the player — and it can be DEFEATED by stomping
# on its head, the classic platformer verb. With create_game_manager,
# create_collectible, and create_hazard it rounds out the 2D gameplay loop: the
# thing in the level that moves, hurts you, and can be beaten.
#
# Two contact outcomes, decided by where the player hits it:
#   - STOMP (player above + falling onto its head): the enemy dies (queue_free),
#     adds `score_value` to the score via the GameManager, and bounces the player
#     up — so jumping on enemies feels right.
#   - SIDE / BELOW touch: costs the player a life via the GameManager's lose_life
#     (which respawns the player or ends the game).
#
# It wires into the manager through the "game_manager" group (no hard reference)
# and degrades gracefully if no manager exists yet (contact just does nothing).
# Call create_game_manager first so a stomp scores and a hit actually costs a life.
#
# Styles:
#   "patrol"  (default) — walks back and forth, turning at walls AND at ledges so
#     it never strolls off the platform. The right default for a placed enemy.
#   "chaser"  — homes in on the player's horizontal position whenever the player
#     is within `aggro_range`, otherwise holds still. A simple "sees you and comes
#     for you" threat without pathfinding.
#
# Why a template tool: a good enemy is fiddly — gravity + move_and_slide, turning
# at ledges (a raycast probe, not just walls), and a stomp test that distinguishes
# "landed on its head" from "ran into its side". The vetted script handles all of
# it; the manager owns the score/respawn/game-over decision.
#
# The vetted script is written ONCE per project (enemy_2d.gd) and reused by every
# call, so you can place many: call this repeatedly, or place one and
# duplicate_node the rest. Each node carries its own exported speed / score / aggro.
#
# Args:
#   directory:    res:// folder for the generated script. Default "res://scripts".
#   name:         node name. Default "Enemy".
#   parent_path:  scene-relative parent. Default: the scene root.
#   position:     "x,y" placement. Default 0,0.
#   style:        "patrol" (default) or "chaser".
#   size:         "w,h" body + placeholder size in px. Default 28,32.
#   speed:        horizontal move speed in px/s. Default 70.
#   score_value:  score added when the player stomps it. Default 1.
#   color:        placeholder fill color. Default menacing purple.
#   overwrite:    regenerate the shared script if it exists. Default false.
#
# Response payload:
#   created_script, node (path), group ("enemies"), style

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "enemies"
const _DEFAULT_SIZE := Vector2(28, 32)
const _DEFAULT_COLOR := Color(0.55, 0.22, 0.65)  # menacing purple
const _VALID_STYLES := ["patrol", "chaser"]

# ── Vetted script: Enemy2D (moving, stompable threat) ───────────────────────
const ENEMY_SRC := """extends CharacterBody2D

# A moving enemy. It walks under gravity and threatens the player two ways,
# decided by HOW the player touches it:
#   - Stomp (player drops onto its head): it dies, scores, and bounces the player.
#   - Side/below touch: it costs the player a life via the GameManager.
# Wires into the manager through the \"game_manager\" group; if no manager exists
# yet, contact simply does nothing. Reacts only to nodes in the \"player\" group.

@export_enum(\"patrol\", \"chaser\") var style: String = \"patrol\"
@export var speed: float = 70.0
# Score awarded to the GameManager when the player stomps this enemy.
@export var score_value: int = 1
# Chaser only: how close (px) the player must be before the enemy gives chase.
@export var aggro_range: float = 260.0
# Upward velocity given to the player on a successful stomp, so the bounce feels
# like Mario. Player must be a CharacterBody2D (has a `velocity`).
@export var stomp_bounce: float = 420.0

var _gravity: float = float(ProjectSettings.get_setting(\"physics/2d/default_gravity\", 980.0))
var _dir: int = -1  # current facing: -1 left, +1 right
var _dead: bool = false


func _ready() -> void:
	add_to_group(\"enemies\")
	var hurtbox := get_node_or_null(\"Hurtbox\")
	if hurtbox != null:
		hurtbox.body_entered.connect(_on_touch)
		hurtbox.area_entered.connect(_on_touch)


func _physics_process(delta: float) -> void:
	if _dead:
		return

	# Gravity so the enemy rests on the ground / tilemap.
	if not is_on_floor():
		velocity.y += _gravity * delta

	if style == \"chaser\":
		var player := _player()
		if player != null and absf(player.global_position.x - global_position.x) <= aggro_range:
			_dir = 1 if player.global_position.x > global_position.x else -1
			velocity.x = _dir * speed
		else:
			velocity.x = move_toward(velocity.x, 0.0, speed)
	else:
		velocity.x = _dir * speed

	move_and_slide()

	# Patrol: turn around at a wall, or before walking off a ledge.
	if style == \"patrol\" and is_on_floor():
		if is_on_wall() or not _ground_ahead():
			_dir *= -1
	elif style == \"chaser\" and is_on_wall():
		_dir *= -1

	_face(_dir)


# True if there is solid ground just ahead in the current facing direction. A
# short ray cast down from a point in front of the feet — keeps a patroller on its
# platform instead of marching into the void.
func _ground_ahead() -> bool:
	var space := get_world_2d().direct_space_state
	# Start the probe ahead of the body (clear of our own collision) and cast down.
	var ahead := global_position + Vector2(_dir * 20.0, 0.0)
	var query := PhysicsRayQueryParameters2D.create(ahead, ahead + Vector2(0.0, 40.0))
	query.exclude = [get_rid()]  # exclude is Array[RID]; skip our own body
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


# A stomp = the player is above this enemy AND moving downward onto it. Anything
# else (running into the side, jumping up into it) is a hit on the player.
func _is_stomp(player: Node) -> bool:
	var above: bool = player.global_position.y < global_position.y - 4.0
	var falling: bool = (\"velocity\" in player) and player.velocity.y > 0.0
	return above and falling


func _die_by_stomp(player: Node) -> void:
	_dead = true
	if \"velocity\" in player:
		player.velocity.y = -stomp_bounce
	var gm := get_tree().get_first_node_in_group(\"game_manager\")
	if gm != null and gm.has_method(\"add_score\") and score_value > 0:
		gm.add_score(score_value)
	queue_free()


func _player() -> Node2D:
	var p := get_tree().get_first_node_in_group(\"player\")
	return p if p is Node2D else null


func _face(dir: int) -> void:
	var sprite := get_node_or_null(\"Placeholder\")
	if sprite is Node2D and dir != 0:
		sprite.scale.x = absf(sprite.scale.x) * signf(dir)
"""


func _init() -> void:
	tool_name = "create_enemy_2d"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)
	if root is Node3D:
		return ToolUtils.error_with_solutions(
			"create_enemy_2d is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root)",
				"3D enemies aren't supported by this tool yet",
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
			]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var size: Vector2 = ToolUtils.parse_vector2_arg(args, "size", _DEFAULT_SIZE)
	size = Vector2(max(1.0, size.x), max(1.0, size.y))
	var speed: float = max(0.0, ToolUtils.parse_float_arg(args, "speed", 70.0))
	var score_value: int = max(0, ToolUtils.parse_int_arg(args, "score_value", 1))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# Write the shared script once; reuse it on every subsequent call.
	var script_path := directory + "/enemy_2d.gd"
	var script_exists := FileAccess.file_exists(script_path)
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

	# ── Build the CharacterBody2D + body collision + placeholder + Hurtbox ──
	var enemy := CharacterBody2D.new()
	enemy.name = node_name
	parent.add_child(enemy)
	enemy.owner = root
	enemy.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	var half := size * 0.5

	# Solid body collision: lets the enemy walk the tilemap and the player collide
	# with it like a moving wall.
	var body_col := CollisionShape2D.new()
	body_col.name = "CollisionShape2D"
	var body_rect := RectangleShape2D.new()
	body_rect.size = size
	body_col.shape = body_rect
	enemy.add_child(body_col)
	body_col.owner = root

	# A purple block placeholder so the enemy reads as a threat without art.
	var vis := Polygon2D.new()
	vis.name = "Placeholder"
	vis.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])
	vis.color = color
	enemy.add_child(vis)
	vis.owner = root

	# Hurtbox: a slightly inflated Area2D that detects the player so we get
	# overlap signals (a CharacterBody2D alone never reports who touched it).
	var hurtbox := Area2D.new()
	hurtbox.name = "Hurtbox"
	enemy.add_child(hurtbox)
	hurtbox.owner = root
	var hurt_col := CollisionShape2D.new()
	hurt_col.name = "CollisionShape2D"
	var hurt_rect := RectangleShape2D.new()
	hurt_rect.size = size + Vector2(6, 6)
	hurt_col.shape = hurt_rect
	hurtbox.add_child(hurt_col)
	hurt_col.owner = root

	var enemy_script = load(script_path)
	if not (enemy_script is Script):
		return ToolUtils.error("Wrote enemy script but could not load it from '%s'" % script_path)
	enemy.set_script(enemy_script)
	enemy.set("style", style)
	enemy.set("speed", speed)
	enemy.set("score_value", score_value)
	if not enemy.is_in_group(_GROUP):
		enemy.add_to_group(_GROUP, true)

	var hint := (
		"It patrols back and forth, turning at walls and ledges."
		if style == "patrol"
		else "It chases the player whenever they come within aggro_range."
	)

	return ToolUtils.success(
		"Added a %s enemy. %s This tool is ATOMIC: it wrote (once) a VETTED CharacterBody2D enemy script and built "
		% [style, hint]
		+ "the node with a body collision shape, a placeholder, and a Hurtbox. STOMPING it (jumping onto its head) "
		+ "kills it, adds score_value via the GameManager, and bounces the player; a SIDE touch calls lose_life — so "
		+ "create_game_manager FIRST or contact does nothing. Place more by calling this again (the script is reused) "
		+ "or by duplicate_node. Replace the Placeholder Polygon2D with a Sprite2D/AnimatedSprite2D for real art, and "
		+ "pair it with create_screen_shake for a stomp that feels like one. Then call save_scene.",
		{
			"created_script": script_path,
			"node": ToolUtils.node_relative_path(enemy),
			"group": _GROUP,
			"style": style,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
