extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a HAZARD (spikes, lava, an enemy's hurtbox) to the scene in ONE call: an
# Area2D that costs the player a life via the GameManager on contact (which then
# respawns the player, or ends the game at zero lives). With create_game_manager
# and create_collectible it completes the core 2D gameplay loop — the threat that
# makes the level something you can lose.
#
# It wires into the manager through the "game_manager" group (no hard reference)
# and degrades gracefully if no manager exists yet (contact simply does nothing).
# Call create_game_manager first so a hit actually costs a life.
#
# Why a template tool: the contact handler is easy to get subtly wrong — missing
# area_entered, reacting to non-player nodes, or double-counting a hit. The vetted
# script handles all three; the manager owns the respawn/game-over decision.
#
# The vetted script is written ONCE per project (hazard.gd) and reused by every
# call, so you can place many: call this repeatedly, or place one and
# duplicate_game_object the rest.
#
# Args:
#   directory:   res:// folder for the generated script. Default "res://scripts".
#   name:        node name. Default "Hazard".
#   parent_path: scene-relative parent. Default: the scene root.
#   position:    "x,y" placement. Default 0,0.
#   size:        "w,h" collision + placeholder size in px. Default 48,16.
#   color:       placeholder fill color. Default danger red.
#   overwrite:   regenerate the shared script if it exists. Default false.
#
# Response payload:
#   created_script, node (path), group ("hazards")

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "hazards"
const _DEFAULT_SIZE := Vector2(48, 16)
const _DEFAULT_COLOR := Color(0.85, 0.22, 0.22)  # danger red

# ── Vetted script: Hazard (Area2D damage volume) ───────────────────────────
const HAZARD_SRC := """extends Area2D

# A hazard. When the player (anything in the \"player\" group) overlaps it, it
# costs a life through the GameManager, which respawns the player or ends the
# game. Handles BOTH a body player (CharacterBody2D) and an area player, and only
# reacts to the player.


func _ready() -> void:
	add_to_group(\"hazards\")
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)


func _on_body_entered(body: Node) -> void:
	_try_hit(body)


func _on_area_entered(area: Node) -> void:
	_try_hit(area)


func _try_hit(node: Node) -> void:
	if not node.is_in_group(\"player\"):
		return
	var gm := get_tree().get_first_node_in_group(\"game_manager\")
	if gm != null and gm.has_method(\"lose_life\"):
		gm.lose_life()
"""


func _init() -> void:
	tool_name = "create_hazard"
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
			"create_hazard is 2D-only, but the open scene's root is 3D (Node3D)",
			[
				"Open or create a 2D scene (Node2D root)",
				"3D hazards aren't supported by this tool yet",
			]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Hazard")
	if node_name.is_empty():
		node_name = "Hazard"
	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)
	var size: Vector2 = ToolUtils.parse_vector2_arg(args, "size", _DEFAULT_SIZE)
	size = Vector2(max(1.0, size.x), max(1.0, size.y))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	# Write the shared script once; reuse it on every subsequent call.
	var script_path := directory + "/hazard.gd"
	var script_exists := FileAccess.file_exists(script_path)
	if not script_exists or overwrite:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, HAZARD_SRC)
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
	var rect := RectangleShape2D.new()
	rect.size = size
	col.shape = rect
	area.add_child(col)
	col.owner = root

	# A red bar placeholder so the hazard reads as danger without art.
	var vis := Polygon2D.new()
	vis.name = "Placeholder"
	var half := size * 0.5
	vis.polygon = PackedVector2Array([
		Vector2(-half.x, -half.y),
		Vector2(half.x, -half.y),
		Vector2(half.x, half.y),
		Vector2(-half.x, half.y),
	])
	vis.color = color
	area.add_child(vis)
	vis.owner = root

	var hazard_script = load(script_path)
	if not (hazard_script is Script):
		return ToolUtils.error("Wrote hazard script but could not load it from '%s'" % script_path)
	area.set_script(hazard_script)
	if not area.is_in_group(_GROUP):
		area.add_to_group(_GROUP, true)

	return ToolUtils.success(
		"Added a hazard. This tool is ATOMIC: it wrote (once) a VETTED Area2D damage-volume script and built the "
		+ "node with a collision shape + a red placeholder. On player touch it calls the GameManager's lose_life "
		+ "(which respawns the player or ends the game) — so create_game_manager FIRST or contact does nothing. "
		+ "Place more by calling this again (the script is reused) or by duplicate_game_object. Replace the "
		+ "Placeholder Polygon2D with real art, and pair it with create_screen_shake for a hit that feels like "
		+ "one. Then call save_scene.",
		{
			"created_script": script_path,
			"node": ToolUtils.node_relative_path(area),
			"group": _GROUP,
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
