extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Creates an AnimatedSprite2D with a ready-to-play SpriteFrames resource built
# from a list of frame textures — the frame-based 2D animation workflow (player
# run cycles, coin spins, explosions). Bundles the node + the SpriteFrames +
# the frames in one call, the way create_physics_body bundles the collision
# shape: an AnimatedSprite2D with no SpriteFrames is a silent no-op, and
# building one by hand is several chained calls an agent routinely botches.
#
# The SpriteFrames is embedded in the scene (a sub-resource), which is the
# normal authoring shape for AnimatedSprite2D — no separate .tres needed.
#
# Two ways to supply frames (pick one):
#   1. `frames` — a list of individual res:// texture paths (one image per frame).
#   2. `spritesheet` — ONE res:// image sliced into a grid by `hframes`/`vframes`
#      (the common "I have run.png laid out as a strip/grid" case). Frames are
#      taken row-major; use `frame_start`/`frame_end` to pick a sub-range.
# If both are given, the spritesheet wins.
#
# Args:
#   frames:      Array<String> | "a.png,b.png" — res:// texture paths, one per
#                         animation frame, in order. Empty is allowed (you get
#                         an empty animation to fill later) but shows nothing.
#   spritesheet: String — res:// path to a grid spritesheet, sliced via
#                         hframes/vframes into AtlasTexture frames.
#   hframes:     int — spritesheet columns. Default: 1.
#   vframes:     int — spritesheet rows. Default: 1.
#   frame_start: int — first grid cell (row-major, 0-based) to include. Default 0.
#   frame_end:   int — last grid cell to include. Default: last cell.
#   animation:   String — animation name. Default: "default".
#   fps:         float  — playback speed in frames/sec. Default: 10.
#   loop:        bool   — loop the animation. Default: true.
#   autoplay:    bool   — start this animation automatically at runtime.
#                         Default: false.
#   name:        String — node name. Default: "AnimatedSprite2D".
#   parent_path: String — scene-relative parent. Default: scene root.
#   position:    "x,y" — initial position in pixels. Default: 0,0.
#   centered:    bool  — centre frames on the node origin. Default: true.
#   modulate:    "r,g,b[,a]" | "#rrggbb[aa]" — tint. Default: white.
#
# Response payload:
#   node_path, type ("AnimatedSprite2D"), animation, frame_count, fps, loop,
#   skipped_frames (paths that failed to load as a Texture2D)

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")


func _init() -> void:
	tool_name = "create_animated_sprite_2d"
	requires_edit_mode = true


