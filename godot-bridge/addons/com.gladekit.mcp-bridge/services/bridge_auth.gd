extends RefCounted

# Per-session token authentication for the Godot bridge.
#
# THREAT: the bridge is a WebSocket server on 127.0.0.1:8766. Any web page the
# user visits can open `new WebSocket("ws://127.0.0.1:8766")` and drive every
# tool — including run_project, which spawns a subprocess (a CSWSH / drive-by
# attack). Godot 4's WebSocketPeer.accept_stream does NOT expose the incoming
# HTTP handshake to GDScript, so the bridge cannot inspect Origin or any custom
# header — the standard browser defenses are unavailable here.
#
# DEFENSE: a per-session token. On startup the bridge generates a random token
# and writes it to a local file readable only by the current OS user. Every
# request (except the `health` liveness probe) must echo that token in its JSON
# body. A browser can open the socket and send arbitrary JSON, but it CANNOT
# read a local file, so it can never learn the token → its requests are refused.
# A legitimate local client (the MCP server, the desktop app, the eval harness)
# reads the file and includes the token. This is the same model Jupyter and
# VS Code use to protect their localhost servers.
#
# TOKEN FILE LOCATION (every client MUST compute the same path):
#   <home>/.gladekit/godot-bridge-<port>.token
# keyed by port so multiple projects on different ports don't collide, and
# discoverable without knowing the project path (clients know the port they dial).
#
# OPT-OUT: set GLADEKIT_GODOT_NO_AUTH=1 to disable enforcement entirely (for
# users on an older client that can't send the token yet). Documented, logged
# loudly at startup, and strictly opt-in — the secure default is enforcement.

const ENV_OPT_OUT := "GLADEKIT_GODOT_NO_AUTH"

# Endpoints answered without a token. `health` is a pure liveness probe clients
# use to bootstrap and to tell "editor wedged" apart from "bridge gone"; it
# leaks only version/projectName/toolCount, which is low-risk. Everything else —
# tools/list, tools/execute, context/gather, backup/*, turn/* — requires the token.
const EXEMPT_ENDPOINTS := ["health"]


static func is_auth_disabled() -> bool:
	var v := OS.get_environment(ENV_OPT_OUT).strip_edges().to_lower()
	return v == "1" or v == "true"


## Cryptographically random 64-hex-char token (32 bytes).
static func generate_token() -> String:
	var crypto := Crypto.new()
	return crypto.generate_random_bytes(32).hex_encode()


## Absolute path to the token file for a given port. Clients replicate this
## exactly: <home>/.gladekit/godot-bridge-<port>.token
static func token_path(port: int) -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")  # Windows
	return home.path_join(".gladekit").path_join("godot-bridge-%d.token" % port)


## Write the token to its file (owner-only on unix). Returns the path on success,
## or "" on failure so the caller can fail open (a bridge that can't publish a
## token must not refuse every client — availability over a defense that would
## brick the tool). The caller logs loudly when this returns "".
static func write_token(port: int, token: String) -> String:
	var path := token_path(port)
	var dir := path.get_base_dir()
	var mkerr := DirAccess.make_dir_recursive_absolute(dir)
	if mkerr != OK and not DirAccess.dir_exists_absolute(dir):
		return ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(token)
	f.close()
	# GDScript has no chmod; shell out best-effort on unix so another local user
	# can't read the token. Windows home directories are already per-user ACL'd.
	if OS.has_feature("linux") or OS.has_feature("macos"):
		OS.execute("chmod", ["600", path])
	return path


## True when a request may proceed. Auth-disabled and exempt endpoints always
## pass. When no token was generated (write failed → expected_token == "") we
## fail open. Otherwise the request must carry the exact token.
static func is_request_authorized(endpoint: String, request: Dictionary, expected_token: String) -> bool:
	if is_auth_disabled():
		return true
	if EXEMPT_ENDPOINTS.has(endpoint):
		return true
	if expected_token == "":
		return true
	var provided := str(request.get("token", ""))
	return constant_time_eq(provided, expected_token)


## Length-aware constant-time compare. The localhost threat model doesn't make a
## timing oracle likely, but this costs nothing and avoids an early-exit compare.
static func constant_time_eq(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff := 0
	for i in range(a.length()):
		diff |= (a.unicode_at(i) ^ b.unicode_at(i))
	return diff == 0
