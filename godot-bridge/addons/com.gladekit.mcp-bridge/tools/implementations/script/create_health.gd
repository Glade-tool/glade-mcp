extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Gives a node HIT POINTS in ONE call — the other half of the combat loop. The
# scene can already SHOOT (create_projectile) and has things to shoot AT
# (create_enemy_2d/3d), but every target died in one hit because nothing tracked
# health. This adds a reusable Health COMPONENT: a child node named "Health" that
# holds current/max HP, takes damage with optional invulnerability frames, heals,
# emits `damaged` / `healed` / `died`, and (by default) frees its owner on death.
#
# Why a CHILD node (named "Health"): a Godot node holds ONE script, and the target
# usually already has one (an enemy's AI, the player's controller). So Health is
# added as a CHILD — it works on ANY node regardless of its existing script, and
# it's pure logic (extends Node), so the SAME component works in 2D and 3D scenes.
#
# How it composes with create_projectile: a projectile, on hitting a target, looks
# for a child named "Health" and calls its `take_damage(amount)` — so adding Health
# to an enemy turns the projectile's one-shot-destroy into real HP damage (N hits
# to kill). With no Health child the projectile still destroys on hit, so the two
# tools are independent but click together. Other damage sources wire in the same
# way: `$Health.take_damage(n)` or `get_node("Health").take_damage(n)`.
#
# Reacting to health: connect the signals to gameplay/UI —
#   `died`  → play a death effect, add score, or end the game.
#   `damaged(amount, current, maximum)` → flash the sprite, update a health bar.
# `free_owner_on_death=true` (default) frees the parent entity when HP hits 0 — the
# right default for enemies and destructibles. For the PLAYER, set it false and
# handle `died` yourself (respawn / game-over via the GameManager).
#
# Args:
#   target_path:         node to attach Health to. Default: the "player"-group node
#                        if one exists (so "give my player health" just works), else
#                        this is required.
#   name:                component node name. Default "Health" — KEEP this for the
#                        projectile auto-lookup to find it.
#   max_health:          maximum (and starting) hit points. Default 3.
#   invuln_seconds:      invulnerability window after taking a hit (i-frames).
#                        Default 0 (every hit lands). Set ~0.5 for a player.
#   free_owner_on_death: free the parent entity when HP reaches 0. Default true
#                        (enemies/destructibles). Set false for the player.
#   directory:           res:// folder for the generated script. Default "res://scripts".
#   overwrite:           regenerate the shared health script if it exists. Default false.
#
# Response payload:
#   created_script, health_node (path), target (path), max_health, signals

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

# ── Vetted script: Health (reusable HP component) ────────────────────────────
const HEALTH_SRC := """extends Node

# A reusable health / damage component. Add it as a CHILD named \"Health\" of any
# entity that should have hit points. Damage sources call take_damage(amount); it
# clamps HP, honors optional invulnerability frames, emits signals, and (by
# default) frees its owner — the parent — on death. Pure logic, so the same
# component works in 2D and 3D scenes.

signal damaged(amount: int, current: int, maximum: int)
signal healed(amount: int, current: int, maximum: int)
signal died

@export var max_health: int = 3
# Seconds of invulnerability after a hit lands (i-frames). 0 = every hit counts.
@export var invuln_seconds: float = 0.0
# Free the parent entity when HP reaches 0. True for enemies/destructibles; set
# false for the player and handle `died` yourself (respawn / game over).
@export var free_owner_on_death: bool = true

var _health: int = 0
var _invuln_left: float = 0.0


func _ready() -> void:
	_health = max_health


func _process(delta: float) -> void:
	if _invuln_left > 0.0:
		_invuln_left -= delta


func take_damage(amount: int = 1) -> void:
	if _health <= 0 or amount <= 0 or _invuln_left > 0.0:
		return
	_health = maxi(0, _health - amount)
	damaged.emit(amount, _health, max_health)
	if _health <= 0:
		died.emit()
		if free_owner_on_death:
			var owner_node := get_parent()
			if owner_node != null:
				owner_node.queue_free()
	else:
		_invuln_left = invuln_seconds


func heal(amount: int = 1) -> void:
	if _health <= 0 or amount <= 0:
		return
	_health = mini(max_health, _health + amount)
	healed.emit(amount, _health, max_health)


func get_health() -> int:
	return _health


func is_alive() -> bool:
	return _health > 0


# Resize the pool (e.g. a max-HP upgrade). refill=true tops up to the new max;
# otherwise current HP is only clamped down if it now exceeds the max.
func set_max_health(value: int, refill: bool = false) -> void:
	max_health = maxi(1, value)
	if refill or _health > max_health:
		_health = max_health
"""


