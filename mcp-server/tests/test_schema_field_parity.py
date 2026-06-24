"""Field-name parity guard for the Unity and Godot tool catalogs.

Companion to the name-parity guards in test_registry.py / test_registry_godot.py.
Those prove every tool *name* matches between schema and bridge; this one proves
every tool *argument* does.

Why it matters
--------------
A tool's arguments are forwarded to the bridge under the exact field names the
schema declares. If a schema advertises an argument the bridge never reads, the
agent sends it, the tool reports success, and the value is silently ignored —
the worst kind of bug, because every other check still passes ("the tool ran").

The check
---------
For every tool schema, every field name (top-level plus recursively-nested
object / array-item properties) must appear as a quoted literal somewhere in the
bridge source. "Somewhere in the bridge" (rather than "in this tool's own file")
avoids false positives for tools that delegate argument parsing to a shared
helper.

The two engines differ in how keys reach a tool, so the match differs:

* Unity does no key normalization — each tool reads exact dict keys — so a schema
  field must appear verbatim in the C# source.
* Godot's ws_server runs ``ToolUtils.normalize_args`` on every request, folding
  TOP-LEVEL camelCase keys to snake_case before a tool reads them (nested dict
  keys are not recursed into). So a top-level field counts as read if the bridge
  reads it verbatim OR reads its camel->snake form; nested fields must match
  exactly. A Godot failure therefore means a genuinely wrong argument name, not
  merely a camelCase/snake_case spelling difference (unless it is nested).

Each engine's test skips automatically when that bridge's sources are not
present (e.g. the package installed standalone without a bundled bridge).
"""

from __future__ import annotations

from pathlib import Path

import pytest

from gladekit_mcp.schemas.godot import get_godot_tool_schemas
from gladekit_mcp.tools import get_unity_tool_schemas

# Tools the agent sees but that are NOT dispatched to the engine bridge, so they
# have no bridge-side argument reads and are exempt from this check:
#   find_asset          — answered by the server against the bundled asset
#                         catalog, no bridge round-trip.
#   request_user_input  — a meta tool the client consumes to prompt the user;
#                         it is never executed by the bridge.
# Add a tool here only if it is genuinely answered without reaching the bridge.
_NOT_DISPATCHED = {
    "find_asset",
    "request_user_input",
}

# (tool_name, field_name) pairs intentionally not read by the bridge. Each needs
# a one-line reason. Keep this tiny — it is for genuine exceptions, not unwired
# arguments.
_ALLOWED_UNREAD: set[tuple[str, str]] = {
    # Informational annotation the agent attaches to each queued change for its
    # own reasoning / the change log; execution only needs the tool name + args.
    ("apply_queued_fix", "rationale"),
}


def _find_dir(*relative_parts: str) -> Path | None:
    """Walk up from this file for a directory at the given relative path.

    Returns None when absent — the normal case for a standalone install without
    the bundled bridge sources; callers skip in that case.
    """
    target = Path(*relative_parts)
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        candidate = parent / target
        if candidate.is_dir():
            return candidate
    return None


def _iter_field_names(params: dict) -> list[tuple[str, int]]:
    """Yield (field_name, depth); depth 0 is a top-level argument."""
    out: list[tuple[str, int]] = []

    def walk(props, depth):
        if not isinstance(props, dict):
            return
        for fname, spec in props.items():
            out.append((fname, depth))
            if not isinstance(spec, dict):
                continue
            if isinstance(spec.get("properties"), dict):
                walk(spec["properties"], depth + 1)
            items = spec.get("items")
            if isinstance(items, dict) and isinstance(items.get("properties"), dict):
                walk(items["properties"], depth + 1)

    walk(params.get("properties"), 0)
    return out


def _camel_to_snake(s: str) -> str:
    """Mirror of ToolUtils._camel_to_snake in the Godot bridge."""
    out: list[str] = []
    for i, c in enumerate(s):
        if "A" <= c <= "Z":
            if i > 0:
                out.append("_")
            out.append(c.lower())
        else:
            out.append(c)
    return "".join(out)


def _read_source(root: Path, glob: str) -> str:
    return "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in root.rglob(glob))


def _violations(schemas, source: str, *, normalize: bool) -> list[str]:
    out: list[str] = []
    for tool in schemas:
        fn = tool["function"]
        name = fn["name"]
        if name in _NOT_DISPATCHED:
            continue
        for field, depth in _iter_field_names(fn.get("parameters", {})):
            if (name, field) in _ALLOWED_UNREAD:
                continue
            read = f'"{field}"' in source
            if not read and normalize and depth == 0:
                read = f'"{_camel_to_snake(field)}"' in source
            if not read:
                out.append(f"{name}.{field}")
    return out


_FIX_HINT = (
    "\n\nFix one of: (1) rename the schema field to match the bridge's args key, "
    "(2) wire the bridge tool to read it, (3) remove the dead field from the "
    "schema, or (4) if it is intentionally informational, add it to "
    "_ALLOWED_UNREAD with a reason."
)


def test_every_unity_schema_field_is_read_by_the_bridge() -> None:
    editor = _find_dir("unity-bridge", "Editor")
    if editor is None:
        pytest.skip("Unity bridge sources not present (installed without bundled bridge)")

    source = _read_source(editor, "*.cs")
    assert source, f"Read zero C# from {editor} — path/glob drift?"

    violations = _violations(get_unity_tool_schemas(), source, normalize=False)
    assert not violations, (
        "Schema fields the Unity bridge never reads (silent-drop risk):\n  "
        + "\n  ".join(sorted(violations))
        + _FIX_HINT
    )


def test_every_godot_schema_field_is_read_by_the_bridge() -> None:
    bridge = _find_dir("godot-bridge", "addons", "com.gladekit.mcp-bridge")
    if bridge is None:
        pytest.skip("Godot bridge sources not present (installed without bundled bridge)")

    source = _read_source(bridge, "*.gd")
    assert source, f"Read zero GDScript from {bridge} — path/glob drift?"

    violations = _violations(get_godot_tool_schemas(), source, normalize=True)
    assert not violations, (
        "Schema fields the Godot bridge never reads (silent-drop risk):\n  "
        + "\n  ".join(sorted(violations))
        + _FIX_HINT
        + "\nNote: top-level camelCase is auto-normalized by the bridge, so a "
        "violation means a genuinely wrong name (unless it is a nested field)."
    )
