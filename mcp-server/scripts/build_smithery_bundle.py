#!/usr/bin/env python3
"""Build the Smithery-ready MCPB bundle (`gladekit-mcp.mcpb`).

Why this script exists — a schema conflict between two specs:

* The MCPB manifest schema locks each `tools[]` entry to `{name, description}`
  only (`additionalProperties: false`), so `mcpb pack` refuses a manifest whose
  tools carry an `inputSchema`.
* Smithery's registry, however, validates each published tool as a full MCP
  tool object and rejects any tool that lacks an `inputSchema`. With no tools
  at all, the listing shows "No capabilities found".

Neither side is negotiable, so we can't express the tool list in the committed
`manifest.json` (it has to stay pack-valid). Instead:

  1. `mcpb pack` builds a bundle from the clean, pack-valid `manifest.json`.
  2. This script rewrites the `manifest.json` *inside* that bundle, injecting
     the real tool schemas pulled straight from this package's own registry
     (the same schemas the running server serves via `tools/list`). Smithery's
     bundle reader only checks that each tool has a `name`; it does not
     re-validate against the strict MCPB schema, so the enriched manifest is
     accepted and every tool shows up on the listing.

Pulling the schemas from code at build time means the listing never drifts from
what the server actually exposes — there is no hand-maintained tool list.

Usage (from the `mcp-server/` directory):

    uv run python scripts/build_smithery_bundle.py [output.mcpb]

then publish the result:

    npx -y smithery@latest mcp publish gladekit-mcp.mcpb -n gladekit/gladekit-mcp
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MCP_SERVER_ROOT = Path(__file__).resolve().parent.parent

# Tools that exist in the schema set but must not appear on a public listing.
# `reset_eval_state` drives the offline test harness; it is not a game-dev tool.
DENY: frozenset[str] = frozenset({"reset_eval_state"})


def _load_tool_schemas() -> list[dict]:
    """Every engine tool as an MCP `{name, description, inputSchema}` object,
    deduped by name (Unity and Godot share some names), minus the denylist."""
    sys.path.insert(0, str(MCP_SERVER_ROOT / "src"))
    from gladekit_mcp.schemas.godot import get_godot_tool_schemas
    from gladekit_mcp.tools import get_unity_tool_schemas

    tools: list[dict] = []
    seen: set[str] = set()
    for schema_set in (get_unity_tool_schemas(), get_godot_tool_schemas()):
        for schema in schema_set:
            # Schemas are OpenAI function-calling format, sometimes wrapped in a
            # {"type": "function", "function": {...}} envelope.
            fn = schema.get("function", schema)
            name = fn["name"]
            if name in DENY or name in seen:
                continue
            seen.add(name)
            tools.append(
                {
                    "name": name,
                    "description": fn.get("description", ""),
                    "inputSchema": fn.get("parameters", {"type": "object", "properties": {}}),
                }
            )
    return tools


def _pack_clean_bundle(dest: Path) -> None:
    """Run `mcpb pack` on the committed (pack-valid) manifest to get a bundle
    with the correct structure and .mcpbignore handling."""
    # Resolve the full npx path so this works on Windows too — subprocess
    # (no shell) can't find `npx` there without the `.cmd` extension.
    npx = shutil.which("npx") or "npx"
    subprocess.run(
        [npx, "-y", "@anthropic-ai/mcpb@latest", "pack", ".", str(dest)],
        cwd=MCP_SERVER_ROOT,
        check=True,
    )


def _inject_tools(base_mcpb: Path, out_mcpb: Path, tools: list[dict]) -> None:
    """Copy the packed bundle, replacing manifest.json with a tools-enriched one."""
    manifest = json.loads((MCP_SERVER_ROOT / "manifest.json").read_text(encoding="utf-8"))
    manifest["tools"] = tools
    manifest["tools_generated"] = True  # more tools surface at runtime per engine

    with (
        zipfile.ZipFile(base_mcpb) as zin,
        zipfile.ZipFile(out_mcpb, "w", zipfile.ZIP_DEFLATED) as zout,
    ):
        for item in zin.infolist():
            if item.filename == "manifest.json":
                zout.writestr("manifest.json", json.dumps(manifest, indent=1))
            else:
                zout.writestr(item, zin.read(item.filename))


def main() -> None:
    out_mcpb = Path(sys.argv[1]) if len(sys.argv) > 1 else MCP_SERVER_ROOT / "gladekit-mcp.mcpb"
    tools = _load_tool_schemas()
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "base.mcpb"
        _pack_clean_bundle(base)
        _inject_tools(base, out_mcpb, tools)
    print(f"Built {out_mcpb} with {len(tools)} tools.")


if __name__ == "__main__":
    main()
