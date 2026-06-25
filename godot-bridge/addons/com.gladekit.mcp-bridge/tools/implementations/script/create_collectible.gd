extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a COLLECTIBLE (a coin / pickup / star) to the scene in ONE call: an Area2D
# that, when the player touches it, adds to the score via the GameManager and
# removes itself. With create_game_manager and create_hazard it completes the
# core 2D gameplay loop — a reason to move through the level and a way to win.
#
# It wires into the manager through the "game_manager" group exactly the way the
# manager documents (no hard reference needed), and degrades gracefully if no
# manager exists yet (it simply disappears on pickup). Call create_game_manager
# first so the score actually counts.
#
# Why a template tool: the pickup itself is easy to get subtly wrong — forgetting
# area_entered (so an Area2D player never triggers it), reacting to non-player
# bodies, or freeing mid-signal. The vetted script below handles all three.
#
# The vetted script is written ONCE per project (collectible.gd) and reused by
# every call, so you can place many pickups: call this repeatedly, or place one
# and duplicate_game_object the rest. Each node carries its own `value`.
#
# Args:
#   directory:   res:// folder for the generated script. Default "res://scripts".
#   name:        node name. Default "Collectible".
#   parent_path: scene-relative parent. Default: the scene root.
#   position:    "x,y" placement. Default 0,0.
#   value:       score added on pickup. Default 1.
#   radius:      collision + placeholder radius in px. Default 12.
#   color:       placeholder fill color. Default gold.
#   overwrite:   regenerate the shared script if it exists. Default false.
#
# Response payload:
#   created_script, node (path), group ("collectibles"), value

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "collectibles"
const _DEFAULT_COLOR := Color(0.98, 0.82, 0.25)  # gold

# ── Vetted script: Collectible (Area2D pickup) ─────────────────────────────
const COLLECTIBLE_SRC := """extends Area2D

# A pickup. When the player (anything in the \"player\" group) overlaps it, it
# adds to the score through the GameManager and removes itself. Handles BOTH a
# body player (CharacterBody2D) and an area player, only reacts to the player,
# and frees safely after scoring.

@export var value: int = 1


func _ready() -> void:
	add_to_group(\"collectibles\")
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)


func _on_body_entered(body: Node) -> void:
	_try_collect(body)


func _on_area_entered(area: Node) -> void:
	_try_collect(area)


func _try_collect(node: Node) -> void:
	if not node.is_in_group(\"player\"):
		return
	var gm := get_tree().get_first_node_in_group(\"game_manager\")
	if gm != null and gm.has_method(\"add_score\"):
		gm.add_score(value)
	queue_free()
"""


func _init() -> void:
	tool_name = "create_collectible"
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
			"create_collectible is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root)",
				"3D collectibles aren't supported by this tool yet",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Collectible")
	if node_name.is_empty():
		node_name = "Collectible"
	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)
	var value: int = max(0, ToolUtils.parse_int_arg(args, "value", 1))
	var radius: float = max(1.0, ToolUtils.parse_float_arg(args, "radius", 12.0))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# Write the shared script once; reuse it on every subsequent call (many
	# collectibles per level). Only regenerate when explicitly asked.
	var script_path := directory + "/collectible.gd"
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, COLLECTIBLE_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		if not script_exists:
			SessionTracker.mark_created(script_path)

	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the Area2D + collision + placeholder visual ──
	var area := Area2D.new()
	area.name = node_name
	parent.add_child(area)
	area.owner = root
	area.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	var col := CollisionShape2D.new()
	col.name = "CollisionShape2D"
	var circle := CircleShape2D.new()
	circle.radius = radius
	col.shape = circle
	area.add_child(col)
	col.owner = root

	# A spinnable diamond placeholder so the pickup is visible without art.
	var vis := Polygon2D.new()
	vis.name = "Placeholder"
	vis.polygon = PackedVector2Array([
		Vector2(0, -radius),
		Vector2(radius, 0),
		Vector2(0, radius),
		Vector2(-radius, 0),
	])
	vis.color = color
	area.add_child(vis)
	vis.owner = root

	var collectible_script = load(script_path)
	if not (collectible_script is Script):
		return ToolUtils.error("Wrote collectible script but could not load it from '%s'" % script_path)
	area.set_script(collectible_script)
	var dropped := ToolUtils.apply_script_properties(area, {
		"value": value,
	})
	var warning := "" if dropped.is_empty() else " " + ToolUtils.reused_script_warning(dropped, script_path)
	if not area.is_in_group(_GROUP):
		area.add_to_group(_GROUP, true)

	return ToolUtils.success(
		"Added a collectible worth %d. This tool is ATOMIC: it wrote (once) a VETTED Area2D pickup script and "
		% value
		+ "built the node with a collision shape + a visible placeholder. It calls the GameManager's add_score on "
		+ "player touch and frees itself — so create_game_manager FIRST or the pickup vanishes without scoring. "
		+ "Place more by calling this again (the script is reused) or by duplicate_game_object. Replace the "
		+ "Placeholder Polygon2D with a Sprite2D/AnimatedSprite2D for real art. Then call save_scene."
		+ warning,
		{
			"created_script": script_path,
			"node": ToolUtils.node_relative_path(area),
			"group": _GROUP,
			"value": value,
			"dropped_properties": dropped,
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
