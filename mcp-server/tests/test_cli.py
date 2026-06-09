"""Tests for gladekit doctor / init / version CLI commands."""

import json
import sys
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

from gladekit_mcp.bridge import UnityBridgeError
from gladekit_mcp.cli import (
    _check_bridge,
    _check_glade_md,
    _check_python,
    _detect_genre,
    _render_glade_md,
    _upgrade_command,
    run_doctor,
    run_version,
)

# ── doctor ────────────────────────────────────────────────────────────────────


def _mock_health(status="ok", unity_version="2022.3.12f1", project_name="TestGame", project_path="/proj"):
    return {
        "status": status,
        "unityVersion": unity_version,
        "projectName": project_name,
        "projectPath": project_path,
        "isCompiling": False,
    }


def test_check_python_pass():
    result = _check_python()
    assert result["pass"] is True
    assert sys.version_info >= (3, 10)


def test_check_bridge_pass():
    with patch("gladekit_mcp.cli.asyncio.run", return_value=_mock_health()):
        result = _check_bridge("http://localhost:8765")
    assert result["pass"] is True
    assert result["unity_version"] == "2022.3.12f1"
    assert result["project_name"] == "TestGame"


def test_check_bridge_unreachable():
    with patch("gladekit_mcp.cli.asyncio.run", side_effect=UnityBridgeError("refused")):
        result = _check_bridge("http://localhost:8765")
    assert result["pass"] is False
    assert result["unity_version"] is None
    assert "fix" in result


def test_check_glade_md_exists(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "GLADE.md").write_text("# GDD")
    result = _check_glade_md()
    assert result["pass"] is True


