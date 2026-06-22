extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Adds a screen-space HEALTH BAR in ONE call — the visible half of the health
# system. create_health gives an entity hit points and emits damaged/healed/died;
# this builds a HUD bar that FOLLOWS those signals so the player can SEE their HP
# drain and refill. Without it, health is invisible — you lose HP with no feedback.
#
# It writes a vetted script and builds a CanvasLayer overlay (screen-space, above
# the game) holding a styled ProgressBar with a "current / max" readout. The script
# finds a Health component at runtime — by default the one on the "player"-group
# node (set target_group to track a boss, a vehicle, etc.) — seeds the bar from its
# max_health, then connects to `damaged`/`healed` so the bar updates live. If the
# tracked entity has no Health child yet, the bar hides itself (call create_health
# first). Works in 2D and 3D scenes (a CanvasLayer is dimension-agnostic).
#
# Not one-per-scene: a player bar plus a boss bar (different target_group) is a
# valid setup, so call it again for each tracked entity.
#
# Args:
#   target_group: group whose member's "Health" child to track. Default "player".
#   name:         node name. Default "HealthBar".
#   position:     "top_left" (default), "top_center", "top_right", "bottom_left",
#                 "bottom_right" — screen corner the bar anchors to.
#   width/height: bar size in px. Default 240 x 22.
#   color:        fill color. Default health red. The track behind is dark.
#   show_text:    overlay a "current / max" number on the bar. Default true.
#   directory:    res:// folder for the generated script. Default "res://scripts".
#   overwrite:    overwrite the generated script if it exists. Default false.
#
# Response payload:
#   created_script, health_bar (node path), group ("health_bar"), target_group

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")
const SessionTracker = preload("res://addons/com.gladekit.mcp-bridge/bridge/session_tracker.gd")

const _GROUP := "health_bar"
const _DEFAULT_COLOR := Color(0.85, 0.2, 0.2)  # health red
const _VALID_POSITIONS := ["top_left", "top_center", "top_right", "bottom_left", "bottom_right"]

# ── Vetted script: HealthBar (follows a Health component's signals) ──────────
const HEALTH_BAR_SRC := """extends CanvasLayer

# A HUD health bar. On ready it finds a Health component (create_health) — the one
# on the first `target_group` member — reads its max, fills the bar, then follows
# the component's `damaged`/`healed` signals so the bar tracks HP live. Hides
# itself if the tracked entity has no Health child.

# Group whose member's \"Health\" child this bar tracks (\"player\", \"boss\", ...).
@export var target_group: String = \"player\"

@onready var _bar: ProgressBar = get_node_or_null(\"Bar\")
@onready var _label: Label = get_node_or_null(\"Bar/Label\")


func _ready() -> void:
	add_to_group(\"health_bar\")
	if _bar == null:
		return
	var health := _find_health()
	if health == null:
		_bar.visible = false
		return
	var maximum: int = int(health.max_health)
	_bar.min_value = 0.0
	_bar.max_value = float(maximum)
	_bar.value = float(maximum)  # full at start; the signals refine it on the first hit
	_set_text(maximum, maximum)
	if health.has_signal(\"damaged\"):
		health.damaged.connect(_on_health_changed)
	if health.has_signal(\"healed\"):
		health.healed.connect(_on_health_changed)


func _on_health_changed(_amount: int, current: int, maximum: int) -> void:
	_bar.max_value = float(maximum)
	_bar.value = float(current)
	_set_text(current, maximum)


func _set_text(current: int, maximum: int) -> void:
	if _label != null:
		_label.text = \"%d / %d\" % [current, maximum]


# The first target_group member's Health child, or null. Runs at runtime when the
# scene is live, so get_first_node_in_group works (unlike in the editor).
func _find_health() -> Node:
	var owner_node := get_tree().get_first_node_in_group(target_group)
	if owner_node == null:
		return null
	return owner_node.get_node_or_null(\"Health\")
"""


