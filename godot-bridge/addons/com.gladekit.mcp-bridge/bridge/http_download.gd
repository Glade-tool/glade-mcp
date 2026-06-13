extends RefCounted

# Blocking HTTPS file downloader built on HTTPClient.
#
# Why HTTPClient and not HTTPRequest:
#   HTTPRequest is a Node — it wants to live in the SceneTree and emits its
#   result via a signal pumped by the main loop. The asset pipeline downloads
#   from a WORKER thread (so the editor's main thread stays responsive while a
#   multi-megabyte pack lands), and a Node-based, signal-driven API is awkward
#   to drive synchronously off-thread. HTTPClient is a plain RefCounted we can
#   poll in a tight loop on whatever thread calls us.
#
# Contract:
#   download_to_file() BLOCKS the calling thread until the download completes,
#   fails, or times out. Call it from a Thread — never from the editor main
#   thread (a slow host would trip the bridge's main-thread stall watchdog).
#
# It does its own redirect following (HTTPClient does not) and enforces a byte
# cap + wall-clock timeout so a hostile or broken host can't claim unbounded
# disk or wedge the worker forever.

# 301/302/303/307/308 — the set we follow. 303 is included so a POST-style
# redirect would degrade to GET, but we only ever issue GET so it's moot here.
const _REDIRECT_CODES := [301, 302, 303, 307, 308]


# Download `url` to the absolute filesystem path `dest_abs_path`.
#
# Returns a Dictionary:
#   { success: bool, error: String, status_code: int, bytes: int,
#     final_url: String }
# On failure the partial file (if any) is removed so callers never see a
# truncated asset on disk.
static func download_to_file(
	url: String,
	dest_abs_path: String,
	max_bytes: int,
	timeout_msec: int,
	max_redirects: int = 5
) -> Dictionary:
	var started_msec := Time.get_ticks_msec()
	var current_url := url
	var redirects_left := max_redirects

	while true:
		var parsed := _parse_url(current_url)
		if not parsed.get("ok", false):
			return _fail("Malformed URL %r: %s" % [current_url, parsed.get("error", "")])

		var host: String = parsed["host"]
		var port: int = parsed["port"]
		var use_tls: bool = parsed["tls"]
		var path: String = parsed["path"]

		var client := HTTPClient.new()
		var tls_opts: TLSOptions = TLSOptions.client() if use_tls else null
		var err := client.connect_to_host(host, port, tls_opts)
		if err != OK:
			return _fail("connect_to_host(%s:%d) failed (error %d)" % [host, port, err])

		# Pump the connection handshake.
		var connect_result := _poll_until(
			client,
			[HTTPClient.STATUS_CONNECTED],
			[HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING],
			started_msec, timeout_msec
		)
		if not connect_result.get("ok", false):
			client.close()
			return _fail("connecting to %s: %s" % [host, connect_result.get("error", "")])

		# A browser-ish UA + explicit Accept keeps picky CDNs from 403-ing.
		var headers := [
			"User-Agent: GladeKitBridge/1.0 (+https://github.com/Glade-tool/glade-mcp)",
			"Accept: */*",
		]
		err = client.request(HTTPClient.METHOD_GET, path, headers)
		if err != OK:
			client.close()
			return _fail("request(%s) failed (error %d)" % [path, err])

		# Pump until headers are parsed (STATUS_BODY) or the response has no
		# body (STATUS_CONNECTED — e.g. a bare redirect).
		var req_result := _poll_until(
			client,
			[HTTPClient.STATUS_BODY, HTTPClient.STATUS_CONNECTED],
			[HTTPClient.STATUS_REQUESTING],
			started_msec, timeout_msec
		)
		if not req_result.get("ok", false):
			client.close()
			return _fail("awaiting response from %s: %s" % [host, req_result.get("error", "")])

		var code := client.get_response_code()

		# Redirect? Resolve Location and loop.
		if code in _REDIRECT_CODES:
			var resp_headers := client.get_response_headers_as_dictionary()
			client.close()
			if redirects_left <= 0:
				return _fail("too many redirects (last code %d)" % code)
			var location := _header_ci(resp_headers, "Location")
			if location.is_empty():
				return _fail("redirect %d with no Location header" % code)
			current_url = _resolve_redirect(current_url, location)
			redirects_left -= 1
			continue

		if code < 200 or code >= 300:
			client.close()
			return _fail("HTTP %d from %s" % [code, current_url], code)

		# Stream the body to disk.
		var stream_result := _stream_body_to_file(
			client, dest_abs_path, max_bytes, started_msec, timeout_msec
		)
		client.close()
		if not stream_result.get("ok", false):
			_remove_partial(dest_abs_path)
			return _fail(stream_result.get("error", "body stream failed"), code)

		return {
			"success": true,
			"error": "",
			"status_code": code,
			"bytes": int(stream_result.get("bytes", 0)),
			"final_url": current_url,
		}

	# Unreachable — the loop only exits via return.
	return _fail("download loop exited unexpectedly")


