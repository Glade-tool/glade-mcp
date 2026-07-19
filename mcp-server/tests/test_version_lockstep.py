"""Drift guard for the version numbers that must move together on a release.

`pyproject.toml` drives the published `gladekit-mcp` version. Several sibling
descriptors have to match it or they ship a version that lies about the code:

  - `server.json`            — the MCP-registry descriptor (top-level `version`
                               AND the `packages[].version` PyPI entry). The
                               registry publish is version-sensitive, and this
                               file has no other guard.
  - `unity-bridge/package.json` — the UPM package version; `sync-oss.yml` tags
                               the public repo `v{unity-bridge version}`, so a
                               mismatch tags the wrong release.

`manifest.json` is covered separately by `test_mcpb_manifest.py`. The Godot
bridge is a distinct version stream guarded by `test_godot_version_lockstep.py`.

These checks are mechanical: they parse the files at test time so a bump that
forgets one fails locally and in CI instead of shipping. `server.json` silently
drifted to 0.7.14 while pyproject was 0.7.15 (it missed a release) precisely
because nothing here was watching it.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
import tomllib

MCP_SERVER_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = MCP_SERVER_ROOT.parent


def _pyproject_version() -> str:
    data = tomllib.loads((MCP_SERVER_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    return data["project"]["version"]


def _server_json() -> dict:
    return json.loads((MCP_SERVER_ROOT / "server.json").read_text(encoding="utf-8"))


def test_server_json_top_level_version_matches_pyproject():
    """server.json `version` must match pyproject so the registry descriptor
    advertises the same version as the published package."""
    server_version = _server_json()["version"]
    pyproject_version = _pyproject_version()
    assert server_version == pyproject_version, (
        f"Drift: pyproject.toml version is {pyproject_version} but server.json "
        f"version is {server_version}. Bump server.json to match when releasing."
    )


def test_server_json_package_version_matches_pyproject():
    """The `packages[].version` in server.json (the PyPI entry the registry
    resolves) must also match pyproject — it drifts independently of the
    top-level field."""
    pyproject_version = _pyproject_version()
    packages = _server_json().get("packages", [])
    assert packages, "server.json has no packages[] entry to check"
    for pkg in packages:
        assert pkg["version"] == pyproject_version, (
            f"Drift: pyproject.toml version is {pyproject_version} but "
            f"server.json packages[] entry for {pkg.get('identifier')!r} is "
            f"{pkg['version']}. Bump it to match when releasing."
        )


def test_unity_bridge_package_version_matches_pyproject():
    """unity-bridge/package.json must match pyproject so `sync-oss.yml` tags
    the right `v{version}` release. Skips when the sibling package is absent
    (e.g. a standalone mcp-server checkout), mirroring the defensive skip in
    test_registry_godot.py — the guard is only meaningful in the full tree."""
    unity_pkg = REPO_ROOT / "unity-bridge" / "package.json"
    if not unity_pkg.is_file():
        pytest.skip("unity-bridge/package.json not present (standalone mcp-server checkout)")
    unity_version = json.loads(unity_pkg.read_text(encoding="utf-8"))["version"]
    pyproject_version = _pyproject_version()
    assert unity_version == pyproject_version, (
        f"Drift: pyproject.toml version is {pyproject_version} but "
        f"unity-bridge/package.json version is {unity_version}. These ship in "
        f"lockstep; bump both when releasing."
    )