func _init() -> void:
	tool_name = "create_health_bar"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a scene first"]
		)

	var directory: String = ToolUtils.parse_string_arg(args, "directory", "res://scripts")
	if directory.is_empty():
		directory = "res://scripts"
	directory = directory.rstrip("/")
	if not directory.begins_with("res://"):
		directory = "res://" + directory.lstrip("/")

	var node_name: String = ToolUtils.parse_string_arg(args, "name", "HealthBar")
	if node_name.is_empty():
		node_name = "HealthBar"

	var target_group: String = ToolUtils.parse_string_arg(args, "target_group", "player")
	if target_group.is_empty():
		target_group = "player"

	var position: String = ToolUtils.parse_string_arg(args, "position", "top_left").to_lower()
	if not _VALID_POSITIONS.has(position):
		return ToolUtils.error_with_solutions(
			"Unknown position '%s'" % position,
			["Use one of: %s" % ", ".join(_VALID_POSITIONS)]
		)

	var width: float = maxf(16.0, ToolUtils.parse_float_arg(args, "width", 240.0))
	var height: float = maxf(8.0, ToolUtils.parse_float_arg(args, "height", 22.0))
	var color: Color = ToolUtils.parse_color_arg(args.get("color"), _DEFAULT_COLOR) if args.has("color") else _DEFAULT_COLOR
	var show_text: bool = ToolUtils.parse_bool_arg(args, "show_text", true)
	var overwrite: bool = ToolUtils.parse_bool_arg(args, "overwrite", false)

	var script_path := directory + "/health_bar.gd"
	if FileAccess.file_exists(script_path) and not overwrite:
		# Reuse the existing vetted script (this tool may be called per entity);
		# only refuse if the caller explicitly wants a rewrite they can't get.
		pass
	else:
		var make_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if make_err != OK and make_err != ERR_ALREADY_EXISTS:
			return ToolUtils.error("Failed to create directory '%s' (error %d)" % [directory, make_err])
		var werr := _write_file(script_path, HEALTH_BAR_SRC)
		if werr != "":
			return ToolUtils.error(werr)
		SessionTracker.mark_created(script_path)
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(script_path)

	# ── Build the overlay node tree ──
	var layer := CanvasLayer.new()
	layer.name = node_name
	layer.layer = 5  # above gameplay, below a pause overlay (layer 10)
	root.add_child(layer)
	layer.owner = root

	var bar := ProgressBar.new()
	bar.name = "Bar"
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 100.0
	_place(bar, position, width, height, 16.0)
	# Dark track + colored fill via theme styleboxes.
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.09, 0.09, 0.11, 0.85)
	bg.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	layer.add_child(bar)
	bar.owner = root

	if show_text:
		var label := Label.new()
		label.name = "Label"
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 14)
		label.text = "HP"
		bar.add_child(label)
		label.owner = root

	var bar_script = load(script_path)
	if not (bar_script is Script):
		layer.free()
		return ToolUtils.error("Wrote health-bar script but could not load it from '%s'" % script_path)
	layer.set_script(bar_script)
	layer.set("target_group", target_group)
	if not layer.is_in_group(_GROUP):
		layer.add_to_group(_GROUP, true)

	return ToolUtils.success(
		"Added a health bar (%s) tracking the '%s' group. This tool is ATOMIC: it wrote a VETTED HealthBar script "
		% [position, target_group]
		+ "VERBATIM and built a CanvasLayer overlay with a styled ProgressBar + 'current / max' readout. At runtime it "
		+ "finds the '%s' member's Health child (create_health), seeds the bar from max_health, and follows its " % target_group
		+ "damaged/healed signals so the bar tracks HP live. Add create_health to that entity FIRST or the bar hides "
		+ "itself. Place a boss bar by calling again with a different target_group. Then call save_scene.",
		{
			"created_script": script_path,
			"health_bar": ToolUtils.node_relative_path(layer),
			"group": _GROUP,
			"target_group": target_group,
		}
	)


# ── Helpers ─────────────────────────────────────────────────────────────────

# Anchor a fixed-size Control to a screen corner with a margin, using offset-based
# placement (deterministic — no need for the runtime viewport size).
func _place(c: Control, pos: String, w: float, h: float, m: float) -> void:
	match pos:
		"top_right":
			c.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			c.offset_left = -m - w
			c.offset_right = -m
			c.offset_top = m
			c.offset_bottom = m + h
		"top_center":
			c.set_anchors_preset(Control.PRESET_CENTER_TOP)
			c.offset_left = -w * 0.5
			c.offset_right = w * 0.5
			c.offset_top = m
			c.offset_bottom = m + h
		"bottom_left":
			c.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
			c.offset_left = m
			c.offset_right = m + w
			c.offset_top = -m - h
			c.offset_bottom = -m
		"bottom_right":
			c.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
			c.offset_left = -m - w
			c.offset_right = -m
			c.offset_top = -m - h
			c.offset_bottom = -m
		_:  # top_left
			c.set_anchors_preset(Control.PRESET_TOP_LEFT)
			c.offset_left = m
			c.offset_right = m + w
			c.offset_top = m
			c.offset_bottom = m + h


func _write_file(file_path: String, content: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return "Could not open '%s' for writing (FileAccess error %d)" % [file_path, FileAccess.get_open_error()]
	f.store_string(content)
	f.close()
	return ""
