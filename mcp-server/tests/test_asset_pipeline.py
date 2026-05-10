"""Asset pipeline tests for the MCP server.

These tests exercise the bundled orchestrator/provider/catalog and the env-var
toggle. They depend on the same conftest.py as the rest of the MCP test suite,
which auto-imports gladekit_mcp.server (and therefore the `mcp` SDK). Run via
`uv sync && uv run pytest tests/test_asset_pipeline.py` once deps are installed.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

# Skip cleanly in environments without the mcp SDK (covers local dev without
# `uv sync`). CI installs deps via uv before running.
pytest.importorskip("mcp", reason="MCP SDK required for these tests")


# Add src/ to sys.path so `from gladekit_mcp...` works without uv sync.
_SRC = Path(__file__).resolve().parent.parent / "src"
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))


# ── Catalog & orchestrator ───────────────────────────────────────────────────


def test_kenney_catalog_loads_in_mcp_package():
    """The catalog file must be present at the MCP-package path so the
    bundled orchestrator works without depending on the cloud."""
    from gladekit_mcp.asset_pipeline.providers.kenney import _load_catalog

    catalog = _load_catalog()
    assert catalog["provider"] == "kenney"
    assert len(catalog["packs"]) >= 5


def test_orchestrator_search_runs_locally():
    from gladekit_mcp.asset_pipeline import AssetSpec, AssetType, search

    candidates = search(
        AssetSpec(
            description="platformer character",
            asset_type=AssetType.SPRITE_2D,
        )
    )
    assert candidates, "search should return candidates locally"
    assert all(c.provider == "kenney" for c in candidates)


def test_search_dataclass_to_dict_is_json_safe():
    """to_dict() output must be JSON-serializable so the MCP intercept can
    package it into a tool_result string without fancy encoders."""
    from gladekit_mcp.asset_pipeline import AssetSpec, AssetType, search

    candidates = search(AssetSpec(description="dungeon", asset_type=AssetType.SPRITE_2D))
    for c in candidates:
        json.dumps(c.to_dict())  # must not raise


# ── Env-var toggle ────────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    monkeypatch.delenv("GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", raising=False)


def _reload_tools_pkg():
    """Force re-import of gladekit_mcp.tools so the env var is re-read.

    Deleting `gladekit_mcp.tools` from sys.modules is not sufficient on its own:
    after the first import, `tools` is also held as an attribute on the parent
    `gladekit_mcp` package, and `from gladekit_mcp import tools` resolves via
    that attribute (not via re-import). Clear both so the next import re-runs
    the module body and re-reads the env var.
    """
    for mod in [m for m in list(sys.modules) if m.startswith("gladekit_mcp.tools")]:
        del sys.modules[mod]
    import gladekit_mcp

    if hasattr(gladekit_mcp, "tools"):
        delattr(gladekit_mcp, "tools")


def test_asset_pipeline_in_categories_when_enabled():
    _reload_tools_pkg()
    from gladekit_mcp import tools as mcp_tools

    cats = [c["name"] for c, _ in mcp_tools.ALL_CATEGORIES]
    assert "asset_pipeline" in cats


@pytest.mark.parametrize("val", ["1", "true", "TRUE", "yes", "on"])
def test_env_var_disable_strips_category(monkeypatch, val):
    monkeypatch.setenv("GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", val)
    _reload_tools_pkg()
    from gladekit_mcp import tools as mcp_tools

    cats = [c["name"] for c, _ in mcp_tools.ALL_CATEGORIES]
    assert "asset_pipeline" not in cats, f"GLADEKIT_MCP_DISABLE_ASSET_PIPELINE={val!r} should disable category"


@pytest.mark.parametrize("val", ["0", "false", "no", "off", ""])
def test_env_var_blank_or_falsey_keeps_category(monkeypatch, val):
    monkeypatch.setenv("GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", val)
    _reload_tools_pkg()
    from gladekit_mcp import tools as mcp_tools

    cats = [c["name"] for c, _ in mcp_tools.ALL_CATEGORIES]
    assert "asset_pipeline" in cats


# ── Schema sanity ────────────────────────────────────────────────────────────


def test_asset_pipeline_schemas_have_required_tools():
    """The MCP-side schemas must expose the same three tools as the cloud
    schemas so the MCP UX matches the Electron UX feature-for-feature."""
    _reload_tools_pkg()
    from gladekit_mcp.tools.asset_pipeline import TOOLS

    names = {(t.get("function") or {}).get("name") for t in TOOLS}
    assert names == {"find_asset", "import_asset", "list_imported_assets"}


def test_import_asset_schema_requires_license_acknowledged():
    from gladekit_mcp.tools.asset_pipeline import TOOLS

    import_tool = next(t for t in TOOLS if (t.get("function") or {}).get("name") == "import_asset")
    required = import_tool["function"]["parameters"]["required"]
    assert "licenseAcknowledged" in required, "license gate must be a required arg in the schema"
    assert "candidateId" in required
    assert "assetType" in required
