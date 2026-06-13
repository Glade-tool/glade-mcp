"""
Dynamic MCP tool registration from OpenAI-format tool schemas.

Engine-aware. Probes the local bridge at first list_tools to decide
which schema set to expose:

  Unity   — 235+ tools, filtered to a curated CORE set (~80) for Claude
            Code's ~128-tool budget. All non-core tools remain
            dispatchable via the bridge.
  Godot   — 63 tools (full catalog, no filtering — well under the budget).

OpenAI format:
    {"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}

MCP format:
    Tool(name="...", description="...", inputSchema={...})

Engine selection: `bridge.detect_bridge_kind()` is the single source of
truth. Cached after first probe per process; override with
`GLADEKIT_MCP_FORCE_ENGINE=unity|godot` if running both bridges and you
need to address a specific one.

Use get_relevant_tools (Unity meta-tool in server.py) to discover
extended Unity tools beyond the core listed set.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from mcp import types

from .. import bridge
from ..schemas.godot import GODOT_READ_ONLY_TOOLS, get_godot_tool_schemas
from . import get_unity_tool_schemas

logger = logging.getLogger("gladekit-mcp")

# ── Core tool set ─────────────────────────────────────────────────────────────
# ~80 tools covering the most common Unity workflows. All non-core tools are
# still callable via the bridge; they're just not listed to stay within Claude
# Code's tool-count budget.

CORE_TOOLS: set[str] = {
    # ── Reasoning / meta ──────────────────────────────────────────────────────
    "think",
    "request_user_input",
    "get_session_summary",
    # ── Scene & hierarchy ─────────────────────────────────────────────────────
    "get_scene_hierarchy",
    "get_gameobject_info",
    "find_game_objects",
    "get_selection",
    "set_selection",
    "open_scene",
    "save_scene",
    # ── GameObjects ───────────────────────────────────────────────────────────
    "create_game_object",
    "create_primitive",
    "destroy_game_object",
    "set_game_object_active",
    "set_game_object_parent",
    "duplicate_game_object",
    "rename_game_object",
    "list_children",
    "set_layer",
    "set_tag",
    "group_objects",
    # ── Transforms ───────────────────────────────────────────────────────────
    "set_transform",
    "set_local_transform",
    "set_transform_batch",
    "snap_to_ground",
    "align_objects",
    # ── Components ────────────────────────────────────────────────────────────
    "get_gameobject_components",
    "add_component",
    "remove_component",
    "set_component_property",
    "set_script_component_property",
    "set_object_reference",
    "get_component_inspector_properties",
    # ── Scripts ───────────────────────────────────────────────────────────────
    "create_script",
    "modify_script",
    "get_script_content",
    "find_scripts",
    "compile_scripts",
    # ── Assets & folders ─────────────────────────────────────────────────────
    "list_assets",
    "check_asset_exists",
    "create_folder",
    "move_asset",
    "delete_asset",
    "refresh_asset_database",
    # ── Prefabs ───────────────────────────────────────────────────────────────
    "create_prefab",
    "instantiate_prefab",
    "get_prefab_info",
    # ── Materials & shaders ───────────────────────────────────────────────────
    "create_material",
    "set_material_property",
    "assign_material_to_renderer",
    "list_materials",
    "change_material_shader",
    # ── Lighting ─────────────────────────────────────────────────────────────
    "create_light",
    "set_light_properties",
    "set_render_settings",
    # ── Physics ───────────────────────────────────────────────────────────────
    "add_rigidbody",
    "set_rigidbody_properties",
    "create_collider",
    "set_collider_properties",
    "create_character_controller",
    "create_physics_material",
    # ── Camera ────────────────────────────────────────────────────────────────
    "create_camera",
    "set_camera_properties",
    # ── UI ────────────────────────────────────────────────────────────────────
    "create_canvas",
    "create_ui_element",
    # set_ui_properties demoted: 50+ property schema exceeds Unity AI Gateway's
    # cloud token budget. Still callable via get_relevant_tools for UI work.
    "create_event_system",
    "import_tmp_essential_resources",
    # ── Audio ─────────────────────────────────────────────────────────────────
    "create_audio_source",
    "set_audio_source_properties",
    "assign_audio_clip",
    # ── Animator (essentials) ─────────────────────────────────────────────────
    "create_animator_controller",
    "assign_animator_controller",
    "add_animator_parameters",
    "add_animator_state",
    "add_animator_transition",
    # ── Console & diagnostics ─────────────────────────────────────────────────
    "get_unity_console_logs",
    # ── Runtime / Live Loop ───────────────────────────────────────────────────
    "start_runtime_observation",
    "stop_runtime_observation",
    "get_runtime_events",
    "get_play_mode_state",
    "apply_queued_fix",
    # ── Asset pipeline (gated by GLADEKIT_MCP_DISABLE_ASSET_PIPELINE) ──────────
    "find_asset",
    "import_asset",
    "list_imported_assets",
}
# NOTE: Unity AI Gateway has a cloud schema token budget (~76 small tools).
# Demoted to extended-only (still callable via get_relevant_tools):
#   set_ui_properties (50+ property schema exceeds token budget alone),
#   create_scene, convert_materials_to_render_pipeline
# Claude Code limit is ~128, so this core set fits both clients.

# ── Engine-aware cache ────────────────────────────────────────────────────────
# Per-engine caches so that switching engines (rare — would require an env
# override + clear_bridge_kind_cache) doesn't bleed state across.

_unity_mcp_tools: list[types.Tool] | None = None
_unity_all_tool_names: set[str] | None = None

_godot_mcp_tools: list[types.Tool] | None = None
_godot_all_tool_names: set[str] | None = None

# Per-process cached bridge kind, set on first get_mcp_tools call.
_active_engine: str | None = None


def _convert_openai_to_mcp(
    schema: dict[str, Any],
    read_only_names: set[str] | frozenset[str] | None = None,
) -> types.Tool:
    """Convert a single OpenAI function-calling schema to an MCP Tool.

    When the tool's name is in ``read_only_names``, stamp it with a
    ``readOnlyHint`` annotation so MCP clients can auto-approve the call
    without prompting. Mutating tools are left un-annotated (the spec
    default, which clients treat as "may modify — confirm").
    """
    func = schema["function"]
    annotations = None
    if read_only_names and func["name"] in read_only_names:
        annotations = types.ToolAnnotations(readOnlyHint=True)
    return types.Tool(
        name=func["name"],
        description=func.get("description", ""),
        inputSchema=func.get("parameters", {"type": "object", "properties": {}}),
        annotations=annotations,
    )


def _build_tool_list(
    openai_schemas: list[dict[str, Any]],
    read_only_names: set[str] | frozenset[str] | None = None,
) -> tuple[list[types.Tool], set[str]]:
    """Convert schemas → MCP tools, dedupe by name, return (tools, names)."""
    converted = [_convert_openai_to_mcp(s, read_only_names) for s in openai_schemas]
    seen: set[str] = set()
    out: list[types.Tool] = []
    for t in converted:
        if t.name in seen:
            logger.warning(f"Duplicate tool name in schemas: {t.name!r} — keeping first occurrence")
            continue
        seen.add(t.name)
        out.append(t)
    return out, seen


def _get_unity_mcp_tools() -> list[types.Tool]:
    """Unity: filter to CORE_TOOLS for Claude Code's ~128-tool budget."""
    global _unity_mcp_tools, _unity_all_tool_names
    if _unity_mcp_tools is None:
        all_tools, names = _build_tool_list(get_unity_tool_schemas())
        _unity_all_tool_names = names
        _unity_mcp_tools = [t for t in all_tools if t.name in CORE_TOOLS]
        logger.info(f"Registered {len(_unity_mcp_tools)} core Unity tools ({len(names)} total available via bridge)")
    return _unity_mcp_tools


