extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Attaches a reusable "juice" component to a Node2D/Control in ONE call by
# writing a VETTED tween script verbatim and parenting it under the target.
# Juice — a scale pop on a pickup, a hit flash on damage, a fade on spawn — is
# what makes a prototype feel responsive instead of static. It's the per-object
# counterpart to create_screen_shake (which kicks the whole camera).
#
# Why a child Node (not a script on the target itself): the target usually has
# its own script (a Sprite2D, a coin running collectible.gd, the player). The
# Juice node tweens the PARENT's transform/modulate from the outside, so it adds
# feel without clobbering or re-parenting anything — the same discipline the
# moving-platform PathMover uses. The script declares NO class_name (addressed
# purely by node path), so it can't collide with a user's own `Juice` class.
#
# Why a template tool: hand-written tween juice is reliably mediocre. The common
# misses are (a) a linear scale punch that reads as a glitch instead of a pop
# (no overshoot/elastic settle), (b) flashes/fades that stomp the node's resting
# modulate because the base value wasn't cached, (c) Control nodes that scale
# from their top-left because pivot_offset was never centered, and (d) idle
# loops that drift the node off its start position. The vetted script caches the
# parent's resting scale/modulate/position at _ready, centers a Control's pivot,
# and uses BACK/ELASTIC easing so a pop actually pops.
#
# Trigger the juice from the parent's script (or any reference to it):
#     $Juice.pop()                # squash-stretch punch (collect, land, click)
#     $Juice.flash(Color.RED)     # quick color flash (took damage)
#     $Juice.fade_out(0.3)        # fade to transparent, emits faded_out (despawn)
#
# Like collectible/hazard, the shared juice.gd is written ONCE and reused on
# repeat calls (attach Juice to many nodes without rewriting the file).
#
# Args:
#   target_path: scene-relative path of the Node2D or Control to juice (required).
#   name:        name of the Juice child node. Default "Juice".
#   idle:        ambient loop — "none" (default), "pulse" (gentle scale breathe,
#                great for pickups), or "bob" (vertical hover, Node2D only).
#   spawn:       on-ready effect — "pop_in" (default, scales up from nothing) or
#                "none".
#   directory:   res:// folder for the generated script. Default "res://scripts".
#   overwrite:   rewrite juice.gd even if it already exists. Default false
#                (reuses the existing shared script rather than erroring).
#
# Response payload:
#   created_script, juice_node (path), target (path), idle, spawn,
#   reused_script (bool), triggers (example calls to drive the juice).

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _IDLE_MODES := ["none", "pulse", "bob"]
const _SPAWN_MODES := ["none", "pop_in"]

# ── Vetted script: reusable per-object tween juice ─────────────────────────
const JUICE_SRC := """extends Node

# Reusable \"juice\" component. Attach as a CHILD of any Node2D or Control and
# call its methods from gameplay code to make that node feel alive — a scale pop
# on a pickup, a hit flash on damage, a fade on spawn/despawn. It tweens the
# PARENT's transform/modulate, so it never clobbers the parent's own script.
#
# Trigger from the parent's script (or any reference):
#     $Juice.pop()                 # squash-stretch punch (collect, land, click)
#     $Juice.flash(Color.RED)      # quick color flash (took damage)
#     $Juice.fade_out(0.3)         # fade out, emits faded_out (then queue_free)

signal faded_out

@export_enum(\"none\", \"pulse\", \"bob\") var idle: String = \"none\"
@export_enum(\"none\", \"pop_in\") var spawn: String = \"pop_in\"
@export var pop_strength: float = 0.35

var _ci: CanvasItem
var _base_scale: Vector2 = Vector2.ONE
var _base_modulate: Color = Color(1, 1, 1, 1)
var _base_pos: Vector2 = Vector2.ZERO
var _idle_tween: Tween


func _ready() -> void:
	var parent = get_parent()
	if not (parent is CanvasItem):
		push_warning(\"Juice: parent is not a Node2D/Control; nothing to animate.\")
		return
	_ci = parent
	_base_scale = _ci.scale
	_base_modulate = _ci.modulate
	if _ci is Node2D:
		_base_pos = (_ci as Node2D).position
	# A Control scales from its top-left unless its pivot is centered.
	if _ci is Control:
		var c := _ci as Control
		if c.pivot_offset == Vector2.ZERO:
			c.pivot_offset = c.size * 0.5
	if spawn == \"pop_in\":
		pop_in()
	match idle:
		\"pulse\":
			_start_pulse()
		\"bob\":
			_start_bob()


# Squash-stretch punch: a quick overshoot then an elastic settle back to rest.
# Use on a pickup, a successful action, a landing, a button press.
func pop(strength: float = -1.0, duration: float = 0.28) -> void:
	if _ci == null:
		return
	var s: float = pop_strength if strength < 0.0 else strength
	var t := create_tween()
	_ci.scale = _base_scale
	t.tween_property(_ci, \"scale\", _base_scale * (1.0 + s), duration * 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(_ci, \"scale\", _base_scale, duration * 0.65).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# Scale up from nothing. Called automatically when spawn == \"pop_in\".
func pop_in(duration: float = 0.3) -> void:
	if _ci == null:
		return
	var t := create_tween()
	_ci.scale = Vector2.ZERO
	t.tween_property(_ci, \"scale\", _base_scale, duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Flash to a color and ease back to the resting tint. Use on taking damage
# (Color.RED) or a positive ping. Caches the base tint so it always settles back.
func flash(color: Color = Color(1, 1, 1, 1), duration: float = 0.14) -> void:
	if _ci == null:
		return
	var t := create_tween()
	_ci.modulate = color
	t.tween_property(_ci, \"modulate\", _base_modulate, duration)


func fade_in(duration: float = 0.3) -> void:
	if _ci == null:
		return
	var t := create_tween()
	_ci.modulate = Color(_base_modulate.r, _base_modulate.g, _base_modulate.b, 0.0)
	t.tween_property(_ci, \"modulate:a\", _base_modulate.a, duration)


# Fade to transparent, then emit faded_out so the caller can queue_free the node.
func fade_out(duration: float = 0.3) -> void:
	if _ci == null:
		faded_out.emit()
		return
	var t := create_tween()
	t.tween_property(_ci, \"modulate:a\", 0.0, duration)
	t.finished.connect(func(): faded_out.emit())


func _start_pulse() -> void:
	if _ci == null:
		return
	_idle_tween = create_tween().set_loops()
	_idle_tween.tween_property(_ci, \"scale\", _base_scale * 1.08, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.tween_property(_ci, \"scale\", _base_scale, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _start_bob() -> void:
	if not (_ci is Node2D):
		return
	var n := _ci as Node2D
	_idle_tween = create_tween().set_loops()
	_idle_tween.tween_property(n, \"position\", _base_pos + Vector2(0, -6), 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_idle_tween.tween_property(n, \"position\", _base_pos, 0.7).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
"""


