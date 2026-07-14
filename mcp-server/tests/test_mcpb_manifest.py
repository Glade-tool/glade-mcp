"""Drift guard for the MCPB bundle manifest.

`manifest.json` is the MCP Bundle (.mcpb) descriptor used to publish this
server to registries such as Smithery. Its `version` is baked into the bundle
at pack time, so it must track the package version in `pyproject.toml` — a
stale manifest ships a bundle whose advertised version lies about the code
inside it.

These checks are mechanical: they parse both files at test time so a version
bump that forgets the manifest fails locally and in CI instead of shipping.
"""

from __future__ import annotations

import json
from pathlib import Path

import tomllib

MCP_SERVER_ROOT = Path(__file__).resolve().parent.parent


def _manifest() -> dict:
    return json.loads((MCP_SERVER_ROOT / "manifest.json").read_text(encoding="utf-8"))


def _pyproject_version() -> str:
    data = tomllib.loads((MCP_SERVER_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    return data["project"]["version"]


def test_manifest_version_matches_pyproject():
    """manifest.json version must match pyproject.toml so the packed .mcpb
    advertises the same version as the code it runs."""
    manifest_version = _manifest()["version"]
    pyproject_version = _pyproject_version()
    assert manifest_version == pyproject_version, (
        f"Drift: pyproject.toml version is {pyproject_version} but "
        f"manifest.json version is {manifest_version}. Bump manifest.json "
        f"to match when releasing."
    )


def test_manifest_has_required_mcpb_fields():
    """The bundle won't pack without these top-level fields."""
    manifest = _manifest()
    for field in ("manifest_version", "name", "version", "description", "author", "server"):
        assert field in manifest, f"manifest.json is missing required field: {field}"
    assert manifest["author"].get("name"), "author.name is required by the MCPB spec"


def test_manifest_server_runs_via_uv_with_supported_runtime_label():
    """The server is launched with `uv run` (uv resolves deps, incl. compiled
    ones like numpy, from the bundled pyproject.toml + uv.lock at first launch).

    `server.type` must stay one of the runtime labels Smithery's publisher
    recognizes — python / node / binary. Do NOT set it to "uv": the MCPB v0.4
    "uv" runtime type is real, but Smithery's `detectBundleRuntime`
    (src/lib/mcpb.ts) has no case for it and rejects the bundle with "Could not
    determine bundle runtime from manifest". "python" is the accurate label and
    leaves the `uv run` command (read verbatim from mcp_config) untouched.
    """
    server = _manifest()["server"]
    assert server["type"] in {"python", "node", "binary"}, (
        "server.type must be a Smithery-supported runtime label; 'uv' is rejected by "
        "Smithery's publisher (see src/lib/mcpb.ts detectBundleRuntime)"
    )
    assert server["mcp_config"]["command"] == "uv", "launch the server via `uv run`"
    entry_point = MCP_SERVER_ROOT / server["entry_point"]
    assert entry_point.is_file(), f"server.entry_point does not exist: {server['entry_point']}"


def test_manifest_name_matches_package():
    """Keep the bundle name aligned with the distributed package name."""
    data = tomllib.loads((MCP_SERVER_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    assert _manifest()["name"] == data["project"]["name"]