def _get_godot_mcp_tools() -> list[types.Tool]:
    """Godot: expose all 33 tools (no filtering needed — well under budget)."""
    global _godot_mcp_tools, _godot_all_tool_names
    if _godot_mcp_tools is None:
        all_tools, names = _build_tool_list(get_godot_tool_schemas(), GODOT_READ_ONLY_TOOLS)
        _godot_all_tool_names = names
        _godot_mcp_tools = all_tools
        logger.info(f"Registered {len(_godot_mcp_tools)} Godot tools")
    return _godot_mcp_tools


async def get_mcp_tools_async() -> list[types.Tool]:
    """Probe the bridge to decide engine, then return that engine's tools.

    Called from server.list_tools (which is async). Caches the detected
    engine so subsequent calls are no-ops on the probe path.
    """
    global _active_engine
    if _active_engine is None:
        _active_engine = await bridge.detect_bridge_kind()
        if _active_engine == "none":
            # No bridge reachable — default to Unity for backward compat.
            # Tools still appear in list_tools; dispatch will surface the
            # connection error if/when the user tries to invoke one.
            _active_engine = "unity"
            logger.warning(
                "No bridge reachable on probe — defaulting to Unity schemas. "
                "Start the editor and the next list_tools call will pick up the right engine."
            )
        else:
            logger.info(f"Active bridge engine: {_active_engine}")
    return _get_godot_mcp_tools() if _active_engine == "godot" else _get_unity_mcp_tools()


