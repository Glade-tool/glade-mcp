"""
CLI subcommands for the gladekit / gladekit-mcp entry point.

  gladekit doctor  — diagnose the full GladeKit stack
  gladekit init    — scaffold a GLADE.md from the live Unity project
  gladekit version — show version and check PyPI for updates
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import httpx

from . import __version__
from .bridge import DEFAULT_BRIDGE_URL, UnityBridgeError, check_health, gather_scene_context

PYPI_URL = "https://pypi.org/pypi/gladekit-mcp/json"

# ── doctor ────────────────────────────────────────────────────────────────────


# Use UTF-8 symbols if the terminal supports them, ASCII fallback otherwise.
def _supports_unicode() -> bool:
    import sys

    enc = getattr(sys.stdout, "encoding", "") or ""
    return enc.lower().replace("-", "") in ("utf8", "utf16", "utf32")


_CHECK_PASS = "  \u2713" if _supports_unicode() else "  [OK]  "
_CHECK_FAIL = "  \u2717" if _supports_unicode() else "  [FAIL]"
_ARROW = "\u2192" if _supports_unicode() else "->"


def _check_python() -> dict:
    v = sys.version_info
    ok = v >= (3, 10)
    return {
        "pass": ok,
        "value": f"{v.major}.{v.minor}.{v.micro}",
        "fix": "Install Python 3.10 or later: https://python.org/downloads",
    }


def _check_bridge(bridge_url: str) -> dict:
    try:
        health = asyncio.run(check_health(bridge_url))
        ok = health.get("status") == "ok"
        unity_version = health.get("unityVersion", "unknown")
        project_name = health.get("projectName", "unknown")
        return {
            "pass": ok,
            "value": f"{project_name} ({unity_version})",
            "unity_version": unity_version,
            "project_name": project_name,
            "project_path": health.get("projectPath", ""),
            "fix": "Open Unity and enable Window > GladeKit MCP",
        }
    except (UnityBridgeError, Exception) as exc:
        return {
            "pass": False,
            "value": None,
            "error": str(exc),
            "unity_version": None,
            "project_name": None,
            "project_path": "",
            "fix": "Start Unity, open your project, then enable Window > GladeKit MCP",
        }


def _check_env(var: str, label: str, fix: str) -> dict:
    val = os.environ.get(var, "")
    return {
        "pass": bool(val),
        "value": "set" if val else "not set",
        "fix": fix,
    }


def _check_glade_md() -> dict:
    path = Path.cwd() / "GLADE.md"
    if path.exists():
        return {"pass": True, "value": str(path)}
    return {
        "pass": False,
        "value": "not found",
        "fix": "Run `gladekit init` to generate a starter GLADE.md in your Unity project",
    }


def run_doctor(bridge_url: str = DEFAULT_BRIDGE_URL, output_json: bool = False) -> int:
    """Run all diagnostic checks and print results. Returns 0 if all pass, 1 otherwise."""
    checks: dict[str, dict] = {}

    checks["python"] = _check_python()
    checks["bridge"] = _check_bridge(bridge_url)
    checks["openai_key"] = _check_env(
        "OPENAI_API_KEY",
        "openai key",
        "Set OPENAI_API_KEY for semantic script search: https://platform.openai.com/api-keys",
    )
    checks["gladekit_key"] = _check_env(
        "GLADEKIT_API_KEY",
        "gladekit key",
        "Get your API key at https://gladekit.com/pricing (free tier available)",
    )
    checks["glade_md"] = _check_glade_md()

    if output_json:
        print(json.dumps(checks, indent=2))
        return 0 if all(c["pass"] for c in checks.values()) else 1

    # Human-readable output
    labels = {
        "python": ("python", lambda c: c.get("value", "")),
        "bridge": ("unity bridge", lambda c: c.get("value") or c.get("error", "")),
        "openai_key": ("openai key", lambda c: c.get("value", "")),
        "gladekit_key": ("gladekit key", lambda c: c.get("value", "")),
        "glade_md": ("glade.md", lambda c: c.get("value", "")),
    }

    print("\nGladeKit Doctor\n")
    all_pass = True
    for key, (label, val_fn) in labels.items():
        c = checks[key]
        icon = _CHECK_PASS if c["pass"] else _CHECK_FAIL
        val = val_fn(c)
        print(f"{icon}  {label:<14} {val}")
        if not c["pass"]:
            all_pass = False
            fix = c.get("fix")
            if fix:
                print(f"       {_ARROW} {fix}")

    if all_pass:
        print("\nAll checks passed.\n")
    else:
        print("\nSome checks failed. See fixes above.\n")

    return 0 if all_pass else 1


# ── init ──────────────────────────────────────────────────────────────────────


def _detect_genre(packages: list[dict]) -> str:
    """Infer a genre hint from installed package names."""
    names = {p.get("name", "").lower() for p in packages}
    if any("2d" in n or "tilemap" in n or "sprite" in n for n in names):
        return "2D"
    if any("xr" in n or "vr" in n or "ar" in n or "openxr" in n for n in names):
        return "XR / VR"
    if any("netcode" in n or "multiplayer" in n or "transport" in n for n in names):
        return "Multiplayer 3D"
    return "3D"


def _render_glade_md(
    project_name: str,
    unity_version: str,
    render_pipeline: str,
    input_system: str,
    genre: str,
    packages: list[dict],
) -> str:
    input_label = {
        "NEW": "New Input System",
        "OLD": "Legacy Input Manager",
        "BOTH": "New + Legacy Input System",
    }.get(input_system or "", "Unknown Input System")

    notable_packages = [
        p["name"]
        for p in packages
        if not p.get("name", "").startswith("com.unity.modules.")
        and not p.get("name", "").startswith("com.unity.feature.")
        and p.get("name", "")
    ]
    packages_section = (
        "\n".join(f"- {n}" for n in sorted(notable_packages[:20])) if notable_packages else "_(none detected)_"
    )

    return f"""\
