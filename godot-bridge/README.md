# GladeKit MCP Bridge for Godot

Local WebSocket server that lives inside the Godot 4 editor and exposes
scene, node, script, and resource tools so AI assistants can read and modify
the active project. Designed to be addressed by an MCP server (for use with
Cursor, Claude Code, Windsurf, and similar) or by the GladeKit desktop app.

**Status:** 53 tools registered across 11 categories.

| Phase | Tools | Cumulative | Status |
| --- | --- | --- | --- |
| 1 | `get_scene_tree` | 1 | shipped (v0.1.0) |
| 2 | + 9 Scene/Node, + 5 Script | 15 | shipped (v0.2.0) |
| 3 | + 2 Camera/Light, + 2 Resource, + 1 Physics, + 4 Scene I/O, + 7 Runtime/process (incl. `run_project`/`stop_project`/`get_debug_output` + `launch_editor`), + 2 UID (4.4+) | 33 | shipped (v0.3.0) |
| 5 | + 3 Signal wiring (`connect_signal`, `list_signal_connections`, `disconnect_signal`) | 36 | shipped (v0.4.1) |
| 6 | + 1 Project introspection (`get_project_info`) | 37 | shipped (v0.4.2) |
| 7 | + 1 Resource assignment (`set_node_resource`); `readOnlyHint` on read-only tools | 38 | shipped (v0.4.4) |
| 8 | + 1 Generic resource factory (`create_resource`) | 39 | shipped (v0.4.5) |
| 9 | `context/gather` aggregating endpoint (project + scene tree + recent errors in one round-trip) | 39 | shipped (v0.4.6) |
| 10 | + 6 UI / Control tools (`create_control`, `set_control_anchors`, `set_control_text`, `set_control_size`, `list_ui_hierarchy`, `create_theme`); Window dialog support | 46 | shipped (v0.5.1) |
| 11 | + 3 Structured runtime-event observation (`start_runtime_observation`, `stop_runtime_observation`, `get_runtime_events`) — cursored, fingerprinted error stream parsed from active play-session stderr | 49 | shipped (v0.5.2) |
| 12 | + 4 Lighting & WorldEnvironment (`set_light_properties`, `get_light_info`, `set_world_environment`, `get_world_environment`) — mutate/read existing lights and the scene's sky / ambient / fog / tonemap / glow / SSAO | 53 | shipped (v0.5.3) |
| 13 | `run_project` auto-saves the edited scene before spawning + refuses duplicate concurrent sessions (prevents stale-disk and double-window footguns) | 53 | shipped (v0.5.4) |
| 14 | Diagnostics workflow hardening: `get_runtime_events` gains `wait_ms` (blocking poll up to 5s so the first call after `run_project` doesn't beat the subprocess to `_ready`); `stop_project` accepts either `session_id` or `pid` and tolerates the model's "pid 23696" string mangling | 53 | shipped (v0.5.5) |
| 15 | Parser catches Godot 4 `USER ERROR:` prefix (was matching Godot 3's `USER SCRIPT ERROR:` only, silently dropping every `push_error` event); `get_runtime_events` adds `raw_stderr_bytes` + `raw_stderr_tail` self-diagnosis fields so an empty response distinguishes "parser missed a prefix" from "subprocess wrote nothing" | 53 | shipped (v0.5.6) |
| 16 | `get_runtime_events` message field surfaces the byte-count diagnostic inline so it can't be missed by models that only quote `message` back | 53 | shipped (v0.5.7) |

### New in Phase 3

- **Live play session loop** — `run_project` spawns a headless Godot
  subprocess; `get_debug_output` drains stdout/stderr non-blockingly;
  `stop_project` kills the session. Differentiates vs the dominant
  competitor (godot-mcp), which can't run a play session and keep an
  editor alive — they have to relaunch Godot per tool call.
- **Godot 4.4+ UID handling** — `get_uid` and `update_project_uids`
  (port from godot-mcp with MIT attribution, see [NOTICE](../NOTICE)).
  Version-gated; older engines see a structured "requires Godot 4.4+"
  error.
- **Service layer** — read-only mode (`GLADEKIT_GODOT_READ_ONLY=1`),
  per-session error tracker (`diagnostics/recent_errors` endpoint),
  demo-asset write guard, pre-mutation file backups in
  `<project>/.gladekit-backups/`, editor context gatherer.
- **Args normalization** — camelCase keys (`nodePath`, `parentPath`)
  are automatically rewritten to snake_case before tool dispatch.
- **Structured errors with hints** — most failures now return
  `possible_solutions: [...]` so the agent has next-step suggestions
  rather than just a single error string.

### New in Phase 5

- **Signal wiring tools (3)** — `connect_signal`, `list_signal_connections`,
  `disconnect_signal`. Editor-time, scene-saved (CONNECT_PERSIST) signal
  connections — the same kind you'd otherwise create through the editor's
  Node panel. `list_signal_connections` with `response_format="detailed"`
  also lists every signal *declared* on the node, so the agent can plan
  a connection without a second tool call. Suggestions use edit-distance
  matching so a 1-character typo (`timeput` instead of `timeout`) surfaces
  the right name.

### New in Phase 6

- **`get_project_info`** — single-call snapshot of "what is this Godot
  project?" Returns project name, Godot version, renderer, main scene,
  currently edited scene, scene/script/resource counts, enabled addons,
  and (with `response_format="detailed"`) bounded file listings, top-level
  directories, and the project's custom input actions. Replaces the 4-5
  exploratory tool calls an agent typically makes when dropped into an
  unfamiliar project. File walk is bounded (50 scenes / 50 scripts / 30
  resources / 5000 entries hard cap) so the call stays fast even on
  pathological projects.

### New in v0.4.4

- **`set_node_resource`** — assign a Resource loaded from a `res://` path to
  any Resource-typed property on a node: a `Mesh` onto `MeshInstance3D.mesh`,
  a `Texture2D` onto `Sprite2D.texture`, a `Shape3D` onto
  `CollisionShape3D.shape`, an `AudioStream` onto `AudioStreamPlayer.stream`,
  and so on. One consolidated tool instead of a separate `assign_*` per
  resource kind. Validates that the property exists and is resource-typed,
  enforces the property's declared built-in class, and on a wrong property
  name returns the node's resource-typed properties as recovery hints. Pass
  `resource_path=""` to clear a property.
- **`readOnlyHint` tool annotations** — the 12 read-only tools (queries,
  hierarchy/script reads, console/debug reads, `get_project_info`,
  `list_signal_connections`) now advertise the MCP `readOnlyHint` annotation
  so clients like Claude Code can auto-approve them without a per-call
  confirmation prompt. (Also fixes two read-only tools that were missing from
  the read-only-mode allow-list.)

### New in v0.4.5

- **`create_resource`** — generic factory for any concrete `Resource`
  subclass. Composition partner to `set_node_resource`: create the `.tres`
  here, then assign it there. Handles `BoxMesh`/`SphereMesh`/`PlaneMesh`,
  every `Shape3D` (`BoxShape3D`, `SphereShape3D`, `CapsuleShape3D`, …),
  `Curve`/`Curve2D`/`Curve3D`, `Environment`, `AudioStream` subclasses,
  `Gradient`/`GradientTexture*`, and so on. Refuses `Material`/`Script`
  types with a redirect to `create_material`/`create_script` so the three
  resource creators stay cleanly partitioned. On unknown class names returns
  up to 5 edit-distance-ranked suggestions; on abstract types returns
  concrete subclasses. Properties are validated against the resource's
  declared schema — typos land in `unapplied_properties` with a reason so
  the agent can retry against the right key.

### New in v0.4.6

- **`context/gather` endpoint** — single round-trip orientation snapshot.
  Aggregates `get_project_info` (detailed), `get_scene_tree` (including the
  flat `tree_text` view), and the recent-error history into one response.
  Previously, a first-turn orientation cost 2–3 separate `tools/execute`
  calls; clients that bridge an agent loop to this endpoint can replace all
  of those with one call. Sub-fetch failures degrade gracefully — an
  optional per-source `errors` map appears alongside whichever data
  succeeded, so the caller never gets a hard failure on this best-effort
  path. Args: `project_response_format` ("concise" | "detailed"),
  `scene_max_depth` (int), `errors_limit` (int, default 10, 0 = skip).

## Requirements

- Godot **4.3** or newer
- Editor mode (the bridge is editor-only and never runs in exported games)

## Install

1. Copy `addons/com.gladekit.mcp-bridge/` into your Godot project's
   `addons/` directory. The final path should be:
   ```
   <your-project>/addons/com.gladekit.mcp-bridge/plugin.cfg
   ```
2. In Godot, open **Project → Project Settings → Plugins**.
3. Enable **GladeKit MCP Bridge**.
4. Confirm the bridge is up: the editor Output panel should print
   ```
   [GladeKit MCP Bridge] listening on ws://127.0.0.1:8766  (v0.5.7, 53 tools registered, thread-polled at 200Hz)
   ```

The server stops automatically when you disable the plugin or close Godot.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `GLADEKIT_GODOT_BRIDGE_PORT` | `8766` | Override the listen port if 8766 is taken. Set in your shell *before* launching Godot. |

If the bridge fails to bind (port already in use, etc.) it prints a clear
error to the editor's Errors panel and to stdout with the env-var override
instructions.

## Wire protocol

All traffic is JSON text frames over a single WebSocket connection.
Connect to `ws://127.0.0.1:8766/` (no path routing — the endpoint lives
inside the message).

### Request

```json
{
  "id": "req-1",
  "endpoint": "health" | "tools/list" | "tools/execute",
  "toolName": "get_scene_tree",
  "arguments": {"max_depth": 50}
}
```

- `id` — opaque string, echoed verbatim on the response. Use it to
  correlate requests with responses when pipelining.
- `endpoint` — required.
- `toolName` — required for `tools/execute`.
- `arguments` — optional. Accepts either a JSON object (recommended) or a
  JSON-encoded string (matches the Unity bridge wire shape).

### Response

```json
{
  "id": "req-1",
  "success": true,
  "message": "Scene tree retrieved",
  "tree": { ... },
  "node_count": 12
}
```

On error:

```json
{
  "id": "req-1",
  "success": false,
  "error": "Unknown tool 'foo'",
  "message": "Unknown tool 'foo'"
}
```

### Endpoints

| Endpoint | Purpose | Response payload |
| --- | --- | --- |
| `health` | Liveness + version probe | `status`, `bridgeVersion`, `bridgeKind` (`"godot-mcp"`), `godotVersion`, `engineMode` (`"edit"` \| `"play"`), `toolCount` |
| `tools/list` | List registered tool names | `tools: [String]` |
| `tools/execute` | Run a named tool | Tool-specific. Always carries `success` and `message`. |
| `diagnostics/recent_errors` | Recent tool failures for retry context | `errors: [{timestamp_ms, tool_name, error, args_keys}]`, `total` (set `limit: int` in request, default 10) |
| `context/gather` (v0.4.6+) | One-shot orientation snapshot | `project` (from `get_project_info`), `scene_tree` (`tree` + `tree_text` + `scene_path` + `node_count`), `recent_errors` (list). On per-source failure adds an `errors` map keyed by `"project"` \| `"scene_tree"` while still returning whatever succeeded. Args: `project_response_format`, `scene_max_depth`, `errors_limit`. |

### Play-mode safety

Tools declare `requires_edit_mode = true/false`. The bridge refuses to
dispatch any `requires_edit_mode = true` tool while Godot is playing the
scene, returning a structured error. Read-only tools (queries, hierarchy
reads, console-log reads) run in either mode.

## Architecture

```
                    ws://127.0.0.1:8766
External client ─────────────────────────────► WebSocketPeer
(MCP server,                                       │
 desktop app,                                      ▼
 benchmark)                                  ws_server.gd
                                                   │  (main-thread _process tick)
                                                   ▼
                                            tool_registry.gd
                                                   │  (explicit registration)
                                                   ▼
                                            tools/implementations/**/*.gd
                                                   │
                                                   ▼
                                            Godot editor APIs
                                            (EditorInterface, etc.)
```

- **Transport:** `TCPServer` + `WebSocketPeer.accept_stream()`. Plain
  WebSocket text frames; no multiplayer/RPC framing.
- **Threading:** all dispatch happens on the editor main thread inside
  `_process()`. Godot scene-tree APIs are not thread-safe, and per-tick
  polling is plenty fast for tool calls (network RTT dominates).
- **Hot reload:** Godot reloads addons whenever a script in the addon
  changes. The plugin's `_exit_tree()` closes peers and stops the TCP
  server cleanly so `_enter_tree()` can re-bind on the next reload without
  hitting `ERR_ALREADY_IN_USE`.

## Adding a tool

1. Create `tools/implementations/<category>/<tool_name>.gd`:

   ```gdscript
   extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

   const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

   func _init() -> void:
       tool_name = "my_new_tool"
       requires_edit_mode = true  # false for read-only tools

   func execute(args: Dictionary) -> Dictionary:
       var path: String = ToolUtils.parse_path_arg(args, "path")
       if path.is_empty():
           return ToolUtils.error("'path' is required")
       # ... do editor work ...
       return ToolUtils.success("Done", {"result": some_value})
   ```

2. Register it in `bridge/tool_registry.gd`:

   ```gdscript
   const MyNewTool = preload("res://addons/com.gladekit.mcp-bridge/tools/implementations/<cat>/my_new_tool.gd")
   # ...inside _register_all():
   register_tool(MyNewTool.new())
   ```

3. Use **typed GDScript** for arg parsing and return shapes. Use the
   `ToolUtils` helpers — they coerce loose JSON types (int/float/string
   for numbers, etc.) defensively.

4. Tools must return a `Dictionary` matching `ToolUtils.success(...)` /
   `ToolUtils.error(...)`.

## Known limitations (Phase 1)

- **`tools/execute` latency is gated by editor frame rate when Godot is
  unfocused.** The worker thread handles WS accept/poll/send/health/list
  on its own loop (~200Hz), so transport-layer p99 stays under 10ms
  regardless of focus state. But `tools/execute` requires main-thread
  dispatch (the editor's scene tree is not thread-safe), and Godot's
  editor throttles its main loop hard when unfocused — typically 20Hz,
  which puts per-tool latency at ~50–100ms. Focused Godot runs at the
  editor's normal ~145Hz and tool latency drops accordingly. To be
  addressed in a later phase (likely a worker-thread→main-thread
  signaling mechanism that wakes the editor on demand).

- **Single connection at a time is typical.** The server accepts multiple
  concurrent peers, but tool dispatch is serialized through a single
  main-thread queue. For agentic workloads this is fine; batched-tool
  parallelism is out of scope for Phase 1.

## License

MIT.
