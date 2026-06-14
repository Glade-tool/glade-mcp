extends GutTest

# Smoke coverage for import_asset's EDITOR-SIDE finalize — the steps that only
# run inside a live Godot editor and are therefore invisible to the headless
# unit suite. Three layers, by how much of a real editor they need:
#
#   Part 1 (headless): resolve_filter_change — the pure filter decision. Runs
#           everywhere; gates every local test run.
#   Part 2 (headless): the project-setting key import_asset writes is a REAL
#           engine setting (catches a typo'd settings path — the main latent
#           bug in _apply_texture_filter). In-memory only; no file written.
#   Part 3 (editor only): drive a real EditorFileSystem.scan() over a placed
#           fixture and assert Godot imports it. This is the M4/M5 gap — the
#           scan→import handoff import_asset depends on but nothing exercised.
#           pending() when run headless (no EditorInterface), so it never passes
#           for the wrong reason. To run it: open godot-bridge/ in the editor and
#           run this test from the GUT panel.
#
# Why this exists: import_asset's most load-bearing editor step (scan→import)
# and its one global side effect (default_texture_filter) were otherwise only
# confirmable by hand in a live editor. This turns that into a repeatable check.

const ImportAsset = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/asset_pipeline/import_asset.gd")
const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

# A throwaway res:// folder for the fixtures. Lives outside any real asset dir
# and is removed in after_each.
const _SMOKE_DIR := "res://_gladekit_asset_smoke/"
const _SMOKE_PNG := _SMOKE_DIR + "smoke_sprite.png"


func after_each() -> void:
	# Fixtures + their generated .import are cleaned; the imported artifacts land
	# under res://.godot/imported/ (gitignored) — leave them.
	_remove_if_exists(_SMOKE_PNG)
	_remove_if_exists(_SMOKE_PNG + ".import")
	var dir_abs := ProjectSettings.globalize_path(_SMOKE_DIR)
	if DirAccess.dir_exists_absolute(dir_abs):
		DirAccess.remove_absolute(dir_abs)


func _remove_if_exists(res_path: String) -> void:
	var abs := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)


# ── Part 1: pure filter decision (headless) ─────────────────────────────────

func test_no_filter_requested_is_a_noop() -> void:
	var d := ImportAsset.resolve_filter_change("", "sprite_2d", 1)
	assert_eq(d["action"], "none", "an empty filter must not touch any setting")


func test_unknown_filter_is_a_noop() -> void:
	# parse_filter_option rejects bad values upstream; resolve_filter_change
	# defends the same way rather than acting on garbage.
	var d := ImportAsset.resolve_filter_change("point", "sprite_2d", 1)
	assert_eq(d["action"], "none", "an unrecognized filter must not act")


func test_nearest_on_non_sprite_type_is_skipped() -> void:
	var d := ImportAsset.resolve_filter_change("nearest", "model_3d", 1)
	assert_eq(d["action"], "skip", "filter must not apply to model_3d (PBR wants linear+mipmaps)")
	assert_string_contains(d["reason"], "sprite", "the skip reason explains the applicable types")


func test_filter_on_audio_is_skipped() -> void:
	var d := ImportAsset.resolve_filter_change("nearest", "audio_sfx", 1)
	assert_eq(d["action"], "skip", "audio has no textures to filter")


func test_nearest_when_already_nearest_is_skipped() -> void:
	# current == 0 (NEAREST) already; flipping again is wasteful + a needless save.
	var d := ImportAsset.resolve_filter_change("nearest", "sprite_2d", 0)
	assert_eq(d["action"], "skip", "no-op when the project default already matches")
	assert_string_contains(d["reason"], "already")


func test_nearest_over_linear_default_is_applied() -> void:
	# The headline pixel-art case: project at Godot's LINEAR default (1), user
	# wants crisp pixels → flip to NEAREST (0).
	var d := ImportAsset.resolve_filter_change("nearest", "sprite_2d", 1)
	assert_eq(d["action"], "apply")
	assert_eq(d["target"], 0, "nearest maps to CanvasItem.TEXTURE_FILTER_NEAREST (0)")
	assert_eq(d["previousValue"], 1, "previous value is reported for transparency")


func test_linear_over_nearest_is_applied() -> void:
	var d := ImportAsset.resolve_filter_change("linear", "ui_sprite", 0)
	assert_eq(d["action"], "apply")
	assert_eq(d["target"], 1, "linear maps to CanvasItem.TEXTURE_FILTER_LINEAR (1)")
	assert_eq(d["previousValue"], 0)


# ── Part 2: the settings key is real (headless, no file write) ──────────────

func test_filter_setting_path_is_a_real_engine_setting() -> void:
	# get_setting returns our sentinel ONLY if the key is unknown to the engine.
	# A non-sentinel return proves _FILTER_SETTING names a real built-in setting
	# — the cheapest guard against a typo'd settings path in _apply_texture_filter
	# (set_setting would happily create a junk custom key, so this is the check
	# that actually catches it). Reads only; nothing is written or saved.
	var sentinel := -97531
	var v = ProjectSettings.get_setting(ImportAsset._FILTER_SETTING, sentinel)
	assert_ne(v, sentinel, "default_texture_filter must be a real engine setting (key typo guard)")
	assert_true(typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT, "filter setting is an enum int")


# ── Part 3: real scan() → import (editor only) ──────────────────────────────

func test_scan_imports_a_placed_fixture() -> void:
	var ei: Object = ToolUtils.get_editor_interface_safe()
	if ei == null:
		pending("requires a live editor — open godot-bridge/ and run from the GUT panel")
		return

	# Place a real PNG the way import_asset's worker would, then trigger the same
	# rescan poll() performs and assert Godot actually imports it.
	var dir_abs := ProjectSettings.globalize_path(_SMOKE_DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	var png_abs := ProjectSettings.globalize_path(_SMOKE_PNG)
	assert_eq(img.save_png(png_abs), OK, "fixture PNG must be writable")

	var fs = ei.get_resource_filesystem()
	assert_not_null(fs, "editor filesystem must be available")
	fs.scan()

	# Import runs across editor idle frames; poll for the generated .import
	# sidecar with a generous ceiling rather than a fixed sleep.
	var import_abs := png_abs + ".import"
	var imported := false
	for _i in range(160):  # ~8s at 0.05s/iter
		if FileAccess.file_exists(import_abs):
			imported = true
			break
		await get_tree().create_timer(0.05).timeout

	assert_true(imported, "scan() must drive Godot to import the placed fixture (.import should appear)")
	if imported:
		var res = load(_SMOKE_PNG)
		assert_true(res is Texture2D, "the imported fixture loads as a Texture2D")