extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Drops the HUB of a simple 2D game into the scene in ONE call: a GameManager
# node that tracks SCORE and LIVES, handles RESPAWN and WIN/LOSE, and drives an
# on-screen HUD (score + lives readouts and a centered win/lose banner). It is
# the piece that turns a playable character into an actual game — something you
# can win or lose — and it is the counterpart the collectible and hazard tools
# (create_collectible / create_hazard) wire into.
#
# Why a template tool: the game-state hub is small but easy to get subtly wrong —
# missed initial HUD sync, scoring that keeps counting after the game ends,
# respawn that forgets to zero the player's velocity, a HUD that breaks depending
# on which node is _ready first. The vetted script below avoids all of those.
#
# How gameplay code talks to it (same group convention as screen shake): the
# manager joins the "game_manager" group, so anything can reach it without a
# hard reference:
#     get_tree().get_first_node_in_group("game_manager").add_score(1)
#     get_tree().get_first_node_in_group("game_manager").lose_life()
#     get_tree().get_first_node_in_group("game_manager").win()
# The collectible/hazard templates already emit exactly these calls.
#
# Win/lose model:
#   - lives start at `starting_lives`. lose_life() decrements; while lives remain
#     it RESPAWNS the player (the first node in the "player" group) at its start
#     position with zeroed velocity; at zero lives it fires game_over.
#   - score_to_win > 0 auto-wins when score reaches it (e.g. "collect 10 coins").
#   - score_to_win == 0 (default) auto-wins when ALL collectibles in the level
#     have been picked up (collect-them-all). A level with no collectibles stays
#     a manual win — call win() yourself from a goal/flag.
#   - on game over / win the HUD shows a banner; pressing R reloads the scene.
#
# Args:
#   directory:       res:// folder for the generated script. Default "res://scripts".
#   manager_name:    name for the manager node. Default "GameManager".
#   starting_lives:  initial lives (exported on the script too). Default 3.
#   score_to_win:    score that auto-wins; 0 = win by collecting all collectibles
#                    (or manual win() if the level has none). Default 0.
#   overwrite:       overwrite the generated script if it exists. Default false.
#
# Response payload:
#   created_script, manager (node path), group ("game_manager"),
#   triggers (the one-liners gameplay code calls)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "game_manager"

