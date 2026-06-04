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
    GODOT_READ_ONLY_TOOLS,
    get_category_for_tool,
    get_godot_tool_names,
    get_godot_tool_schemas,
)
from gladekit_mcp.tools.registry import _build_tool_list

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


def _bridge_read_only_tools() -> set[str]:
    """Parse the bridge's authoritative READ_ONLY_TOOLS const from
    services/read_only_guard.gd.

    The const is a typed Array[String] literal; we extract every quoted
    string between the `const READ_ONLY_TOOLS ... [` opener and its closing
    `]`. Skips (like the parity tests above) when the bridge sources aren't
    present in the synced OSS layout.
    """
    root = _repo_root()
    if root is None:
        pytest.skip("Godot bridge sources not present (mcp-server synced without godot-bridge/)")
    guard = root / "godot-bridge" / "addons" / "com.gladekit.mcp-bridge" / "services" / "read_only_guard.gd"
    if not guard.is_file():
        pytest.skip(f"Godot bridge sources not present at {guard}")

    text = guard.read_text(encoding="utf-8")
    # Anchor on `= [` so the `[` inside the `Array[String]` type annotation
    # doesn't terminate the match; the array body holds only quoted strings +
    # comments, so the first `]` after `= [` is the real closer.
    block = re.search(r"READ_ONLY_TOOLS[^=]*=\s*\[(.*?)\]", text, re.DOTALL)
    assert block, "Could not locate READ_ONLY_TOOLS array literal in read_only_guard.gd"
    return set(re.findall(r'"([a-z_][a-z0-9_]*)"', block.group(1)))


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


def test_tool_count_matches_canonical_catalog():
    """Phase 3 shipped 33 tools; Phase 5 added 3 signal tools → 36;
    get_project_info added → 37; set_node_resource added → 38; create_resource
    added → 39; list_assets added → 40; v0.5.0 added 6 UI/Control tools → 46;
    v0.5.2 added 3 structured runtime-event observation tools
    (start/stop_runtime_observation + get_runtime_events) → 49;
    v0.5.3 added 4 lighting/environment tools (set_light_properties +
    get_light_info + set_world_environment + get_world_environment) → 53;
    v0.6.0 added 5 animation tools (add_animation_to_player +
    add_animation_track + add_animation_keyframe + set_animation_properties
    + get_animation_player_info) → 58. A change here is a real change —
    update this test and the schema package together."""
    bridge_names = _bridge_tool_names()
    expected = 58
    assert len(bridge_names) == expected, (
        f"Expected {expected} Godot bridge tools, got {len(bridge_names)}. "
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


# ── Read-only annotations (Tier 1B) ───────────────────────────────────────────


def test_read_only_set_matches_bridge_guard():
    """GODOT_READ_ONLY_TOOLS must equal the bridge's authoritative
    READ_ONLY_TOOLS const. If they drift, a tool gets a wrong/missing
    readOnlyHint relative to what the bridge actually enforces in read-only
    mode — exactly the kind of silent mismatch this guard exists to catch."""
    assert set(GODOT_READ_ONLY_TOOLS) == _bridge_read_only_tools(), (
        "GODOT_READ_ONLY_TOOLS (schemas/godot/__init__.py) and the bridge's "
        "READ_ONLY_TOOLS (services/read_only_guard.gd) have drifted. Update both."
    )


def test_read_only_tools_are_real_godot_tools():
    """Every name in the read-only set must be an actual registered tool —
    a typo would annotate nothing and silently pass elsewhere."""
    schema_names = set(get_godot_tool_names())
    unknown = set(GODOT_READ_ONLY_TOOLS) - schema_names
    assert not unknown, f"Read-only set names not present in schemas: {sorted(unknown)}"


def test_read_only_tools_get_readonly_hint_annotation():
    """Each read-only Godot tool's MCP definition must carry
    annotations.readOnlyHint == True so clients can auto-approve it."""
    tools, _ = _build_tool_list(get_godot_tool_schemas(), GODOT_READ_ONLY_TOOLS)
    by_name = {t.name: t for t in tools}
    for name in GODOT_READ_ONLY_TOOLS:
        tool = by_name[name]
        assert tool.annotations is not None, f"{name} should carry annotations"
        assert tool.annotations.readOnlyHint is True, f"{name} should have readOnlyHint=True"


def test_mutating_tools_have_no_readonly_hint():
    """Mutating tools (everything not in the read-only set) must NOT advertise
    readOnlyHint — otherwise a client auto-approves a project-modifying call.
    run_project / stop_project / launch_editor are explicitly checked here:
    they're play-mode-safe but have side effects, so they are NOT read-only."""
    tools, _ = _build_tool_list(get_godot_tool_schemas(), GODOT_READ_ONLY_TOOLS)
    for tool in tools:
        if tool.name in GODOT_READ_ONLY_TOOLS:
            continue
        hint = None if tool.annotations is None else tool.annotations.readOnlyHint
        assert hint is not True, f"{tool.name} is mutating but advertises readOnlyHint=True"
    # Spot-check the three deceptive ones explicitly.
    by_name = {t.name: t for t in tools}
    for name in ("run_project", "stop_project", "launch_editor"):
        hint = None if by_name[name].annotations is None else by_name[name].annotations.readOnlyHint
        assert hint is not True, f"{name} must not be marked read-only"
