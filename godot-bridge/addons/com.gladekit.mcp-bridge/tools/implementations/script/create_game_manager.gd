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
#   - score_to_win > 0 auto-wins when score reaches it (e.g. "collect 10 coins");
#     0 disables auto-win so you call win() yourself from a goal/flag.
#   - on game over / win the HUD shows a banner; pressing R reloads the scene.
#
# Args:
#   directory:       res:// folder for the generated script. Default "res://scripts".
#   manager_name:    name for the manager node. Default "GameManager".
#   starting_lives:  initial lives (exported on the script too). Default 3.
#   score_to_win:    score that auto-wins; 0 = manual win only. Default 0.
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
# Score that triggers an automatic win. 0 disables it — call win() yourself from
# a goal/flag instead.
@export var score_to_win: int = 0

@onready var _score_label: Label = get_node_or_null(\"HUD/ScoreLabel\")
@onready var _lives_label: Label = get_node_or_null(\"HUD/LivesLabel\")
@onready var _message_label: Label = get_node_or_null(\"HUD/MessageLabel\")

var score: int = 0
var lives: int = 0
var _finished: bool = false            # locks scoring once the game has ended
var _player_start: Vector2 = Vector2.ZERO
var _player_start_captured: bool = false


func _ready() -> void:
	add_to_group(\"game_manager\")
	lives = starting_lives
	_capture_player_start()
	if _message_label != null:
		_message_label.visible = false
	_refresh_hud()


# Add to the score. Auto-wins when score_to_win is set and reached.
func add_score(amount: int = 1) -> void:
	if _finished:
		return
	score += amount
	score_changed.emit(score)
	_refresh_hud()
	if score_to_win > 0 and score >= score_to_win:
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

	var script_path := directory + "/game_manager.gd"
	if FileAccess.file_exists(script_path) and not overwrite:
		return ToolUtils.error_with_solutions(
			"Refused to overwrite existing script '%s'" % script_path,
			[
				"Pass overwrite=true to regenerate the vetted script",
				"Pass a different 'directory' so the existing file isn't clobbered",
			]
		)

	var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if make_err != OK and make_err != ERR_ALREADY_EXISTS:
		return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
	var werr := _write_file(script_path, MANAGER_SRC)
	if werr != "":
		return ToolUtils.error(werr)
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
	manager.set("starting_lives", starting_lives)
	manager.set("score_to_win", score_to_win)
	if not manager.is_in_group(_GROUP):
		manager.add_to_group(_GROUP, true)

	var win_note := (
		"auto-win at score %d" % score_to_win if score_to_win > 0 else "manual win (call win() from a goal)"
	)
	return ToolUtils.success(
		"Created a GameManager — the hub that makes this a winnable/losable game. This tool is ATOMIC: it wrote a "
		+ "VETTED, known-good GDScript VERBATIM and built the node plus a HUD (CanvasLayer with score + lives "
		+ "readouts and a centered win/lose banner). DO NOT hand-write game-state code for this — the template "
		+ "already handles HUD sync, respawn (zeroes player velocity), and locking the score after the game ends. "
		+ "Lives=%d, %s. Gameplay code reaches it via the 'game_manager' group: " % [starting_lives, win_note]
		+ "add_score(1) on a pickup, lose_life() on a hit, win() at a goal. Add pickups with create_collectible and "
		+ "dangers with create_hazard (both already call this manager). Your remaining step is to call save_scene.",
		{
			"created_script": script_path,
			"manager": ToolUtils.node_relative_path(manager),
			"group": _GROUP,
			"starting_lives": starting_lives,
			"score_to_win": score_to_win,
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
