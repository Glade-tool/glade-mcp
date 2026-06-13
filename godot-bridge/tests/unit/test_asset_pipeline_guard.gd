extends GutTest

# Validates the asset-pipeline download-host allowlist and HTTPS enforcement.
# Pure logic — no editor, no network. This is a security boundary: the download
# URL is resolved upstream, but the bridge re-checks it here so a forged or
# smuggled URL can only ever reach a host we already trust per provider.

const AssetPipelineGuard = preload("res://addons/com.gladekit.mcp-bridge/services/asset_pipeline_guard.gd")


# ── Allowed hosts ──────────────────────────────────────────────────────────

func test_kenney_apex_host_allowed() -> void:
	assert_eq(
		AssetPipelineGuard.describe_url_host_rejection("kenney/tiny-town", "https://kenney.nl/a.zip"),
		"", "kenney.nl over HTTPS should be allowed for the kenney provider")


func test_kenney_www_host_allowed() -> void:
	assert_eq(
		AssetPipelineGuard.describe_url_host_rejection("kenney/tiny-town", "https://www.kenney.nl/a.zip"),
		"", "www.kenney.nl should be allowed")


func test_meshy_subdomain_suffix_allowed() -> void:
	# Meshy rotates CDN hostnames; we trust the whole *.meshy.ai subtree.
	assert_eq(
		AssetPipelineGuard.describe_url_host_rejection("meshy/abc123", "https://cdn.assets.meshy.ai/m.glb"),
		"", "a *.meshy.ai subdomain should be allowed for the meshy provider")


# ── Rejections ─────────────────────────────────────────────────────────────

func test_off_allowlist_host_rejected() -> void:
	var reason := AssetPipelineGuard.describe_url_host_rejection(
		"kenney/tiny-town", "https://evil.example.com/a.zip")
	assert_string_contains(reason, "allowlist", "off-allowlist host must be rejected")
	assert_string_contains(reason, "evil.example.com", "rejection names the offending host")


func test_non_https_rejected() -> void:
	var reason := AssetPipelineGuard.describe_url_host_rejection(
		"kenney/tiny-town", "http://kenney.nl/a.zip")
	assert_string_contains(reason, "HTTPS", "a non-HTTPS URL must be rejected even for an allowed host")


func test_unknown_provider_rejected() -> void:
	var reason := AssetPipelineGuard.describe_url_host_rejection(
		"sketchy/thing", "https://sketchy.example.com/a.zip")
	assert_string_contains(reason, "unknown provider", "an unknown provider prefix must be rejected")


func test_missing_provider_prefix_rejected() -> void:
	var reason := AssetPipelineGuard.describe_url_host_rejection(
		"no-slash-id", "https://kenney.nl/a.zip")
	assert_string_contains(reason, "provider prefix", "a candidate id without a provider prefix must be rejected")


func test_empty_inputs_rejected() -> void:
	assert_ne(AssetPipelineGuard.describe_url_host_rejection("", "https://kenney.nl/a.zip"), "",
		"empty candidate id must be rejected")
	assert_ne(AssetPipelineGuard.describe_url_host_rejection("kenney/x", ""), "",
		"empty URL must be rejected")


func test_lookalike_host_suffix_not_confused() -> void:
	# "notkenney.nl" must NOT match the exact "kenney.nl" entry.
	var reason := AssetPipelineGuard.describe_url_host_rejection(
		"kenney/x", "https://notkenney.nl/a.zip")
	assert_string_contains(reason, "allowlist", "a look-alike host must not satisfy an exact-match allow entry")


# ── Enable/disable toggle ──────────────────────────────────────────────────

func test_enabled_by_default() -> void:
	# No env/setting override in the test environment → pipeline is enabled.
	assert_true(AssetPipelineGuard.is_enabled(), "asset pipeline should default to enabled")
	assert_eq(AssetPipelineGuard.reject_if_disabled(), "", "reject_if_disabled returns empty when enabled")