def get_mcp_tools() -> list[types.Tool]:
    """Sync wrapper that returns the active engine's tool list.

    Kept synchronous for backward compatibility with the existing
    list_tools call site. If the engine has never been probed (no async
    list_tools call yet) defaults to Unity — the eventual probe via
    get_mcp_tools_async will replace the cache on next async call.
    """
    if _active_engine == "godot":
        return _get_godot_mcp_tools()
    return _get_unity_mcp_tools()


def get_active_engine() -> str:
    """Return the currently-cached active engine ('unity' or 'godot') or
    'unknown' if no probe has run yet. Used by server.py to pick which
    bridge_version module to query for the warning prefix."""
    return _active_engine or "unknown"


def sanitize_args(arguments: dict[str, Any]) -> dict[str, Any]:
    """Normalize tool arguments for the Unity bridge.

    - Strip null values (Unity AI Gateway sends null for optional params).
    - Coerce ints/floats to strings (LLMs send 0.5 instead of "0.5" for string params).
    - Preserve bools as-is (isinstance bool returns True for int — guard against coercion).
    """
    sanitized: dict[str, Any] = {}
    for k, v in arguments.items():
        if v is None:
            continue
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            sanitized[k] = str(v)
        else:
            sanitized[k] = v
    return sanitized


def _is_asset_pipeline_enabled() -> bool:
    """Single source of truth for the MCP-side asset pipeline gate.

    Mirrors the env-var check in tools/__init__.py — kept in sync so a runtime
    flip (rare, but possible if a wrapper sets the env mid-process) is honored
    by dispatch even if the schema list is already cached.
    """
    import os

    return os.environ.get("GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", "").strip().lower() not in {"1", "true", "yes", "on"}


def _handle_find_asset_locally(arguments: dict[str, Any]) -> str:
    """Run the bundled asset_pipeline orchestrator locally — no bridge call.

    The MCP server hosts its own copy of the Kenney catalog so search works
    without a network round-trip.
    """
    from ..asset_pipeline import AssetSpec
    from ..asset_pipeline import search as _asset_search

    try:
        spec = AssetSpec.from_dict(arguments)
        candidates = _asset_search(spec)
        return json.dumps(
            {
                "success": True,
                "candidates": [c.to_dict() for c in candidates],
                "count": len(candidates),
            }
        )
    except Exception as exc:
        return json.dumps({"success": False, "error": f"find_asset failed: {exc}"})


_CLOUD_INJECTED_ARG_KEYS = frozenset(
    {
        "_resolvedUrl",
        "_resolvedLicense",
        "_resolvedAttribution",
        "_resolvedArchiveFormat",
        "_resolvedFileExtension",
    }
)


# Per-tool HTTP timeout overrides (seconds). Tools that do network I/O or
# heavy Unity work (multi-MB downloads, full-pack imports + AssetDatabase
# refresh) need longer than the default 30s, otherwise the MCP client times
# out and surfaces a failure even when the bridge eventually completes.
_PER_TOOL_TIMEOUTS: dict[str, float] = {
    "import_asset": 300.0,  # download + extract + per-file Unity importer config
    # compile_scripts triggers AssetDatabase.Refresh() on the Unity main thread
    # when no compile is already running. On large projects (thousands of
    # assets, pending texture imports, generated code) Refresh can block well
    # past the default 30s — the bridge can't even acknowledge the request
    # until the main thread yields, so the client surfaces ReadTimeout and the
    # follow-up retry stacks behind the still-running Refresh. 180s gives the
    # main thread room to finish even on a cold scene-open, while still
    # keeping a finite ceiling so a truly hung Editor surfaces a real error.
    "compile_scripts": 180.0,
}


