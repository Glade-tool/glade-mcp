extends RefCounted

# Toggle gate + download-host allowlist for the asset pipeline (import_asset,
# list_imported_assets).
#
# Two independent protections:
#
#   1. Enable/disable toggle — default ON. Teams working in an existing
#      project can turn the pipeline off so the agent never reaches out to
#      external asset hosts. Disable via either:
#        * env  GLADEKIT_GODOT_DISABLE_ASSET_PIPELINE=1
#        * ProjectSettings  gladekit/asset_pipeline_disabled = true
#
#   2. Download-host allowlist — defense in depth. The download URL is
#      resolved upstream from a trusted catalog, but the bridge re-checks the
#      host here so that even a forged or smuggled URL can only ever point at a
#      host we already trust for the named provider. The check requires HTTPS.
#
# Provider is taken from the candidate id prefix ("kenney/tiny-town" → kenney).

const ENV_DISABLE := "GLADEKIT_GODOT_DISABLE_ASSET_PIPELINE"
const SETTING_DISABLE := "gladekit/asset_pipeline_disabled"

# Provider → allowed download hosts. `exact` matches one host; `suffixes`
# (each beginning with '.') trust an entire subdomain tree of a vendor we
# already trust at the apex — used when a vendor rotates CDN hostnames.
const _ALLOWED := {
	"kenney": {
		"exact": ["kenney.nl", "www.kenney.nl"],
		"suffixes": [],
	},
	"meshy": {
		"exact": ["meshy.ai"],
		"suffixes": [".meshy.ai"],
	},
}


static func is_enabled() -> bool:
	if OS.get_environment(ENV_DISABLE).strip_edges() == "1":
		return false
	if ProjectSettings.has_setting(SETTING_DISABLE):
		return not bool(ProjectSettings.get_setting(SETTING_DISABLE))
	return true


# Returns "" when the pipeline is enabled, otherwise a ready-to-return error
# message. Tools call this first and short-circuit on a non-empty string.
static func reject_if_disabled() -> String:
	if is_enabled():
		return ""
	return (
		"Asset pipeline is disabled. Clear the %s environment variable, or set "
		+ "ProjectSettings '%s' to false, to allow downloads of external assets."
	) % [ENV_DISABLE, SETTING_DISABLE]


# Returns "" when the resolved URL is allowed for the candidate's provider;
# otherwise a human-readable rejection reason (including the offending host so
# the caller's error names what to fix). This is the authoritative check.
static func describe_url_host_rejection(candidate_id: String, resolved_url: String) -> String:
	if candidate_id.is_empty():
		return "candidateId is empty"
	if resolved_url.is_empty():
		return "resolved download URL is empty"

	var slash := candidate_id.find("/")
	if slash <= 0:
		return "candidateId '%s' is missing a provider prefix" % candidate_id
	var provider := candidate_id.substr(0, slash)

	if not _ALLOWED.has(provider):
		return "provider '%s' is not in the download allowlist (unknown provider)" % provider

	if not resolved_url.begins_with("https://"):
		return "resolved download URL is not HTTPS (%s)" % _truncate(resolved_url, 80)

	var host := _host_of(resolved_url)
	if host.is_empty():
		return "could not parse host from resolved download URL"

	var allowed: Dictionary = _ALLOWED[provider]
	for h in allowed.get("exact", []):
		if host.nocasecmp_to(String(h)) == 0:
			return ""
	for suffix in allowed.get("suffixes", []):
		if host.to_lower().ends_with(String(suffix).to_lower()):
			return ""

	return "host '%s' is not in the allowlist for provider '%s'. Allowed: %s" % [
		host, provider, _describe_allowed(allowed),
	]


# Extract the host from an https URL. Mirrors http_download._parse_url but kept
# local so the guard has no dependency on the downloader.
static func _host_of(url: String) -> String:
	var u := url.strip_edges()
	if u.begins_with("https://"):
		u = u.substr(8)
	elif u.begins_with("http://"):
		u = u.substr(7)
	var slash := u.find("/")
	var authority := u if slash == -1 else u.substr(0, slash)
	var colon := authority.rfind(":")
	if colon != -1:
		authority = authority.substr(0, colon)
	return authority


static func _describe_allowed(allowed: Dictionary) -> String:
	var parts: Array = []
	for h in allowed.get("exact", []):
		parts.append(String(h))
	for s in allowed.get("suffixes", []):
		parts.append("*" + String(s))
	return "(none)" if parts.is_empty() else ", ".join(parts)


static func _truncate(s: String, n: int) -> String:
	if s.length() <= n:
		return s
	return s.substr(0, n) + "…"
