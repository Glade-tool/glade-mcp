extends GutTest

# Validates import_asset's pure import_options.filter parsing. Side-effect-free
# (no editor, no network, no ProjectSettings): parse_filter_option only reads
# the dict and reports ok/error. The actual project-default mutation
# (_apply_texture_filter) touches ProjectSettings and is covered by live
# verification, not here, to avoid GUT runs rewriting project.godot.

const ImportAsset = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/asset_pipeline/import_asset.gd")


# ── Not requested ───────────────────────────────────────────────────────────

func test_no_filter_key_is_ok_empty() -> void:
	var r := ImportAsset.parse_filter_option({})
	assert_true(r["ok"], "an empty import_options must parse ok")
	assert_eq(r["filter"], "", "no filter requested → empty string")


func test_null_filter_is_ok_empty() -> void:
	var r := ImportAsset.parse_filter_option({"filter": null})
	assert_true(r["ok"], "a null filter must parse ok (treated as not requested)")
	assert_eq(r["filter"], "")


func test_blank_filter_is_ok_empty() -> void:
	var r := ImportAsset.parse_filter_option({"filter": "   "})
	assert_true(r["ok"], "a whitespace-only filter is treated as not requested")
	assert_eq(r["filter"], "")


# ── Valid values ────────────────────────────────────────────────────────────

func test_nearest_accepted() -> void:
	var r := ImportAsset.parse_filter_option({"filter": "nearest"})
	assert_true(r["ok"])
	assert_eq(r["filter"], "nearest")


func test_linear_accepted() -> void:
	var r := ImportAsset.parse_filter_option({"filter": "linear"})
	assert_true(r["ok"])
	assert_eq(r["filter"], "linear")


func test_value_is_case_and_whitespace_insensitive() -> void:
	var r := ImportAsset.parse_filter_option({"filter": "  NEAREST "})
	assert_true(r["ok"])
	assert_eq(r["filter"], "nearest", "value should be lowercased and trimmed")


func test_key_is_case_insensitive() -> void:
	# normalize_args only normalizes top-level keys; the nested import_options
	# key may arrive camelCased.
	var r := ImportAsset.parse_filter_option({"Filter": "nearest"})
	assert_true(r["ok"], "a capitalized 'Filter' key must still resolve")
	assert_eq(r["filter"], "nearest")


# ── Invalid value ───────────────────────────────────────────────────────────

func test_unknown_value_rejected_with_guidance() -> void:
	var r := ImportAsset.parse_filter_option({"filter": "point"})
	assert_false(r["ok"], "an unrecognized filter value must fail fast, not silently no-op")
	assert_string_contains(r["error"], "nearest", "the error enumerates the valid values")
	assert_string_contains(r["error"], "linear")
	assert_string_contains(r["error"], "point", "the error echoes the offending value")


# ── Audio loop import text (build_loop_import_text) ──────────────────────────
# Verified empirically against Godot 4.6.3: ogg/mp3 loop via a bool `loop` param
# that round-trips into the imported resource. WAV's edit/loop_mode is NOT
# honored through a pre-written .import, so wav is deliberately excluded.

func test_ogg_loop_import_text() -> void:
	var t := ImportAsset.build_loop_import_text("ogg")
	assert_string_contains(t, 'importer="oggvorbisstr"', "ogg uses the oggvorbisstr importer")
	assert_string_contains(t, "loop=true", "ogg loops via the bool loop param")


func test_mp3_loop_import_text() -> void:
	var t := ImportAsset.build_loop_import_text("mp3")
	assert_string_contains(t, 'importer="mp3"')
	assert_string_contains(t, "loop=true")


func test_wav_is_excluded_from_auto_loop() -> void:
	# Intentional: wav's edit/loop_mode isn't applied via a pre-written .import
	# (verified 4.6.3), so we don't emit a misleading override for it.
	assert_eq(ImportAsset.build_loop_import_text("wav"), "", "wav is deliberately not auto-looped")


func test_loop_import_text_is_case_insensitive_on_ext() -> void:
	assert_string_contains(ImportAsset.build_loop_import_text("OGG"), "loop=true", "extension match is case-insensitive")


func test_non_audio_ext_yields_empty_text() -> void:
	assert_eq(ImportAsset.build_loop_import_text("png"), "", "a non-audio extension must produce no .import override")
	assert_eq(ImportAsset.build_loop_import_text(""), "", "empty extension → empty")


func test_loop_import_text_has_remap_and_params_sections() -> void:
	# Godot needs both sections present for a partial .import to be honored on
	# first import (the [remap] importer line + the [params] override).
	var t := ImportAsset.build_loop_import_text("ogg")
	assert_string_contains(t, "[remap]")
	assert_string_contains(t, "[params]")
