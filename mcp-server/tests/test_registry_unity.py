"""Parity guards for the Unity tool registry.

Three iron-rule invariants:
  1. Every C# tool class that declares a snake_case ``Name`` is actually
     registered with the bridge's tool registry. An unregistered tool
     compiles cleanly and may even have a schema, but every call fails at
     runtime with "Tool was blocked from executing or null." — the
     silently-dead-tool failure mode this guard exists to catch.
  2. Every tool the bridge registers has a schema in tools/ — otherwise
     the agent has no way to discover or call the tool.
  3. Every schema corresponds to a real bridge tool — otherwise the agent
     can call a tool that doesn't exist.

Unlike the Godot bridge (one tool_registry.gd, guarded by
test_registry_godot.py), Unity registration is spread across C# registrar
files, so this guard parses two things at test time rather than mirroring
any list manually: ``Name => "..."`` declarations in the tool
implementations, and ``Register...(new <Class>())`` calls in the
registrars. Drift in any direction surfaces as a failing test that names
the offender.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from gladekit_mcp.tools import get_unity_tool_schemas

# Bridge-registered but deliberately absent from the agent schemas. Empty now
# that the playability probe is offered to the model (the boot-only mode backs
# the Unity play-verify gate). Keep the set + guard: it pins each exemption to
# a real one-sided state, so future harness-only tools are documented here.
_HARNESS_ONLY_TOOLS: set = set()

# Schema-described but with no C# implementation — legitimate "orphan
# schemas", exempt from the orphan check:
#   - find_asset: answered by the MCP server itself from the bundled asset
#     catalog, no bridge round-trip (see _handle_find_asset_locally in
#     tools/registry.py).
#   - request_user_input: an interaction tool — the answer comes from the
#     human through the hosting client, not from the engine bridge.
_LOCALLY_HANDLED_TOOLS = {"find_asset", "request_user_input"}

# ── Helpers ──────────────────────────────────────────────────────────────────


def _repo_root() -> Path | None:
    """The mcp-server/ package normally ships alongside unity-bridge/; walk
    up from this test file looking for it.

    Returns None when not found — the case for a standalone install of the
    mcp-server package (e.g. from a source tarball) where the engine
    sources aren't present. Callers skip in that case; the parity check is
    only meaningful in a checkout that carries both halves.
    """
    here = Path(__file__).resolve()
    for parent in [here, *here.parents]:
        if (parent / "unity-bridge").is_dir():
            return parent
    return None


def _editor_dir() -> Path:
    root = _repo_root()
    if root is None:
        pytest.skip("Unity bridge sources not present (standalone mcp-server install)")
    editor = root / "unity-bridge" / "Editor"
    if not editor.is_dir():
        pytest.skip(f"Unity bridge sources not present at {editor}")
    return editor


# Each ITool declares its wire name via an expression-bodied property:
#   public string Name => "create_material";
_NAME_RE = re.compile(r'Name\s*=>\s*"([a-z0-9_]+)"')
_CLASS_RE = re.compile(r"\bclass\s+(\w+)")
# Matches both registrar forms:
#   Register(new CreateMaterialTool());          (core registrars)
#   ToolExecutor.RegisterExternal(new ...());    (SRP assembly)
_REGISTER_RE = re.compile(r"\bRegister\w*\(\s*new\s+([\w.]+)\s*\(")


def _implemented_tools() -> dict[str, str]:
    """Map tool name -> implementing class name, from ``Name => "..."``.

    The owning class is the nearest ``class`` declaration above the Name
    property — correct for one-class-per-tool files and for files that
    also carry nested helper types.
    """
    tools: dict[str, str] = {}
    for cs in _editor_dir().rglob("*.cs"):
        text = cs.read_text(encoding="utf-8")
        classes = [(m.start(), m.group(1)) for m in _CLASS_RE.finditer(text)]
        if not classes:
            continue
        for m in _NAME_RE.finditer(text):
            owner = None
            for pos, cls in classes:
                if pos > m.start():
                    break
                owner = cls
            if owner is not None:
                tools[m.group(1)] = owner
    return tools


def _registered_class_names() -> set[str]:
    """Class names passed to Register(new ...()) anywhere in the bridge."""
    classes: set[str] = set()
    for cs in _editor_dir().rglob("*.cs"):
        for m in _REGISTER_RE.finditer(cs.read_text(encoding="utf-8")):
            classes.add(m.group(1).split(".")[-1])
    return classes


def _schema_names() -> set[str]:
    names: set[str] = set()
    for schema in get_unity_tool_schemas():
        name = schema.get("function", {}).get("name")
        if name:
            names.add(name)
    return names


# ── Parity ───────────────────────────────────────────────────────────────────


def test_every_tool_class_is_registered():
    """A tool class that never gets a Register(new ...()) call compiles
    cleanly and looks finished, but every call to it dies at runtime with
    "Tool was blocked from executing or null." Registration is manual —
    nothing else in the stack catches the omission."""
    implemented = _implemented_tools()
    registered = _registered_class_names()
    dead = {name: cls for name, cls in implemented.items() if cls not in registered}
    assert not dead, (
        f"Tool classes declare a Name but are never registered: {dead}. "
        f"Add a Register(new <Class>()); call to the matching "
        f"unity-bridge/Editor/Tools/Registrars/<Category>Tools.cs."
    )


def test_every_registered_bridge_tool_has_a_schema():
    """If the bridge registers a tool, the schema package must describe it
    — otherwise the agent has no way to discover or call the tool."""
    implemented = _implemented_tools()
    registered_classes = _registered_class_names()
    registered_names = {name for name, cls in implemented.items() if cls in registered_classes}
    assert registered_names, "Parsed zero registered tools from the Unity bridge — parser drift?"

    missing_schemas = registered_names - _schema_names() - _HARNESS_ONLY_TOOLS
    assert not missing_schemas, (
        f"Bridge registers tools that tools/ does not describe: {sorted(missing_schemas)}. "
        f"Add a schema entry (or, if the tool is automation-only by design, "
        f"add it to _HARNESS_ONLY_TOOLS)."
    )


def test_every_schema_corresponds_to_a_bridge_tool():
    """If a schema is described, the bridge must implement that name —
    otherwise the agent can call a tool that doesn't exist."""
    orphan_schemas = _schema_names() - set(_implemented_tools()) - _LOCALLY_HANDLED_TOOLS
    assert not orphan_schemas, (
        f"tools/ describes tools the bridge does not implement: {sorted(orphan_schemas)}. "
        f"Either remove the schema, add the C# tool under "
        f"unity-bridge/Editor/Tools/Implementations/, or (if handled by the "
        f"server or client itself) add it to _LOCALLY_HANDLED_TOOLS."
    )


def test_exemption_lists_are_current():
    """A stale exemption would mask real drift — pin each exempted name to
    the exact one-sided state that justifies it."""
    implemented = set(_implemented_tools())
    schema_names = _schema_names()

    for name in _HARNESS_ONLY_TOOLS:
        assert name in implemented, (
            f"{name} is exempted as a bridge-only tool but no longer exists in the bridge — "
            f"remove it from _HARNESS_ONLY_TOOLS."
        )
        assert name not in schema_names, (
            f"{name} is exempted as harness-only yet now has a schema — remove it from _HARNESS_ONLY_TOOLS."
        )

    for name in _LOCALLY_HANDLED_TOOLS:
        assert name in schema_names, (
            f"{name} is exempted as a locally-handled schema but is no longer described — "
            f"remove it from _LOCALLY_HANDLED_TOOLS."
        )
        assert name not in implemented, (
            f"{name} is exempted as having no C# implementation, but the bridge now "
            f"implements it — remove it from _LOCALLY_HANDLED_TOOLS."
        )
