# GladeKit MCP Bridge — Tests

Phase 2 test coverage for the Godot bridge. Tests are written for
[GUT (Godot Unit Test)](https://github.com/bitwes/Gut) v9+.

## Layout

```
tests/
├── unit/                  # Pure logic — no editor / scene tree access required
│   ├── test_tool_utils.gd
│   └── test_tool_registry.gd
├── integration/           # Requires a running Godot editor and edited scene
│   ├── test_scene_node_tools.gd
│   ├── test_script_tools.gd
│   └── test_hot_reload.gd
└── README.md
```

## Running tests

1. **Install GUT** as a project addon (it is intentionally not bundled with
   the bridge — GUT is dev-only and shouldn't ship to OSS users). The
   bitwes/Gut repo nests its plugin at `addons/gut/` inside the repo root,
   so flatten one level after cloning:

   ```bash
   git clone --depth 1 --branch v9.4.0 https://github.com/bitwes/Gut.git godot-bridge/addons/_gut_repo
   mv godot-bridge/addons/_gut_repo/addons/gut godot-bridge/addons/gut
   rm -rf godot-bridge/addons/_gut_repo
   ```

2. **Apply the GUT 4.6 patch** — required on Godot 4.6+. GUT 9.4 reads
   `debug/gdscript/warnings/exclude_addons` and `debug/gdscript/warnings/enable`
   via `ProjectSettings.get(key)`, which returns null on 4.6 when the key
   isn't explicitly set in `project.godot`. Godot 4.6 refuses to assign
   null to a typed `bool`, so GUT fails its static-init and the panel
   never opens. We can't set the keys in `project.godot` because Godot
   strips defaults on save. Run the patch script:

   ```powershell
   # From repo root (Windows):
   pwsh scripts/patch-gut-for-godot-46.ps1
   ```

   The script is idempotent — safe to re-run. It rewrites two
   `ProjectSettings.get(...)` calls to `ProjectSettings.get_setting(..., true)`
   so the default flows through.

3. **Open `godot-bridge/`** in Godot 4.6+.
4. **Enable GUT**: Project Settings → Plugins → enable **Gut** (the
   GladeKit MCP Bridge addon is already enabled).
5. **Run all tests**: GUT panel (bottom dock) → "Run All".
6. **Run a single test file**: GUT panel → click the file, then "Run Selected".

The bridge addon itself must be enabled while integration tests run (the
test fixtures rely on it being loaded). The dev `project.godot` shipped
with this folder already enables it.

## Headless / CI

The pure unit tests under `tests/unit/` can be run headlessly:

```
godot --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/unit/ -gexit
```

Integration tests under `tests/integration/` require an editor session
(they touch `EditorInterface`). They can be exercised via:

```
godot --editor --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/integration/ -gexit
```

CI wiring is deferred to Phase 4 / Phase 5 per the
[Godot support phase plan](../../docs/designs/godot-support.md).

## Integration tests + GUT's runner

GUT 9 runs tests via `EditorInterface.play_custom_scene()`, which executes
test scripts in **game-runtime mode** — `EditorInterface` itself is
unreachable from there. This is fine for unit tests (pure logic / parser /
WS-layer probes), but every integration test in `tests/integration/` needs
the bridge's tools to be able to call `EditorInterface.get_edited_scene_root()`
and similar editor-only APIs. Those tests cannot work under GUT's runner.

The integration test files use `should_skip_script()` (GUT 9's whole-file
skip hook) to detect the missing editor context and skip cleanly with a
clear `risky` message instead of crashing the runner:

```gdscript
func should_skip_script():
    if ToolUtils.get_edited_scene_root_safe() == null:
        return "requires editor context (skipped under GUT play_custom_scene; verify by driving the bridge through an MCP client with the editor open)"
    return false
```

The exception is `test_ws_e2e.gd`, where most tests probe the WS layer
itself (health, tools/list, malformed JSON, etc.) and DO work in any
context. The two tests in that file that call into editor-only tools
(`test_tools_execute_round_trip_read_only`, `test_context_gather_atomic_*`)
use per-test `pending()` gates instead of skipping the whole file.

**Where the actual integration coverage comes from:** driving the bridge
end-to-end through any MCP client (Cursor, Claude Code, Windsurf, etc.)
with the Godot editor open exercises every tool against a real edited
scene. The bridge's hardening + safe helpers
(`ToolUtils.get_edited_scene_root_safe` etc.) ensure the same code paths
used by integration tests also tolerate the no-editor case in production
— that's the actual product behavior the tests are meant to
verify.

## Coverage

Per [docs/designs/godot-support.md](../../docs/designs/godot-support.md)
Phase 2 exit criteria each tool implementation has at minimum:

- **Happy path** — successful execution returns `success: true` and the
  expected response payload shape.
- **Missing required arg** — returns `success: false`, does not crash.
- **Wrong-type arg** — returns `success: false` or a sensible coerced
  default, does not crash.

`test_hot_reload.gd` verifies the Phase 1 exit-tree socket-release
behavior: the WS server must release port 8766 cleanly when the addon
hot-reloads, so the next `_enter_tree()` can re-bind without
`ERR_ALREADY_IN_USE`.
