"""Guards for the Smithery bundle tool-enrichment step.

`scripts/build_smithery_bundle.py` injects real tool schemas into the published
MCPB bundle (the committed manifest.json can't carry them — see the script's
docstring). These checks lock in the two properties Smithery's registry needs
(every tool has an inputSchema) and the one thing that must never leak (the
internal eval tool), without running the slow `mcpb pack` subprocess.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "build_smithery_bundle.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("build_smithery_bundle", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_bundle_tools_are_registry_valid():
    """Every injected tool is a full MCP tool object (name + inputSchema), so
    Smithery's registry accepts it — a tool missing inputSchema triggers the
    "expected object, received undefined" 400 that empties the listing."""
    tools = _load_module()._load_tool_schemas()
    assert len(tools) > 100, "expected the full engine tool set, got a suspiciously short list"
    for t in tools:
        assert t.get("name"), "every tool needs a name"
        assert isinstance(t.get("inputSchema"), dict), f"{t.get('name')} is missing an inputSchema object"


def test_bundle_excludes_internal_tools_and_has_no_duplicates():
    module = _load_module()
    tools = module._load_tool_schemas()
    names = [t["name"] for t in tools]
    assert "reset_eval_state" not in names, "internal eval tool must not appear on the public listing"
    assert names == list(dict.fromkeys(names)), "tool names must be unique (deduped across engines)"
    # The denylist is the single source of truth for exclusions.
    assert "reset_eval_state" in module.DENY