func _init() -> void:
	tool_name = "create_juice"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new 2D scene"]
		)

	var missing := ToolUtils.require_string(args, "target_path")
	if not missing.is_empty():
		return ToolUtils.error(missing)

	# Resolve + validate the target. The Juice node tweens the parent's
	# transform/modulate, so the parent must be a CanvasItem (Node2D or Control).
	var target_path: String = ToolUtils.parse_string_arg(args, "target_path")
	var target: Node = ToolUtils.find_node_by_path(target_path)
	if target == null:
		return ToolUtils.error_with_solutions(
			"Target '%s' not found in the edited scene" % target_path,
			["Check the path with get_scene_tree", "Create the node first (e.g. create_sprite_2d / create_node)"]
		)
	if not (target is CanvasItem):
		return ToolUtils.error_with_solutions(
			"Node '%s' is a %s — juice needs a Node2D or Control to animate" % [target_path, target.get_class()],
			["Pass a Sprite2D / AnimatedSprite2D / Node2D / Control path", "Juice tweens scale + modulate, which only CanvasItems have"]
		)

	# Validate the enum-ish args up front so a typo fails loudly, not silently.
	var idle: String = ToolUtils.parse_string_arg(args, "idle", "none").strip_edges().to_lower()
	if idle.is_empty():
		idle = "none"
	if not _IDLE_MODES.has(idle):
		return ToolUtils.error_with_solutions(
			"Unknown idle '%s'" % idle, ["Use one of: %s" % ", ".join(_IDLE_MODES)]
		)
	var spawn: String = ToolUtils.parse_string_arg(args, "spawn", "pop_in").strip_edges().to_lower()
	if spawn.is_empty():
		spawn = "pop_in"
	if not _SPAWN_MODES.has(spawn):
		return ToolUtils.error_with_solutions(
			"Unknown spawn '%s'" % spawn, ["Use one of: %s" % ", ".join(_SPAWN_MODES)]
		)

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "Juice")
	if node_name.strip_edges().is_empty():
		node_name = "Juice"
	if target.has_node(NodePath(node_name)):
		return ToolUtils.error_with_solutions(
			"Target '%s' already has a child named '%s'" % [target_path, node_name],
			["Pass a different 'name'", "Or remove the existing juice node first"]
		)

	# Resolve the script directory + path.
	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")
	var script_path := directory + "/juice.gd"

	# Reuse the shared juice.gd if it already exists (attach to many nodes without
	# rewriting); only (re)write it when missing or overwrite is requested.
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)
	var reused := FileAccess.file_exists(script_path) and not overwrite
	if not reused:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, JUICE_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		SessionTracker.mark_created(script_path)
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.update_file(script_path)

	var juice_script = load(script_path)
	if not (juice_script is Script):
		return ToolUtils.error("Wrote script but could not load it from '%s'" % script_path)

	# Attach a plain Node carrying the juice script under the target.
	var juice_node := Node.new()
	juice_node.name = node_name
	target.add_child(juice_node)
	juice_node.owner = root
	juice_node.set_script(juice_script)
	var dropped := ToolUtils.apply_script_properties(juice_node, {
		"idle": idle,
		"spawn": spawn,
	})
	var warning := "" if dropped.is_empty() else " " + ToolUtils.reused_script_warning(dropped, script_path)

	var juice_rel := ToolUtils.node_relative_path(juice_node)
	var triggers := [
		"$%s.pop()" % node_name,
		"$%s.flash(Color.RED)" % node_name,
		"$%s.fade_out(0.3)" % node_name,
	]

	return ToolUtils.success(
		"Attached a juice component to '%s'. This tool is ATOMIC: it wrote (or reused) a VETTED tween "
		% target.name
		+ "script and parented a '%s' node under the target. DO NOT hand-write tween juice — the template " % node_name
		+ "already caches the resting scale/modulate, centers a Control's pivot, and uses BACK/ELASTIC easing "
		+ "so a pop actually pops. Drive the feel from the target's script (or any reference): call %s on a "
		% triggers[0]
		+ "pickup/land/click, flash(Color.RED) on a hit, fade_out(0.3) to despawn. "
		+ ("(idle='%s' loop + " % idle if idle != "none" else "(")
		+ "spawn='%s' both fire automatically at runtime.) Then call save_scene." % spawn
		+ warning,
		{
			"created_script": script_path,
			"reused_script": reused,
			"juice_node": juice_rel,
			"target": ToolUtils.node_relative_path(target),
			"idle": idle,
			"spawn": spawn,
			"triggers": triggers,
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