# Poll the client until its status enters one of `good_statuses`. `wait_statuses`
# are the transient in-progress states we keep pumping through. Any other status
# (or a timeout) is an error.
static func _poll_until(
	client: HTTPClient,
	good_statuses: Array,
	wait_statuses: Array,
	started_msec: int,
	timeout_msec: int
) -> Dictionary:
	while true:
		client.poll()
		var status := client.get_status()
		if status in good_statuses:
			return {"ok": true}
		if not (status in wait_statuses):
			return {"ok": false, "error": "unexpected HTTPClient status %d" % status}
		if Time.get_ticks_msec() - started_msec > timeout_msec:
			return {"ok": false, "error": "timed out after %dms" % timeout_msec}
		OS.delay_msec(10)
	# Unreachable — the loop only exits via return. Present to satisfy
	# GDScript's "all code paths return a value" analysis for `while true`.
	return {"ok": false, "error": "poll loop exited unexpectedly"}


static func _stream_body_to_file(
	client: HTTPClient,
	dest_abs_path: String,
	max_bytes: int,
	started_msec: int,
	timeout_msec: int
) -> Dictionary:
	var f := FileAccess.open(dest_abs_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "cannot open %s for write (error %d)" % [dest_abs_path, FileAccess.get_open_error()]}

	var total := 0
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() == 0:
			# No data ready yet — yield briefly rather than busy-spin.
			if Time.get_ticks_msec() - started_msec > timeout_msec:
				f.close()
				return {"ok": false, "error": "timed out mid-body after %dms" % timeout_msec}
			OS.delay_msec(10)
			continue
		total += chunk.size()
		if total > max_bytes:
			f.close()
			return {"ok": false, "error": "download exceeded %d-byte cap" % max_bytes}
		f.store_buffer(chunk)

	f.close()
	return {"ok": true, "bytes": total}


# ── URL parsing / redirect resolution ──────────────────────────────────────
# GDScript has no URL parser. This handles the shapes the asset providers
# actually emit (https with optional explicit port + path + query); it is not
# a general-purpose RFC 3986 implementation.
static func _parse_url(url: String) -> Dictionary:
	var u := url.strip_edges()
	var tls := false
	if u.begins_with("https://"):
		tls = true
		u = u.substr(8)
	elif u.begins_with("http://"):
		u = u.substr(7)
	else:
		return {"ok": false, "error": "only http/https supported"}

	var slash := u.find("/")
	var authority := u if slash == -1 else u.substr(0, slash)
	var path := "/" if slash == -1 else u.substr(slash)
	if path.is_empty():
		path = "/"

	if authority.is_empty():
		return {"ok": false, "error": "empty host"}

	var host := authority
	var port := 443 if tls else 80
	var colon := authority.rfind(":")
	if colon != -1:
		var port_str := authority.substr(colon + 1)
		if port_str.is_valid_int():
			host = authority.substr(0, colon)
			port = int(port_str)

	return {"ok": true, "host": host, "port": port, "tls": tls, "path": path}


# Resolve a (possibly relative) Location header against the URL it came from.
static func _resolve_redirect(base_url: String, location: String) -> String:
	var loc := location.strip_edges()
	if loc.begins_with("http://") or loc.begins_with("https://"):
		return loc
	var base := _parse_url(base_url)
	if not base.get("ok", false):
		return loc
	var scheme := "https" if base["tls"] else "http"
	var authority: String = base["host"]
	var default_port := 443 if base["tls"] else 80
	if int(base["port"]) != default_port:
		authority += ":" + str(base["port"])
	if loc.begins_with("/"):
		return "%s://%s%s" % [scheme, authority, loc]
	# Relative path — resolve against the base directory.
	var base_path: String = base["path"]
	var dir := base_path.substr(0, base_path.rfind("/") + 1)
	return "%s://%s%s%s" % [scheme, authority, dir, loc]


# Case-insensitive header lookup (HTTP header names are case-insensitive and
# CDNs are inconsistent about casing the Location header).
static func _header_ci(headers: Dictionary, name: String) -> String:
	var target := name.to_lower()
	for k in headers.keys():
		if str(k).to_lower() == target:
			return str(headers[k])
	return ""


static func _remove_partial(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func _fail(message: String, status_code: int = 0) -> Dictionary:
	return {
		"success": false,
		"error": message,
		"status_code": status_code,
		"bytes": 0,
		"final_url": "",
	}