func execute(args: Dictionary) -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return ToolUtils.error_with_solutions(
			"No scene is currently open in the editor",
			["Call open_scene with an existing res:// path", "Call create_scene to scaffold a new one"]
		)

	var parent_path: String = ToolUtils.parse_string_arg(args, "parent_path")
	var parent: Node = ToolUtils.find_node_by_path(parent_path) if not parent_path.is_empty() else root
	if parent == null:
		return ToolUtils.error("Parent '%s' not found" % parent_path)

	var anim_name: String = ToolUtils.parse_string_arg(args, "animation", "default")
	if anim_name.is_empty():
		anim_name = "default"
	var fps: float = ToolUtils.parse_float_arg(args, "fps", 10.0)
	var loop: bool = ToolUtils.parse_bool_arg(args, "loop", true)

	var sf := SpriteFrames.new()
	# SpriteFrames ships with a "default" animation. If the caller wants a
	# differently-named one, add it and drop the stock "default" so the
	# resource holds exactly the animation we built.
	if anim_name != "default":
		sf.add_animation(anim_name)
		if sf.has_animation("default"):
			sf.remove_animation("default")
	sf.set_animation_speed(anim_name, fps)
	sf.set_animation_loop(anim_name, loop)

	var frame_count := 0
	var skipped: Array = []
	var sheet_path: String = ToolUtils.parse_path_arg(args, "spritesheet")
	if not sheet_path.is_empty():
		# Spritesheet path: slice one image into a grid of AtlasTexture frames.
		if not ResourceLoader.exists(sheet_path):
			return ToolUtils.error("spritesheet '%s' not found" % sheet_path)
		var sheet = load(sheet_path)
		if not (sheet is Texture2D):
			return ToolUtils.error("spritesheet '%s' did not load as a Texture2D" % sheet_path)
		frame_count = _slice_spritesheet(sf, anim_name, sheet, args)
	else:
		for raw in _frame_paths(args.get("frames")):
			var p: String = _to_res_path(raw)
			if p.is_empty():
				continue
			if not ResourceLoader.exists(p):
				skipped.append(p)
				continue
			var loaded = load(p)
			if not (loaded is Texture2D):
				skipped.append(p)
				continue
			sf.add_frame(anim_name, loaded)
			frame_count += 1

	var node := AnimatedSprite2D.new()
	node.sprite_frames = sf
	node.animation = anim_name
	node.name = ToolUtils.parse_string_arg(args, "name", "AnimatedSprite2D")
	node.centered = ToolUtils.parse_bool_arg(args, "centered", true)
	if ToolUtils.parse_bool_arg(args, "autoplay", false):
		node.autoplay = anim_name
	if args.has("modulate"):
		node.modulate = ToolUtils.parse_color_arg(args.get("modulate"), Color.WHITE)

	parent.add_child(node)
	node.owner = root
	node.position = ToolUtils.parse_vector2_arg(args, "position", Vector2.ZERO)

	var extras := {
		"node_path": ToolUtils.node_relative_path(node),
		"type": "AnimatedSprite2D",
		"animation": anim_name,
		"frame_count": frame_count,
		"fps": fps,
		"loop": loop,
		"skipped_frames": skipped,
	}
	var hint := ToolUtils.dimension_mismatch_note("2d", "this is a 2D animation node — in a 3D scene use AnimationPlayer instead")
	if not hint.is_empty():
		extras["hint"] = hint

	return ToolUtils.success(
		"Created AnimatedSprite2D '%s' (%d frame%s in '%s')" % [node.name, frame_count, "" if frame_count == 1 else "s", anim_name],
		extras
	)


# Slice a grid spritesheet into AtlasTexture frames appended to `sf`'s animation.
# Frames are taken row-major; frame_start/frame_end bound an optional sub-range.
# Returns the number of frames added.
func _slice_spritesheet(sf: SpriteFrames, anim_name: String, sheet: Texture2D, args: Dictionary) -> int:
	var hf: int = max(1, ToolUtils.parse_int_arg(args, "hframes", 1))
	var vf: int = max(1, ToolUtils.parse_int_arg(args, "vframes", 1))
	var total: int = hf * vf
	var fw: int = int(sheet.get_width() / float(hf))
	var fh: int = int(sheet.get_height() / float(vf))
	var start: int = clampi(ToolUtils.parse_int_arg(args, "frame_start", 0), 0, total - 1)
	var end: int = clampi(ToolUtils.parse_int_arg(args, "frame_end", total - 1), start, total - 1)
	var added := 0
	for i in range(start, end + 1):
		var cx: int = i % hf
		var cy: int = i / hf  # integer division → row
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2(cx * fw, cy * fh, fw, fh)
		sf.add_frame(anim_name, at)
		added += 1
	return added


# Normalize the `frames` arg into an Array of raw path strings. Accepts an
# Array (preferred), a comma-separated String, or null/missing (→ empty).
func _frame_paths(v) -> Array:
	if v == null:
		return []
	if v is Array:
		return v
	if v is PackedStringArray:
		return Array(v)
	if v is String:
		var out: Array = []
		for part in (v as String).split(",", false):
			var t: String = part.strip_edges()
			if not t.is_empty():
				out.append(t)
		return out
	return []


func _to_res_path(raw) -> String:
	var s: String = str(raw).strip_edges()
	if s.is_empty():
		return ""
	if s.begins_with("res://") or s.begins_with("user://"):
		return s
	if s.begins_with("/"):
		s = s.substr(1)
	return "res://" + s