def test_check_glade_md_missing(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    result = _check_glade_md()
    assert result["pass"] is False
    assert "fix" in result


def test_run_doctor_all_pass(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    (tmp_path / "GLADE.md").write_text("# GDD")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("GLADEKIT_API_KEY", "gk-test")
    with patch("gladekit_mcp.cli.asyncio.run", return_value=_mock_health()):
        exit_code = run_doctor()
    assert exit_code == 0


def test_run_doctor_bridge_unreachable(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("GLADEKIT_API_KEY", raising=False)
    with patch("gladekit_mcp.cli.asyncio.run", side_effect=UnityBridgeError("refused")):
        exit_code = run_doctor()
    assert exit_code == 1
    captured = capsys.readouterr()
    assert "✗" in captured.out
    assert "bridge" in captured.out.lower() or "Unity" in captured.out


def test_run_doctor_missing_env(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("GLADEKIT_API_KEY", raising=False)
    with patch("gladekit_mcp.cli.asyncio.run", return_value=_mock_health()):
        exit_code = run_doctor()
    assert exit_code == 1  # GLADE.md missing + env vars missing
    captured = capsys.readouterr()
    assert "not set" in captured.out


def test_run_doctor_json_output(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    monkeypatch.setenv("GLADEKIT_API_KEY", "gk-test")
    (tmp_path / "GLADE.md").write_text("# GDD")
    with patch("gladekit_mcp.cli.asyncio.run", return_value=_mock_health()):
        exit_code = run_doctor(output_json=True)
    captured = capsys.readouterr()
    parsed = json.loads(captured.out)
    assert "python" in parsed
    assert "bridge" in parsed
    assert "openai_key" in parsed
    assert exit_code == 0


# ── genre detection ───────────────────────────────────────────────────────────


def test_detect_genre_2d():
    packages = [{"name": "com.unity.2d.tilemap"}, {"name": "com.unity.render-pipelines.universal"}]
    assert _detect_genre(packages) == "2D"


def test_detect_genre_xr():
    packages = [{"name": "com.unity.xr.openxr"}, {"name": "com.unity.render-pipelines.universal"}]
    assert _detect_genre(packages) == "XR / VR"


def test_detect_genre_multiplayer():
    packages = [{"name": "com.unity.netcode.gameobjects"}]
    assert _detect_genre(packages) == "Multiplayer 3D"


def test_detect_genre_default_3d():
    packages = [{"name": "com.unity.render-pipelines.universal"}]
    assert _detect_genre(packages) == "3D"


def test_detect_genre_empty():
    assert _detect_genre([]) == "3D"


# ── GLADE.md template ─────────────────────────────────────────────────────────


def test_render_glade_md_contains_project_name():
    content = _render_glade_md(
        project_name="CoolGame",
        unity_version="2022.3.12f1",
        render_pipeline="URP",
        input_system="NEW",
        genre="3D",
        packages=[{"name": "com.unity.render-pipelines.universal"}],
    )
    assert "CoolGame" in content
    assert "URP" in content
    assert "New Input System" in content
    assert "com.unity.render-pipelines.universal" in content


def test_render_glade_md_filters_unity_modules():
    packages = [
        {"name": "com.unity.modules.physics"},
        {"name": "com.unity.feature.development"},
        {"name": "com.unity.cinemachine"},
    ]
    content = _render_glade_md("G", "2022", "Built-in", "OLD", "3D", packages)
    assert "com.unity.cinemachine" in content
    assert "com.unity.modules.physics" not in content
    assert "com.unity.feature.development" not in content


# ── init ──────────────────────────────────────────────────────────────────────


def _mock_context(render_pipeline="URP", input_system="NEW", packages=None):
    return {
        "projectInfo": {"renderPipeline": render_pipeline, "inputSystem": input_system},
        "packages": packages or [{"name": "com.unity.render-pipelines.universal"}],
        "scripts": [],
    }


@pytest.mark.asyncio
async def test_init_success(tmp_path):
    project_path = tmp_path / "MyGame"
    project_path.mkdir()
    health = _mock_health(project_path=str(project_path))

    with (
        patch("gladekit_mcp.cli.check_health", new=AsyncMock(return_value=health)),
        patch("gladekit_mcp.cli.gather_scene_context", new=AsyncMock(return_value=_mock_context())),
    ):
        exit_code = await _run_init_async_direct(str(project_path), force=False, dry_run=False)

    assert exit_code == 0
    assert (project_path / "GLADE.md").exists()
    assert (project_path / ".gladekit" / "config.json").exists()
    content = (project_path / "GLADE.md").read_text()
    assert "TestGame" in content


@pytest.mark.asyncio
async def test_init_bridge_unreachable(tmp_path, capsys):
    with patch("gladekit_mcp.cli.check_health", new=AsyncMock(side_effect=UnityBridgeError("refused"))):
        from gladekit_mcp.cli import _run_init_async

        exit_code = await _run_init_async("http://localhost:8765", force=False, dry_run=False)
    assert exit_code == 1
    captured = capsys.readouterr()
    assert "✗" in captured.out


@pytest.mark.asyncio
async def test_init_glade_md_already_exists(tmp_path, capsys):
    project_path = tmp_path / "MyGame"
    project_path.mkdir()
    (project_path / "GLADE.md").write_text("# existing GDD")
    health = _mock_health(project_path=str(project_path))

    with patch("gladekit_mcp.cli.check_health", new=AsyncMock(return_value=health)):
        from gladekit_mcp.cli import _run_init_async

        exit_code = await _run_init_async("http://localhost:8765", force=False, dry_run=False)

    assert exit_code == 1
    assert (project_path / "GLADE.md").read_text() == "# existing GDD"  # not overwritten
    captured = capsys.readouterr()
    assert "--force" in captured.out


@pytest.mark.asyncio
async def test_init_force_overwrites(tmp_path):
    project_path = tmp_path / "MyGame"
    project_path.mkdir()
    (project_path / "GLADE.md").write_text("# old GDD")
    health = _mock_health(project_path=str(project_path))

    with (
        patch("gladekit_mcp.cli.check_health", new=AsyncMock(return_value=health)),
        patch("gladekit_mcp.cli.gather_scene_context", new=AsyncMock(return_value=_mock_context())),
    ):
        from gladekit_mcp.cli import _run_init_async

        exit_code = await _run_init_async("http://localhost:8765", force=True, dry_run=False)

    assert exit_code == 0
    content = (project_path / "GLADE.md").read_text()
    assert "old GDD" not in content


@pytest.mark.asyncio
async def test_init_dry_run_does_not_write(tmp_path, capsys):
    project_path = tmp_path / "MyGame"
    project_path.mkdir()
    health = _mock_health(project_path=str(project_path))

    with (
        patch("gladekit_mcp.cli.check_health", new=AsyncMock(return_value=health)),
        patch("gladekit_mcp.cli.gather_scene_context", new=AsyncMock(return_value=_mock_context())),
    ):
        from gladekit_mcp.cli import _run_init_async

        exit_code = await _run_init_async("http://localhost:8765", force=False, dry_run=True)

    assert exit_code == 0
    assert not (project_path / "GLADE.md").exists()
    captured = capsys.readouterr()
    assert "dry run" in captured.out.lower()


# Helper: call _run_init_async with a specific project path via mocked bridge
async def _run_init_async_direct(project_path_str: str, force: bool, dry_run: bool) -> int:
    from gladekit_mcp.cli import _run_init_async

    return await _run_init_async("http://localhost:8765", force=force, dry_run=dry_run)


# ── version ───────────────────────────────────────────────────────────────────


def test_run_version_up_to_date(capsys):
    from gladekit_mcp import __version__

    mock_resp = MagicMock()
    mock_resp.json.return_value = {"info": {"version": __version__}}
    mock_resp.raise_for_status = MagicMock()

    with patch("gladekit_mcp.cli.httpx.get", return_value=mock_resp):
        exit_code = run_version()

    assert exit_code == 0
    captured = capsys.readouterr()
    assert __version__ in captured.out
    assert "up to date" in captured.out


def test_run_version_update_available_pip(capsys):
    """Default install method shows pip upgrade command."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"info": {"version": "99.99.99"}}
    mock_resp.raise_for_status = MagicMock()

    with (
        patch("gladekit_mcp.cli.httpx.get", return_value=mock_resp),
        patch("gladekit_mcp.cli.sys.executable", "/usr/local/bin/python3"),
    ):
        exit_code = run_version()

    assert exit_code == 0
    captured = capsys.readouterr()
    assert "99.99.99" in captured.out
    assert "pip install --upgrade gladekit-mcp" in captured.out


def test_run_version_update_available_uvx(capsys):
    """uvx-installed copy shows uvx --refresh command (uvx caches by version)."""
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"info": {"version": "99.99.99"}}
    mock_resp.raise_for_status = MagicMock()

    uvx_exe = "/Users/x/.local/share/uv/tools/gladekit-mcp/bin/python"
    with (
        patch("gladekit_mcp.cli.httpx.get", return_value=mock_resp),
        patch("gladekit_mcp.cli.sys.executable", uvx_exe),
    ):
        exit_code = run_version()

    assert exit_code == 0
    captured = capsys.readouterr()
    assert "uvx --refresh gladekit-mcp" in captured.out
    assert "pip install" not in captured.out


def test_upgrade_command_detection():
    """_upgrade_command detects uvx-managed envs by sys.executable path."""
    with patch("gladekit_mcp.cli.sys.executable", "/Users/x/.local/share/uv/tools/gladekit-mcp/bin/python"):
        assert _upgrade_command() == "uvx --refresh gladekit-mcp"
    # Windows path with backslashes
    with patch(
        "gladekit_mcp.cli.sys.executable", r"C:\Users\x\AppData\Roaming\uv\tools\gladekit-mcp\Scripts\python.exe"
    ):
        assert _upgrade_command() == "uvx --refresh gladekit-mcp"
    # Default (system / venv / pip-installed) python
    with patch("gladekit_mcp.cli.sys.executable", "/usr/local/bin/python3"):
        assert _upgrade_command() == "pip install --upgrade gladekit-mcp"
    with patch("gladekit_mcp.cli.sys.executable", "/Users/x/proj/.venv/bin/python"):
        assert _upgrade_command() == "pip install --upgrade gladekit-mcp"


def test_run_version_pypi_offline(capsys):
    with patch("gladekit_mcp.cli.httpx.get", side_effect=httpx.ConnectError("offline")):
        exit_code = run_version()
    assert exit_code == 0  # non-fatal
