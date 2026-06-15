extends GutTest

# Integration smoke tests for the audio tools (create_audio_player +
# set_audio_player_properties). Each tool gets happy paths across all three
# player families plus the key error/partial-success branches. Editor + open
# scene required — same setup + skip story as test_phase3_tools.gd.
#
# Audio fixtures are native AudioStreamWAV .tres resources written to a scratch
# dir: unlike .wav files they load directly with no import step, so wiring a
# stream is testable headless-of-import. The streams are never played — these
# tests only verify node creation and property wiring.

const Registry = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

const SANDBOX_NAME := "_GladeKitAudioSandbox"
const SCRATCH_DIR := "res://_gk_audio_scratch"

var _registry = null
var _sandbox: Node = null


func should_skip_script():
	# Integration tests need editor context; GUT runs in play_custom_scene where
	# EditorInterface is unreachable. See test_phase3_tools.gd::should_skip_script.
	if ToolUtils.get_edited_scene_root_safe() == null:
		return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
	return false


func before_each() -> void:
	_registry = Registry.new()
	var scene_root := EditorInterface.get_edited_scene_root()
	var leftover := scene_root.find_child(SANDBOX_NAME, false, false)
	if leftover:
		scene_root.remove_child(leftover)
		leftover.free()
	_sandbox = Node3D.new()
	_sandbox.name = SANDBOX_NAME
	scene_root.add_child(_sandbox)
	_sandbox.owner = scene_root
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(SCRATCH_DIR))


func after_each() -> void:
	if _sandbox != null and is_instance_valid(_sandbox):
		var p := _sandbox.get_parent()
		if p != null:
			p.remove_child(_sandbox)
		_sandbox.free()
	_sandbox = null
	_registry = null
	_clear_scratch()


func _clear_scratch() -> void:
	var dir := DirAccess.open(SCRATCH_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var entry := dir.get_next()
		if entry.is_empty():
			break
		if entry.begins_with(".") or dir.current_is_dir():
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRATCH_DIR.path_join(entry)))
	dir.list_dir_end()


func _run(tool_name: String, args: Dictionary) -> Dictionary:
	var t = _registry.get_tool(tool_name)
	assert_not_null(t, "Tool '%s' must be registered" % tool_name)
	return t.execute(args)


# Write a native AudioStream resource (.tres) so the wiring tests have a real,
# import-free stream to load. Returns the res:// path.
func _make_audio_fixture(filename: String) -> String:
	var path := SCRATCH_DIR + "/" + filename
	var wav := AudioStreamWAV.new()
	wav.data = PackedByteArray([0, 0, 0, 0])  # silent — never played
	ResourceSaver.save(wav, path)
	return path


# ── create_audio_player: families ─────────────────────────────────────────

func test_create_non_positional_is_audio_stream_player() -> void:
	var r := _run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Music"})
	assert_true(r.success, str(r))
	assert_eq(r.type, "AudioStreamPlayer")
	assert_eq(r.space, "none")
	assert_false(r.positional)
	var node := _sandbox.find_child("Music", false, false)
	assert_not_null(node)
	assert_true(node is AudioStreamPlayer)


func test_create_positional_2d_is_audio_stream_player_2d() -> void:
	var r := _run("create_audio_player", {
		"positional": true,
		"space": "2d",
		"parent_path": SANDBOX_NAME,
		"name": "Footstep",
		"position": "100,50",
	})
	assert_true(r.success, str(r))
	assert_eq(r.type, "AudioStreamPlayer2D")
	assert_eq(r.space, "2d")
	assert_true(r.positional)
	var node := _sandbox.find_child("Footstep", false, false) as AudioStreamPlayer2D
	assert_not_null(node)
	assert_eq(node.position, Vector2(100, 50), "2D position uses x,y")


func test_create_positional_3d_is_audio_stream_player_3d() -> void:
	var r := _run("create_audio_player", {
		"positional": true,
		"space": "3d",
		"parent_path": SANDBOX_NAME,
		"name": "Growl",
		"max_distance": 30.0,
	})
	assert_true(r.success, str(r))
	assert_eq(r.type, "AudioStreamPlayer3D")
	assert_eq(r.space, "3d")
	var node := _sandbox.find_child("Growl", false, false) as AudioStreamPlayer3D
	assert_not_null(node)
	assert_almost_eq(node.max_distance, 30.0, 0.001)


func test_create_positional_infers_3d_from_scene() -> void:
	# No space arg + positional: the dev scene root is Node3D, so infer "3d".
	var r := _run("create_audio_player", {"positional": true, "parent_path": SANDBOX_NAME, "name": "Inferred"})
	assert_true(r.success, str(r))
	assert_eq(r.space, "3d", "space should be inferred from the 3D scene root")
	assert_eq(r.type, "AudioStreamPlayer3D")


# ── create_audio_player: stream wiring + properties ───────────────────────

func test_create_with_stream_assigns_and_derives_name() -> void:
	var stream_path := _make_audio_fixture("beep.tres")
	# No name → derived from the stream filename ("beep").
	var r := _run("create_audio_player", {"parent_path": SANDBOX_NAME, "stream": stream_path})
	assert_true(r.success, str(r))
	assert_eq(r.stream, stream_path)
	var node := _sandbox.find_child("beep", false, false) as AudioStreamPlayer
	assert_not_null(node, "node name should derive from the stream filename")
	assert_not_null(node.stream, "stream must be assigned on creation")
	assert_true(node.stream is AudioStream)