def _preprocess_import_asset_args(arguments: dict[str, Any]) -> dict[str, Any] | str:
    """Inject the resolved download URL + license into args for the bridge.

    Returns the augmented args dict on success, or a JSON error string on
    failure (caller short-circuits with the error string).

    Strips any caller-supplied underscore-prefixed fields BEFORE attempting
    resolution so a fabricated URL never survives even when the catalog
    lookup fails.
    """
    # Strip first — order matters so failed-resolution doesn't leak fakes.
    cleaned = {k: v for k, v in arguments.items() if k not in _CLOUD_INJECTED_ARG_KEYS}

    if not cleaned.get("licenseAcknowledged"):
        return json.dumps(
            {
                "success": False,
                "error": (
                    "licenseAcknowledged must be true. Confirm with the user "
                    "that they accept the license shown in find_asset's preview."
                ),
            }
        )
    candidate_id = cleaned.get("candidateId") or cleaned.get("candidate_id")
    if not candidate_id:
        return json.dumps({"success": False, "error": "candidateId is required"})

    try:
        from ..asset_pipeline import fetch as _asset_fetch

        fr = _asset_fetch(candidate_id)
    except Exception as exc:
        return json.dumps({"success": False, "error": f"Could not resolve {candidate_id!r}: {exc}"})

    cleaned["_resolvedUrl"] = fr.download_url
    cleaned["_resolvedLicense"] = fr.license_at_fetch
    cleaned["_resolvedAttribution"] = fr.attribution_text or ""
    cleaned["_resolvedArchiveFormat"] = fr.archive_format
    cleaned["_resolvedFileExtension"] = fr.file_extension
    return cleaned


async def dispatch_tool_call(name: str, arguments: dict[str, Any]) -> str:
    """
    Execute a tool call by dispatching to the active engine's bridge.

    Returns the tool result as a JSON string.
    All tools (core + extended) are dispatchable even if not in the listed set.
    """
    # Engine detection runs once per process; the rest of this function
    # branches on the cached active engine.
    if _active_engine is None:
        # Trigger probe via the async helper. Safe — detect_bridge_kind
        # is cached and idempotent.
        await get_mcp_tools_async()

    if _active_engine == "godot":
        return await _dispatch_godot(name, arguments)

    return await _dispatch_unity(name, arguments)


async def _dispatch_unity(name: str, arguments: dict[str, Any]) -> str:
    """Dispatch path for the Unity HTTP bridge. Preserves all the legacy
    asset-pipeline / import-asset / find-asset special cases that don't
    apply to Godot."""
    # Asset pipeline gate — refuse early when disabled, regardless of cache state.
    if name in {"find_asset", "import_asset", "list_imported_assets"}:
        if not _is_asset_pipeline_enabled():
            return json.dumps(
                {
                    "success": False,
                    "error": (
                        "Asset pipeline is disabled "
                        "(GLADEKIT_MCP_DISABLE_ASSET_PIPELINE is set). Unset the "
                        "env var to re-enable find/import of external assets."
                    ),
                }
            )

    # find_asset is cloud-only in spirit — runs entirely against the bundled
    # catalog with no bridge round-trip.
    if name == "find_asset":
        return _handle_find_asset_locally(arguments)

    # import_asset needs URL injection before bridge dispatch.
    if name == "import_asset":
        prepped = _preprocess_import_asset_args(arguments)
        if isinstance(prepped, str):
            return prepped  # already a JSON error envelope
        arguments = prepped

    # Ensure the full tool name index is populated
    _get_unity_mcp_tools()
    if _unity_all_tool_names and name not in _unity_all_tool_names:
        return json.dumps(
            {
                "success": False,
                "message": f"Unknown tool: {name}. {len(_unity_all_tool_names)} Unity tools available.",
            }
        )

    try:
        timeout = _PER_TOOL_TIMEOUTS.get(name)
        if timeout is not None:
            result = await bridge.execute_tool(name, sanitize_args(arguments), timeout=timeout)
        else:
            result = await bridge.execute_tool(name, sanitize_args(arguments))
        return result
    except Exception as exc:
        logger.error(f"Tool execution error for {name}: {exc}")
        return json.dumps(
            {
                "success": False,
                "message": f"Error executing {name}: {str(exc)}",
            }
        )


async def _dispatch_godot(name: str, arguments: dict[str, Any]) -> str:
    """Dispatch path for the Godot WS bridge. Simpler than Unity — no
    asset-pipeline special cases, no compilation wait, no Unity-specific
    arg munging.

    The Godot bridge does its own snake_case/camelCase normalization (see
    ws_server.gd ToolUtils.normalize_args) so we don't sanitize here —
    sanitize_args was a Unity-specific arg-munging path that stringifies
    numbers to work around the Unity AI Gateway. Godot accepts native
    JSON types.
    """
    _get_godot_mcp_tools()
    if _godot_all_tool_names and name not in _godot_all_tool_names:
        return json.dumps(
            {
                "success": False,
                "message": f"Unknown tool: {name}. {len(_godot_all_tool_names)} Godot tools available.",
            }
        )

    try:
        return await bridge.godot_execute_tool(name, arguments)
    except Exception as exc:
        logger.error(f"Godot tool execution error for {name}: {exc}")
        return json.dumps(
            {
                "success": False,
                "message": f"Error executing {name}: {str(exc)}",
            }
        )