func _init() -> void:
	tool_name = "create_health"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new scene"]
		)

	# Resolve the target: an explicit path, else the player, else ask for one.
	var target_path: String = ToolUtils.parse_string_arg(args, "target_path")
	var target: Node
	if not target_path.is_empty():
		target = ToolUtils.find_node_by_path(target_path)
		if target == null:
			return ToolUtils.error("target_path '%s' not found" % target_path)
	else:
		target = _find_in_group(root, "player")
		if target == null:
			return ToolUtils.error_with_solutions(
				"No target_path given and no node is in the 'player' group",
				[
					"Pass target_path to the node that should have health (an enemy, a destructible, the player)",
					"Or put the player in the 'player' group (create_2d_controller / create_third_person_controller do this)",
				]
			)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Health")
	if node_name.is_empty():
		node_name = "Health"

	var max_health: int = maxi(1, ToolUtils.parse_int_arg(args, "max_health", 3))
	var invuln_seconds: float = maxf(0.0, ToolUtils.parse_float_arg(args, "invuln_seconds", 0.0))
	var free_owner_on_death: bool = ToolUtils.parse_bool_arg(args, "free_owner_on_death", true)
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# Guard against attaching a second Health to the same target.
	if target.get_node_or_null(node_name) != null:
		return ToolUtils.error_with_solutions(
			"'%s' already has a child named '%s'" % [target.name, node_name],
			[
				"That target already has a Health component",
				"Pass a different target_path, or set its max_health in the inspector",
			]
		)

	# Write the shared script once; reuse it on every subsequent call.
	var script_path := directory + "/health.gd"
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, dir_err])
		var werr := _write_file(script_path, HEALTH_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Attach the Health child ──
	var health := Node.new()
	health.name = node_name
	target.add_child(health)
	health.owner = root

	var health_script = load(script_path)
	if not (health_script is Script):
		return ToolUtils.error("Wrote health script but could not load it from '%s'" % script_path)
	health.set_script(health_script)
	var dropped := ToolUtils.apply_script_properties(health, {
		"max_health": max_health,
		"invuln_seconds": invuln_seconds,
		"free_owner_on_death": free_owner_on_death,
	})
	var warning := "" if dropped.is_empty() else " " + ToolUtils.reused_script_warning(dropped, script_path)

	return ToolUtils.success(
		"Added a Health component (%d HP) to '%s'. This tool is ATOMIC: it wrote (once) a VETTED, reusable "
		% [max_health, target.name]
		+ "Health script and attached it as a child named '%s'. Damage sources call $%s.take_damage(amount); " % [node_name, node_name]
		+ "a create_projectile projectile finds this child automatically, so the target now takes %d hits instead of " % max_health
		+ "dying in one. It emits 'damaged'/'healed'/'died' — connect 'died' to a death effect / score / game-over and "
		+ "'damaged' to a health bar. free_owner_on_death=%s: " % str(free_owner_on_death)
		+ ("the parent is freed at 0 HP (right for enemies/destructibles). " if free_owner_on_death else "the parent is NOT auto-freed; handle 'died' yourself (respawn / game over). ")
		+ "For the PLAYER, pass free_owner_on_death=false and invuln_seconds (~0.5) for i-frames. Then call save_scene."
		+ warning,
		{
			"created_script": script_path,
			"health_node": ToolUtils.node_relative_path(health),
			"target": ToolUtils.node_relative_path(target),
			"max_health": max_health,
			"signals": ["damaged", "healed", "died"],
			"dropped_properties": dropped,
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


func _write_file(path: String, content: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