func test_create_applies_volume_autoplay_bus_pitch() -> void:
	var r := _run("create_audio_player", {
		"parent_path": SANDBOX_NAME,
		"name": "Cfg",
		"volume_db": -6.0,
		"autoplay": true,
		"pitch_scale": 1.5,
	})
	assert_true(r.success, str(r))
	assert_true(r.autoplay)
	var node := _sandbox.find_child("Cfg", false, false) as AudioStreamPlayer
	assert_almost_eq(node.volume_db, -6.0, 0.001)
	assert_true(node.autoplay)
	assert_almost_eq(node.pitch_scale, 1.5, 0.001)


func test_create_unknown_bus_warns_but_still_creates() -> void:
	var r := _run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Ghost", "bus": "NoSuchBus"})
	assert_true(r.success, str(r))
	assert_true(r.has("bus_warning"), "unknown bus must surface a bus_warning")
	assert_not_null(_sandbox.find_child("Ghost", false, false))


func test_create_missing_stream_file_errors() -> void:
	var r := _run("create_audio_player", {"parent_path": SANDBOX_NAME, "stream": SCRATCH_DIR + "/nope.tres"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))


func test_create_non_audio_stream_errors() -> void:
	# A BoxMesh .tres loads fine but isn't an AudioStream — the tool must reject it.
	var mesh_path := SCRATCH_DIR + "/not_audio.tres"
	ResourceSaver.save(BoxMesh.new(), mesh_path)
	var r := _run("create_audio_player", {"parent_path": SANDBOX_NAME, "stream": mesh_path})
	assert_false(r.success)
	assert_string_contains(r.error, "AudioStream")


func test_create_positional_unknown_space_errors() -> void:
	var r := _run("create_audio_player", {"positional": true, "space": "4d", "parent_path": SANDBOX_NAME})
	assert_false(r.success)
	assert_string_contains(r.error, "4d")


# ── set_audio_player_properties ───────────────────────────────────────────

func test_set_properties_happy() -> void:
	_run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Trk"})
	var r := _run("set_audio_player_properties", {
		"node_path": SANDBOX_NAME + "/Trk",
		"volume_db": -12.0,
		"autoplay": true,
	})
	assert_true(r.success, str(r))
	assert_true(r.applied_properties.has("volume_db"))
	assert_true(r.applied_properties.has("autoplay"))
	assert_eq(r.ignored_properties.size(), 0)
	var node := _sandbox.find_child("Trk", false, false) as AudioStreamPlayer
	assert_almost_eq(node.volume_db, -12.0, 0.001)


func test_set_max_distance_on_non_positional_is_ignored() -> void:
	_run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Flat"})
	var r := _run("set_audio_player_properties", {
		"node_path": SANDBOX_NAME + "/Flat",
		"max_distance": 500.0,
	})
	# Partial-success contract: the lone arg is wrong-class so it lands in
	# ignored_properties, but the call still succeeds.
	assert_true(r.success, str(r))
	assert_eq(r.applied_properties.size(), 0)
	assert_eq(r.ignored_properties.size(), 1)
	assert_eq(r.ignored_properties[0].name, "max_distance")


func test_set_max_distance_on_positional_applies() -> void:
	_run("create_audio_player", {"positional": true, "space": "2d", "parent_path": SANDBOX_NAME, "name": "Spatial"})
	var r := _run("set_audio_player_properties", {
		"node_path": SANDBOX_NAME + "/Spatial",
		"max_distance": 250.0,
	})
	assert_true(r.success, str(r))
	assert_true(r.applied_properties.has("max_distance"))
	var node := _sandbox.find_child("Spatial", false, false) as AudioStreamPlayer2D
	assert_almost_eq(node.max_distance, 250.0, 0.001)


func test_set_unknown_bus_is_ignored() -> void:
	_run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "BusTest"})
	var r := _run("set_audio_player_properties", {
		"node_path": SANDBOX_NAME + "/BusTest",
		"bus": "GhostBus",
	})
	assert_true(r.success, str(r))
	assert_eq(r.applied_properties.size(), 0)
	assert_eq(r.ignored_properties.size(), 1)
	assert_eq(r.ignored_properties[0].name, "bus")


func test_set_on_non_audio_node_errors() -> void:
	# The sandbox itself is a plain Node3D.
	var r := _run("set_audio_player_properties", {"node_path": SANDBOX_NAME, "volume_db": -3.0})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))
	assert_string_contains(r.error, "not an audio player")


func test_set_missing_node_errors() -> void:
	var r := _run("set_audio_player_properties", {"node_path": SANDBOX_NAME + "/Ghost", "volume_db": 0.0})
	assert_false(r.success)
	assert_string_contains(r.error, "not found")


func test_set_no_properties_errors() -> void:
	_run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Empty"})
	var r := _run("set_audio_player_properties", {"node_path": SANDBOX_NAME + "/Empty"})
	assert_false(r.success)
	assert_true(r.has("possible_solutions"))


# ── set_node_resource swaps the clip (the documented "change the audio") path ─

func test_set_node_resource_swaps_stream() -> void:
	_run("create_audio_player", {"parent_path": SANDBOX_NAME, "name": "Swap"})
	var stream_path := _make_audio_fixture("swap.tres")
	var r := _run("set_node_resource", {
		"node_path": SANDBOX_NAME + "/Swap",
		"property": "stream",
		"resource_path": stream_path,
	})
	assert_true(r.success, str(r))
	var node := _sandbox.find_child("Swap", false, false) as AudioStreamPlayer
	assert_not_null(node.stream, "stream should be assigned via set_node_resource")
	assert_true(node.stream is AudioStream)
