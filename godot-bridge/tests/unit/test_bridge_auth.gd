extends GutTest

# Unit tests for the per-session token auth (bridge_auth.gd). Pure logic — no
# editor, no live socket. The enforcement assertions assume auth is NOT disabled
# via the opt-out env; they skip cleanly (pending) if a runner sets it, so the
# suite never fails spuriously in an opt-out environment.

const BridgeAuth = preload("res://addons/com.gladekit.mcp-bridge/services/bridge_auth.gd")

const SECRET := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


func test_health_is_exempt_even_without_token() -> void:
	# The liveness probe must answer without a token so clients can bootstrap.
	assert_true(BridgeAuth.is_request_authorized("health", {}, SECRET))


func test_execute_requires_token() -> void:
	if BridgeAuth.is_auth_disabled():
		pending("GLADEKIT_GODOT_NO_AUTH set; enforcement disabled in this env")
		return
	assert_false(BridgeAuth.is_request_authorized("tools/execute", {}, SECRET))


func test_execute_accepts_correct_token() -> void:
	if BridgeAuth.is_auth_disabled():
		pending("GLADEKIT_GODOT_NO_AUTH set; enforcement disabled in this env")
		return
	assert_true(BridgeAuth.is_request_authorized("tools/execute", {"token": SECRET}, SECRET))


func test_execute_rejects_wrong_token() -> void:
	if BridgeAuth.is_auth_disabled():
		pending("GLADEKIT_GODOT_NO_AUTH set; enforcement disabled in this env")
		return
	assert_false(BridgeAuth.is_request_authorized("tools/execute", {"token": "wrong"}, SECRET))


func test_empty_expected_token_fails_open() -> void:
	# When the bridge could not generate/publish a token it passes "" as the
	# expected value — availability wins over a defense that would refuse every
	# client. This must be allowed.
	assert_true(BridgeAuth.is_request_authorized("tools/execute", {}, ""))


func test_constant_time_eq() -> void:
	assert_true(BridgeAuth.constant_time_eq("abc", "abc"))
	assert_false(BridgeAuth.constant_time_eq("abc", "abd"))
	assert_false(BridgeAuth.constant_time_eq("abc", "abcd"))  # length mismatch
	assert_false(BridgeAuth.constant_time_eq("", "x"))
	assert_true(BridgeAuth.constant_time_eq("", ""))


func test_generate_token_is_random_64_hex() -> void:
	var a := BridgeAuth.generate_token()
	var b := BridgeAuth.generate_token()
	assert_eq(a.length(), 64, "32 random bytes hex-encode to 64 chars")
	assert_ne(a, b, "each call yields a fresh token")
	assert_true(a.is_valid_hex_number(false), "token is hex")


func test_token_path_is_port_keyed_under_gladekit() -> void:
	var p := BridgeAuth.token_path(8766)
	assert_true(p.ends_with("godot-bridge-8766.token"), "path is keyed by port")
	assert_true(p.contains(".gladekit"), "path lives under the .gladekit dir")
	# Different ports must not collide (multiple projects).
	assert_ne(BridgeAuth.token_path(8766), BridgeAuth.token_path(8767))