# ── Vetted script: GameManager (score / lives / respawn / win / lose + HUD) ──
const MANAGER_SRC := """extends Node

# The hub of a simple 2D game: tracks SCORE and LIVES, RESPAWNS the player on a
# non-fatal hit, ends the game on win/lose, and drives the HUD child. Lives in
# the \"game_manager\" group so gameplay code reaches it without a reference:
#     get_tree().get_first_node_in_group(\"game_manager\").add_score(1)
#     get_tree().get_first_node_in_group(\"game_manager\").lose_life()
#     get_tree().get_first_node_in_group(\"game_manager\").win()

signal score_changed(score)
signal lives_changed(lives)
signal game_won
signal game_over

@export var starting_lives: int = 3
# Score that triggers an automatic win. 0 means \"no score target\": the game is
# instead won by collecting every collectible in the level (or call win()
# yourself from a goal/flag). A level with no collectibles stays a manual win.
@export var score_to_win: int = 0

@onready var _score_label: Label = get_node_or_null(\"HUD/ScoreLabel\")
@onready var _lives_label: Label = get_node_or_null(\"HUD/LivesLabel\")
@onready var _message_label: Label = get_node_or_null(\"HUD/MessageLabel\")

var score: int = 0
var lives: int = 0
var _finished: bool = false            # locks scoring once the game has ended
var _player_start: Vector2 = Vector2.ZERO
var _player_start_captured: bool = false
# True when the level shipped with collectibles — gates the collect-all auto-win
# so a score-only game (no pickups) does not auto-win on its first point.
var _had_collectibles: bool = false


func _ready() -> void:
	add_to_group(\"game_manager\")
	lives = starting_lives
	_capture_player_start()
	if _message_label != null:
		_message_label.visible = false
	_refresh_hud()
	# Detect collect-to-win eligibility after every sibling has entered the tree
	# (collectibles add themselves to their group in their own _ready), so the
	# check is order-independent.
	_detect_collectibles.call_deferred()


# Add to the score. Wins when score_to_win is reached, or — when no explicit
# target is set — when every collectible in the level has been picked up.
func add_score(amount: int = 1) -> void:
	if _finished:
		return
	score += amount
	score_changed.emit(score)
	_refresh_hud()
	if score_to_win > 0:
		if score >= score_to_win:
			win()
	else:
		# Collect-all win. Deferred so the pickup that just called add_score (and
		# queue_free()s itself right after) is already flagged for deletion and
		# excluded from the remaining count below.
		_check_collect_all_win.call_deferred()


func _detect_collectibles() -> void:
	_had_collectibles = not get_tree().get_nodes_in_group(\"collectibles\").is_empty()


# Collect-them-all win: when no explicit score target is set, the game is won
# once no un-collected collectible remains. Only fires for levels that actually
# had collectibles (see _had_collectibles), so a score-only game never trips it.
func _check_collect_all_win() -> void:
	if _finished or not _had_collectibles:
		return
	for c in get_tree().get_nodes_in_group(\"collectibles\"):
		if is_instance_valid(c) and not c.is_queued_for_deletion():
			return
	win()


# Cost a life. Respawns while lives remain; ends the game at zero.
func lose_life(amount: int = 1) -> void:
	if _finished:
		return
	lives = max(lives - amount, 0)
	lives_changed.emit(lives)
	_refresh_hud()
	if lives <= 0:
		_end_game(false)
	else:
		respawn()


# Return the player to where it started, velocity cleared.
func respawn() -> void:
	var player := _player()
	if player == null:
		return
	if not _player_start_captured:
		_capture_player_start()
	player.global_position = _player_start
	if player is CharacterBody2D:
		player.velocity = Vector2.ZERO


func win() -> void:
	if _finished:
		return
	_end_game(true)


func reset_game() -> void:
	get_tree().reload_current_scene()


# Remember the player's start position so respawn can return it there.
func _capture_player_start() -> void:
	var player := _player()
	if player != null:
		_player_start = player.global_position
		_player_start_captured = true


func _end_game(won: bool) -> void:
	_finished = true
	if won:
		game_won.emit()
	else:
		game_over.emit()
	if _message_label != null:
		_message_label.text = \"You Win!\" if won else \"Game Over\\nPress R to restart\"
		_message_label.visible = true


func _refresh_hud() -> void:
	if _score_label != null:
		_score_label.text = \"Score: %d\" % score
	if _lives_label != null:
		_lives_label.text = \"Lives: %d\" % lives


func _player() -> Node2D:
	return get_tree().get_first_node_in_group(\"player\") as Node2D


# Press R to restart once the game has ended (won or lost).
func _unhandled_input(event: InputEvent) -> void:
	if not _finished:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		get_viewport().set_input_as_handled()
		reset_game()
"""


