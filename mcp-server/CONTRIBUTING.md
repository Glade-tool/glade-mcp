# Contributing to GladeKit MCP

Thanks for your interest in contributing! `gladekit-mcp` is a Python MCP server that drives both the Unity and Godot editor bridges. This guide covers everything you need to get a tool change reviewed and merged.

## Setup

```bash
# Clone the repo
git clone https://github.com/Glade-tool/glade-mcp.git
cd glade-mcp/mcp-server

# Install dev dependencies (ruff lives in the dev extra, so this is required
# before you run lint or format below).
uv sync --extra dev
```

## Pre-push checklist

Run all of these before pushing — the OSS Release workflow runs the same suite on every tag push, and a failure burns a published version number you can't reuse.

```bash
uv sync --extra dev          # required first; ruff lives in the dev extra
uv run ruff check .          # lint
uv run ruff format --check . # formatting
uv run pytest -q             # full test suite (234+ tests, ~100 seconds)
```

All four must pass. `ruff format --check .` is non-mutating; if it reports drift, run `uv run ruff format .` to fix it, then re-run.

## Development workflow

1. **Fork the repo** and create a feature branch from `main`.
2. **Make your changes** — keep commits focused and atomic.
3. **Run the pre-push checklist** above.
4. **Open a pull request** against `main` with a clear description of what changed and why.

## Adding a new tool

Both engines follow the same shape: a bridge-side implementation in the engine's native language plus a Python schema in `mcp-server/`. A parity test asserts the bridge registry and the schema package agree on tool names — drift in either direction fails CI.

### Adding a Unity tool

**1. C# implementation** (`unity-bridge/Editor/Tools/Implementations/<Category>/MyTool.cs`):

```csharp
public class MyTool : ITool
{
    public string Name => "my_tool";
    public string Execute(Dictionary<string, object> args)
    {
        // ... Unity Editor API calls ...
        return ToolUtils.CreateSuccessResponse("Done", extras);
    }
}
```

**2. Python schema** (`mcp-server/src/gladekit_mcp/schemas/unity/<category>.py`):

Add an entry to the category's tool list following the existing OpenAI function-calling format. Keep descriptions precise — the AI reads them to decide when to call the tool.

Tools are auto-discovered via reflection at startup — no manual registration needed beyond those two files.

### Adding a Godot tool

**1. GDScript implementation** (`godot-bridge/addons/com.gladekit.mcp-bridge/tools/implementations/<category>/my_tool.gd`):

```gdscript
extends "res://addons/com.gladekit.mcp-bridge/tools/i_tool.gd"

const ToolUtils = preload("res://addons/com.gladekit.mcp-bridge/bridge/tool_utils.gd")

func _init() -> void:
    tool_name = "my_tool"
    requires_edit_mode = true  # false for read-only tools

func execute(args: Dictionary) -> Dictionary:
    var missing := ToolUtils.require_string(args, "node_path")
    if not missing.is_empty():
        return ToolUtils.error(missing)
    # ... Godot Editor API calls ...
    return ToolUtils.success("Done", {"extra": "field"})
```

**2. Bridge registration** (`godot-bridge/addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd`):

Add a `const` and a `register_tool(...)` line — registration is explicit (no reflection) so a missing line fails loudly.

**3. Python schema** (`mcp-server/src/gladekit_mcp/schemas/godot/<category>.py`):

Add the OpenAI-format schema entry. The Godot schemas package's `__init__.py` imports each category module by name.

### Tool-design guidelines

- Tool names use `snake_case` and must match exactly between the bridge implementation and the Python schema.
- Errors should return `success: false` with a clear `error` field, and where the agent could plausibly self-correct, a `possible_solutions: [...]` array (the existing `connect_signal` tool uses Levenshtein-based suggestions for typos — feel free to reuse the pattern).
- Read-only tools (those that don't mutate scene/script state) should set `requires_edit_mode = false` so they remain callable while the user is playing the scene.

## Debugging the bridge

The `mcp-server` ships a Python bridge module (`gladekit_mcp.bridge`) for talking to a live editor without a full MCP client in the loop. Useful when a tool isn't behaving the way the schema implies.

For the Godot bridge specifically, a minimal manual probe:

```python
import asyncio, json, websockets

async def main():
    async with websockets.connect("ws://127.0.0.1:8766") as ws:
        # Health check
        await ws.send(json.dumps({"id": "1", "endpoint": "health"}))
        print(await ws.recv())

        # Call a specific tool with args
        await ws.send(json.dumps({
            "id": "2",
            "endpoint": "tools/execute",
            "toolName": "get_scene_tree",
            "arguments": {},
        }))
        print(await ws.recv())

asyncio.run(main())
```

Run from `mcp-server/` so the dev `websockets` dependency is on the path (`uv run python smoke.py`). The Unity bridge speaks the same `tools/execute` shape on port 8765 over HTTP.

## Bridge version bumps

If your change requires a new bridge version (e.g. you added a tool the schema package now expects), three pins must move together:

- `godot-bridge/addons/com.gladekit.mcp-bridge/plugin.cfg` `version` (or `unity-bridge/package.json` `version` for Unity)
- `mcp-server/src/gladekit_mcp/godot_bridge_version.py` `MIN_GODOT_BRIDGE_VERSION` (Godot)
- `mcp-server/src/gladekit_mcp/bridge_version.py` `MIN_BRIDGE_VERSION` (Unity)

`tests/test_godot_version_lockstep.py` enforces the Godot lockstep at pre-push time. The Unity lockstep is enforced by the matching tests in the same directory.

## Code style

- Python 3.10+, async/await throughout
- Formatted with `ruff format`, linted with `ruff check`
- Type hints on all public functions
- Line length: 120 characters

## Testing

- Unit tests live in `tests/` and use `pytest` + `pytest-asyncio`. Most Unity tests mock the HTTP bridge; Godot tests mock the WebSocket bridge so neither editor needs to be running.
- Schema-vs-bridge parity is enforced by `tests/test_registry.py` (Unity) and `tests/test_registry_godot.py` (Godot). Adding a tool without updating both sides will fail the parity test.
- The `eval/` directory contains a Claude-based evaluation harness with category-tagged prompts. New tools that change the agent's behavior should add at least one eval case.

## Reporting issues

Open an issue on GitHub with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, Python version, Unity / Godot version, AI client)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
