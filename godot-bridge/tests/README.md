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
   the bridge — GUT is dev-only and shouldn't ship to OSS users):
   - Clone or copy [bitwes/Gut](https://github.com/bitwes/Gut) into
     `godot-bridge/addons/gut/`.
   - Open `godot-bridge/` in Godot 4.3+.
   - Project Settings → Plugins → enable **Gut**.
2. **Run all tests**: GUT panel (bottom dock) → "Run All".
3. **Run a single test file**: GUT panel → click the file, then "Run Selected".

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