# Game Design Document — {project_name}

## Project Overview

**Unity Version:** {unity_version}
**Render Pipeline:** {render_pipeline or "Built-in"}
**Input System:** {input_label}
**Genre:** {genre}

## Game Summary

<!-- One paragraph describing your game's core concept, target audience, and platform. -->

## Core Mechanics

<!-- List the primary gameplay mechanics the player interacts with. -->
<!-- Example: platforming, combat, inventory management, etc. -->

## Technical Notes

<!-- Unity-specific architecture decisions, coding conventions, or constraints. -->
<!-- Example: "Use ScriptableObjects for item definitions", "Physics layer 8 = enemies". -->

## Installed Packages

{packages_section}

---

_Generated by `gladekit init`. Fill in the sections above — the AI reads this every session._
"""


async def _run_init_async(bridge_url: str, force: bool, dry_run: bool) -> int:
    # Step 1: get project path from bridge health
    try:
        health = await check_health(bridge_url)
    except UnityBridgeError as exc:
        print(f"  \u2717  Cannot reach Unity bridge: {exc}")
        print(f"       {_ARROW} Start Unity, open your project, and enable Window > GladeKit MCP")
        return 1

    project_path_str = health.get("projectPath", "")
    if not project_path_str:
        print("  \u2717  Bridge did not return a project path. Update your Unity bridge.")
        return 1

    project_path = Path(project_path_str)
    if not project_path.is_absolute() or not project_path.is_dir():
        print(f"  \u2717  Project path from bridge is not valid: {project_path_str}")
        return 1

    glade_md_path = project_path / "GLADE.md"
    if glade_md_path.exists() and not force:
        print(f"  \u2717  GLADE.md already exists at {glade_md_path}")
        print(f"       {_ARROW} Run with --force to overwrite")
        return 1

    # Step 2: gather context for packages + project info
    print("\nGladeKit Init\n")
    print("  Gathering project context from Unity...")
    try:
        ctx = await gather_scene_context(bridge_url)
    except UnityBridgeError as exc:
        print(f"  \u2717  Could not gather project context: {exc}")
        return 1

    project_info = ctx.get("projectInfo") or {}
    packages = ctx.get("packages") or []

    render_pipeline = project_info.get("renderPipeline") or "Built-in"
    input_system = project_info.get("inputSystem") or "OLD"
    unity_version = health.get("unityVersion", "unknown")
    project_name = health.get("projectName", "MyGame")
    genre = _detect_genre(packages)

    print(f"  \u2713  Detected: {render_pipeline}, {input_system} input, {genre}")

    # Step 3: render template
    content = _render_glade_md(
        project_name=project_name,
        unity_version=unity_version,
        render_pipeline=render_pipeline,
        input_system=input_system,
        genre=genre,
        packages=packages,
    )

    if dry_run:
        print("\n--- GLADE.md preview (dry run, not written) ---\n")
        print(content)
        print("--- end preview ---\n")
        return 0

    # Step 4: write files
    try:
        glade_md_path.write_text(content, encoding="utf-8")
        print(f"  \u2713  Wrote GLADE.md to {glade_md_path}")
    except PermissionError as exc:
        print(f"  \u2717  Cannot write GLADE.md: {exc}")
        return 1

    gladekit_dir = project_path / ".gladekit"
    gladekit_dir.mkdir(exist_ok=True)
    config_path = gladekit_dir / "config.json"
    config = {
        "glade_md": str(glade_md_path),
        "project_name": project_name,
        "unity_version": unity_version,
    }
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"  \u2713  Created {config_path}")
    print("\nDone. Open GLADE.md and fill in your game's design — the AI reads it every session.\n")
    return 0


def run_init(bridge_url: str = DEFAULT_BRIDGE_URL, force: bool = False, dry_run: bool = False) -> int:
    return asyncio.run(_run_init_async(bridge_url, force, dry_run))


# ── version ───────────────────────────────────────────────────────────────────


def _upgrade_command() -> str:
    """Detect install method and return the right upgrade command.

    uvx caches resolved versions and won't pick up new releases without --refresh.
    Most MCP users install via uvx (it's the recommended path in the README), so
    suggesting `pip install --upgrade` strands them — pip often isn't even on PATH.
    Detection: uvx installs each tool into its own env under ~/.local/share/uv/tools/
    (or %APPDATA%\\uv\\tools\\ on Windows), so sys.executable contains uv/tools.
    """
    exe = sys.executable.replace("\\", "/")
    if "/uv/tools/" in exe:
        return "uvx --refresh gladekit-mcp"
    return "pip install --upgrade gladekit-mcp"


def run_version() -> int:
    print(f"gladekit-mcp {__version__}")
    try:
        resp = httpx.get(PYPI_URL, timeout=5.0)
        resp.raise_for_status()
        latest = resp.json()["info"]["version"]
        if latest != __version__:
            print(f"Update available: {latest}")
            print(f"  {_ARROW} {_upgrade_command()}")
        else:
            print("You are up to date.")
    except Exception:
        # Non-fatal — offline or PyPI unavailable
        pass
    return 0
