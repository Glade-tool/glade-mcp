extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

# Captures the rendered editor viewport as a PNG and returns it base64-encoded
# so the assistant can *see* what it built — invisible sprites, missing/erroring
# materials, off-screen UI, dark lighting: the whole class of visual problems
# that node inspection alone cannot detect.
#
# Read-only. Picks the 2D or 3D editor viewport based on the edited scene (or an
# explicit `space` arg). The image rides back on the "image_base64" /
# "image_mime" response fields; the client surfaces it as a vision input.
#
# Response payload:
#   image_base64: String — base64-encoded PNG of the viewport
#   image_mime: String — "image/png"
#   width, height: int — pixel size of the returned image
#   source: String — "viewport_2d" | "viewport_3d"

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# Cap the longest edge so the base64 PNG stays a reasonable vision-input size.
const DEFAULT_MAX_WIDTH := 1280
const HARD_MAX_WIDTH := 2048


func _init() -> void:
	tool_name = "look_at_game_view"
	requires_edit_mode = false


func execute(args: Dictionary) -> Dictionary:
	var max_width: int = DEFAULT_MAX_WIDTH
	if args.has("maxWidth"):
		var requested := int(args.get("maxWidth", DEFAULT_MAX_WIDTH))
		if requested > 0:
			max_width = clampi(requested, 64, HARD_MAX_WIDTH)

	var use_2d := _should_use_2d(args)
	var viewport: SubViewport = null
	var source := ""
	if use_2d:
		viewport = EditorInterface.get_editor_viewport_2d()
		source = "viewport_2d"
	else:
		viewport = EditorInterface.get_editor_viewport_3d(0)
		source = "viewport_3d"

	if viewport == null:
		return ToolUtils.error("Could not access the editor viewport to capture.")

	var tex := viewport.get_texture()
	if tex == null:
		return ToolUtils.error("Editor viewport has no texture yet — try again after the view has rendered.")

	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return ToolUtils.error("Captured an empty frame — open the 2D/3D view so it renders, then try again.")

	# Downscale to the cap, preserving aspect.
	var w := img.get_width()
	var h := img.get_height()
	if w > max_width:
		var scale := float(max_width) / float(w)
		w = max_width
		h = maxi(1, int(round(img.get_height() * scale)))
		img.resize(w, h, Image.INTERPOLATE_BILINEAR)

	var buf: PackedByteArray = img.save_png_to_buffer()
	if buf.is_empty():
		return ToolUtils.error("Failed to encode the captured frame to PNG.")

	var b64 := Marshalls.raw_to_base64(buf)
	return ToolUtils.success(
		"Captured the %s view (%dx%d)." % [("2D" if use_2d else "3D"), w, h],
		{
			"image_base64": b64,
			"image_mime": "image/png",
			"width": w,
			"height": h,
			"source": source,
		}
	)


# Decide which editor viewport to grab. Explicit `space` arg wins; otherwise
# infer from the edited scene — a CanvasItem/Node2D root (or a Camera2D in the
# tree) means a 2D game, anything else defaults to the 3D view.
func _should_use_2d(args: Dictionary) -> bool:
	var space := String(args.get("space", "")).to_lower()
	if space == "2d":
		return true
	if space == "3d":
		return false

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return false
	if root is CanvasItem:
		return true
	if _has_node_of_type(root, "Camera2D") and not _has_node_of_type(root, "Camera3D"):
		return true
	return false


func _has_node_of_type(node: Node, type_name: String) -> bool:
	if node.is_class(type_name):
		return true
	for child in node.get_children():
		if _has_node_of_type(child, type_name):
			return true
	return false