func _init() -> void:
	tool_name = "create_game_manager"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)
	# 2D-only: the HUD + respawn logic targets a 2D game (CharacterBody2D player,
	# Vector2 positions). A 3D scene needs a different manager.
	if root is Node3D:
		return ToolUtils.error_with_solutions(
			"create_game_manager is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root) for a 2D game",
				"A 3D game-state manager isn't supported by this tool yet",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var manager_name: String = ToolUtils.parse_string_arg(args, "manager_name", "GameManager")
	if manager_name.is_empty():
		manager_name = "GameManager"
	var starting_lives: int = max(0, ToolUtils.parse_int_arg(args, "starting_lives", 3))
	var score_to_win: int = max(0, ToolUtils.parse_int_arg(args, "score_to_win", 0))
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# A node already in the "game_manager" group means a manager exists — refuse
	# to add a second (two HUDs / two score counters fight each other). Walk the
	# edited subtree directly; the editor's edited scene isn't part of get_tree().
	var existing := _find_in_group(root, _GROUP)
	if existing != null:
		return ToolUtils.error_with_solutions(
			"A GameManager already exists in this scene (node '%s')" % existing.name,
			[
				"Reuse the existing manager — gameplay reaches it via the 'game_manager' group",
				"Delete the existing manager first if you want a fresh one",
			]
		)

	# The manager script is a shared, vetted template — not a user asset. When it
	# already exists (the project built a game before), REUSE it instead of
	# aborting: the per-scene group guard above already prevents a duplicate
	# manager, so a fresh scene with no manager should still get one wired to the
	# existing script. Only (re)write the file when absent or overwrite=true, so a
	# user's manual edits survive. Mirrors create_collectible / create_hazard.
	var script_path := directory + "/game_manager.gd"
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, MANAGER_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the manager node + HUD ──
	var manager := Node.new()
	manager.name = manager_name
	root.add_child(manager)
	manager.owner = root
	_build_hud(manager, root)

	var manager_script = load(script_path)
	if not (manager_script is Script):
		return ToolUtils.error("Wrote manager but could not load it from '%s'" % script_path)
	manager.set_script(manager_script)
	var dropped := ToolUtils.apply_script_properties(manager, {
		"starting_lives": starting_lives,
		"score_to_win": score_to_win,
	})
	var warning := "" if dropped.is_empty() else " " + ToolUtils.reused_script_warning(dropped, script_path)
	if not manager.is_in_group(_GROUP):
		manager.add_to_group(_GROUP, true)

	var win_note := (
		"auto-win at score %d" % score_to_win if score_to_win > 0 else "win by collecting all collectibles (or call win() from a goal)"
	)
	return ToolUtils.success(
		"Created a GameManager — the hub that makes this a winnable/losable game. This tool is ATOMIC: it wrote a "
		+ "VETTED, known-good GDScript VERBATIM and built the node plus a HUD (CanvasLayer with score + lives "
		+ "readouts and a centered win/lose banner). DO NOT hand-write game-state code for this — the template "
		+ "already handles HUD sync, respawn (zeroes player velocity), and locking the score after the game ends. "
		+ "Lives=%d, %s. Gameplay code reaches it via the 'game_manager' group: " % [starting_lives, win_note]
		+ "add_score(1) on a pickup, lose_life() on a hit, win() at a goal. Add pickups with create_collectible and "
		+ "dangers with create_hazard (both already call this manager). Your remaining step is to call save_scene."
		+ warning,
		{
			"created_script": script_path,
			"manager": ToolUtils.node_relative_path(manager),
			"group": _GROUP,
			"starting_lives": starting_lives,
			"score_to_win": score_to_win,
			"dropped_properties": dropped,
			"triggers": {
				"add_score": "get_tree().get_first_node_in_group(\"game_manager\").add_score(1)",
				"lose_life": "get_tree().get_first_node_in_group(\"game_manager\").lose_life()",
				"win": "get_tree().get_first_node_in_group(\"game_manager\").win()",
			},
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# Build the HUD: a CanvasLayer (screen-space, unaffected by the game camera) with
# a top-left score readout, a top-right lives readout, and a hidden centered
# banner the manager reveals on win/lose. Names must match the manager script's
# get_node_or_null("HUD/...") lookups.
func _build_hud(manager: Node, owner_root: Node) -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	manager.add_child(hud)
	hud.owner = owner_root

	var score_label := _make_label("ScoreLabel", "Score: 0")
	score_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	score_label.position = Vector2(16, 12)
	hud.add_child(score_label)
	score_label.owner = owner_root

	var lives_label := _make_label("LivesLabel", "Lives: 3")
	lives_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	lives_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lives_label.offset_left = -160
	lives_label.offset_top = 12
	lives_label.offset_right = -16
	hud.add_child(lives_label)
	lives_label.owner = owner_root

	var message_label := _make_label("MessageLabel", "")
	message_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	message_label.add_theme_font_size_override("font_size", 48)
	message_label.visible = false
	hud.add_child(message_label)
	message_label.owner = owner_root


func _make_label(node_name: String, text: String) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.add_theme_font_size_override("font_size", 24)
	return label


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""


# Group lookup that works before the edited scene is inside the live SceneTree
# (the editor's edited scene isn't part of get_tree()). Walks the node subtree.
func _find_in_group(root: Node, group: String) -> Node:
	if root.is_in_group(group):
		return root
	for child in root.get_children():
		var found := _find_in_group(child, group)
		if found != null:
			return found
	return null
