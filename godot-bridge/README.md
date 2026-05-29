# GladeKit MCP Bridge for Godot

Local WebSocket server that lives inside the Godot 4 editor and exposes
scene, node, script, and resource tools so AI assistants can read and modify
the active project. Designed to be addressed by an MCP server (for use with
Cursor, Claude Code, Windsurf, and similar) or by the GladeKit desktop app.

**Status:** Phase 3 — 33 tools registered. MVP catalog complete.

| Phase | Tools | Cumulative | Status |
| --- | --- | --- | --- |
| 1 | `get_scene_tree` | 1 | shipped (v0.1.0) |
| 2 | + 9 Scene/Node, + 5 Script | 15 | shipped (v0.2.0) |
| 3 | + 2 Camera/Light, + 2 Resource, + 1 Physics, + 4 Scene I/O, + 7 Runtime/process (incl. `run_project`/`stop_project`/`get_debug_output` + `launch_editor`), + 2 UID (4.4+) | 33 | shipped (v0.3.0) |

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
   [GladeKit MCP Bridge] listening on ws://127.0.0.1:8766  (v0.3.0, 33 tools registered, thread-polled at 200Hz)
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
