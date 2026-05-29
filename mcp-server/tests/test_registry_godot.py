"""Parity guards for the Godot tool registry.

Two iron-rule invariants:
  1. Every tool name registered in the bridge has a schema in
     schemas/godot/.
  2. Every schema in schemas/godot/ corresponds to a real registered
     bridge tool.

Without this guard, the agent gets a tool description for something the
bridge can't execute (or executes a bridge tool the agent can't see).

The canonical bridge list lives in
  godot-bridge/addons/com.gladekit.mcp-bridge/bridge/tool_registry.gd
We parse the `register_tool(...)` lines at test time rather than mirroring
the list manually — drift in either direction surfaces as a failing test.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from gladekit_mcp.schemas.godot import (
    ALL_CATEGORIES,
    get_category_for_tool,
    get_godot_tool_names,
    get_godot_tool_schemas,
)

# ── Helpers ──────────────────────────────────────────────────────────────────


def _repo_root() -> Path | None:
    """The mcp-server/ package lives one level inside the monorepo. Walk up
    from this test file looking for godot-bridge/.

    Returns None when not found — that's the normal case in the published
    open-source repo, where mcp-server/ is synced WITHOUT godot-bridge/
    (the Godot bridge ships from its own repo). Callers skip in that case;
    the parity check is only meaningful in the monorepo where both halves
    are present.
    """
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / "godot-bridge").is_dir():
            return parent
    return None


def _bridge_tool_names() -> set[str]:
    """Parse tool_registry.gd to extract the canonical bridge tool name set.

    Each tool implementation .gd file sets `tool_name = "..."` in _init().
    Rather than parsing all 33 .gd files, we scan their files for that one
    line — robust and minimal.
    """
    root = _repo_root()
    if root is None:
        pytest.skip("Godot bridge sources not present (mcp-server synced without godot-bridge/)")
    impls_root = root / "godot-bridge" / "addons" / "com.gladekit.mcp-bridge" / "tools" / "implementations"
    if not impls_root.is_dir():
        pytest.skip(f"Godot bridge sources not present at {impls_root}")

    names: set[str] = set()
    # Match GDScript `tool_name = "snake_case_name"` exactly (no other
    # attribute uses that pattern in the codebase).
    pat = re.compile(r'^\s*tool_name\s*=\s*"([a-z_][a-z0-9_]*)"', re.MULTILINE)
    for gd in impls_root.rglob("*.gd"):
        text = gd.read_text(encoding="utf-8")
        for m in pat.finditer(text):
            names.add(m.group(1))
    return names


# ── Parity ───────────────────────────────────────────────────────────────────


def test_every_bridge_tool_has_a_schema():
    """If the bridge registers a tool, the schema package must describe it
    — otherwise the agent has no way to discover or call the tool."""
    bridge_names = _bridge_tool_names()
    schema_names = set(get_godot_tool_names())

    missing_schemas = bridge_names - schema_names
    assert not missing_schemas, (
        f"Bridge registers tools that schemas/godot/ does not describe: {sorted(missing_schemas)}. Add a schema entry."
    )


def test_every_schema_corresponds_to_a_bridge_tool():
    """If a schema is described, the bridge must register that name —
    otherwise the agent can call a tool that doesn't exist."""
    bridge_names = _bridge_tool_names()
    schema_names = set(get_godot_tool_names())

    orphan_schemas = schema_names - bridge_names
    assert not orphan_schemas, (
        f"schemas/godot/ describes tools that the bridge does not register: "
        f"{sorted(orphan_schemas)}. Either remove the schema or add the tool to "
        f"godot-bridge/.../bridge/tool_registry.gd."
    )


def test_tool_count_matches_canonical_33():
    """Phase 3 shipped exactly 33 tools. A change here is a real change —
    update both sides and bump the count."""
    bridge_names = _bridge_tool_names()
    assert len(bridge_names) == 33, (
        f"Expected 33 Godot bridge tools (Phase 3 catalog), got {len(bridge_names)}. "
        f"If the catalog grew or shrank, update this test and the schema package."
    )


# ── Schema shape ─────────────────────────────────────────────────────────────


def test_all_schemas_are_openai_function_format():
    """Every schema MUST be {"type": "function", "function": {name, description, parameters}}.
    Anything else breaks the OpenAI-format → MCP-tool conversion in registry.py."""
    for schema in get_godot_tool_schemas():
        assert schema["type"] == "function", f"Bad type: {schema}"
        func = schema["function"]
        assert "name" in func, f"Schema missing name: {schema}"
        assert "description" in func, f"Schema {func['name']} missing description"
        assert "parameters" in func, f"Schema {func['name']} missing parameters"
        params = func["parameters"]
        assert params.get("type") == "object", f"Schema {func['name']} params.type must be 'object'"
        assert "properties" in params, f"Schema {func['name']} params missing properties"


def test_no_duplicate_tool_names():
    """A duplicate name would silently drop the second registration. Catches
    a copy-paste typo across category modules."""
    names = get_godot_tool_names()
    duplicates = [n for n in set(names) if names.count(n) > 1]
    assert not duplicates, f"Duplicate Godot tool names across schemas: {duplicates}"


def test_required_args_documented():
    """Tools that declare a required arg in `parameters.required` must also
    have the arg defined in `parameters.properties`. Otherwise the JSON
    schema is internally inconsistent and the MCP client rejects it."""
    for schema in get_godot_tool_schemas():
        func = schema["function"]
        params = func["parameters"]
        required = params.get("required", [])
        props = params.get("properties", {})
        for arg in required:
            assert arg in props, (
                f"Tool {func['name']} declares required arg '{arg}' but does not define it in properties"
            )


# ── Category structure ──────────────────────────────────────────────────────


def test_all_categories_have_at_least_one_tool():
    """A registered category with zero tools is dead weight — and may
    indicate a botched move/rename."""
    for cat_name, tools in ALL_CATEGORIES:
        assert tools, f"Category {cat_name!r} has no tools"


def test_get_category_for_tool_resolves_known_tool():
    assert get_category_for_tool("get_scene_tree") == "scene"
    assert get_category_for_tool("create_script") == "script"
    assert get_category_for_tool("create_camera_3d") == "camera"
    assert get_category_for_tool("create_material") == "resource"
    assert get_category_for_tool("create_physics_body") == "physics"
    assert get_category_for_tool("create_scene") == "scene_io"
    assert get_category_for_tool("run_project") == "runtime"
    assert get_category_for_tool("get_uid") == "uid"


def test_get_category_for_tool_returns_empty_for_unknown():
    assert get_category_for_tool("definitely_not_a_real_tool_xyz") == ""
