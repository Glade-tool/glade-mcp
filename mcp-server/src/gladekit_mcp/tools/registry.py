"""
Dynamic MCP tool registration from OpenAI-format tool schemas.

Converts the 222+ Unity tool schemas (OpenAI function-calling format) into
MCP Tool definitions and dispatches tool calls to the Unity bridge.

OpenAI format:
    {"type": "function", "function": {"name": "...", "description": "...", "parameters": {...}}}

MCP format:
    Tool(name="...", description="...", inputSchema={...})

Tool exposure strategy
─────────────────────
Claude Code has a practical limit of ~128 tools before context overhead causes
tools to be silently dropped. We expose a curated CORE set (~80 tools) covering
the most commonly needed operations. All 200+ tools are still dispatchable via
the bridge — they just aren't advertised in the tool list.

Use get_relevant_tools (a meta-tool in server.py) to discover the full set and
learn which core tool handles a specialized need.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from mcp import types

from .. import bridge
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

# Cache: built once at first list_tools call
_mcp_tools: list[types.Tool] | None = None
_all_tool_names: set[str] | None = None


def _convert_openai_to_mcp(schema: dict[str, Any]) -> types.Tool:
    """Convert a single OpenAI function-calling schema to an MCP Tool."""
    func = schema["function"]
    return types.Tool(
        name=func["name"],
        description=func.get("description", ""),
        inputSchema=func.get("parameters", {"type": "object", "properties": {}}),
    )


def get_mcp_tools() -> list[types.Tool]:
    """Return core Unity tools as MCP Tool definitions (cached).

    Only CORE_TOOLS are listed to stay within Claude Code's tool-count budget.
    All tools remain callable via dispatch_tool_call regardless of listing.
    """
    global _mcp_tools, _all_tool_names
    if _mcp_tools is None:
        openai_schemas = get_unity_tool_schemas()
        all_tools_with_dupes = [_convert_openai_to_mcp(s) for s in openai_schemas]
        # Dedupe by name (MCP spec requires unique tool names; Windsurf hard-fails on duplicates).
        # Keep first occurrence and warn — collision usually means the same tool was registered in two category modules.
        seen: set[str] = set()
        all_tools: list[types.Tool] = []
        for t in all_tools_with_dupes:
            if t.name in seen:
                logger.warning(f"Duplicate tool name in schemas: {t.name!r} — keeping first occurrence")
                continue
            seen.add(t.name)
            all_tools.append(t)
        _all_tool_names = seen
        _mcp_tools = [t for t in all_tools if t.name in CORE_TOOLS]
        logger.info(f"Registered {len(_mcp_tools)} core tools ({len(_all_tool_names)} total available via bridge)")
    return _mcp_tools


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
    return os.environ.get(
        "GLADEKIT_MCP_DISABLE_ASSET_PIPELINE", ""
    ).strip().lower() not in {"1", "true", "yes", "on"}


def _handle_find_asset_locally(arguments: dict[str, Any]) -> str:
    """Run the bundled asset_pipeline orchestrator locally — no bridge call.

    The MCP server hosts its own copy of the Kenney catalog so search works
    without a cloud round-trip. Identical orchestrator and ranking logic as
    the Proxy backend.
    """
    from ..asset_pipeline import AssetSpec, search as _asset_search

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


_CLOUD_INJECTED_ARG_KEYS = frozenset({
    "_resolvedUrl",
    "_resolvedLicense",
    "_resolvedAttribution",
    "_resolvedArchiveFormat",
    "_resolvedFileExtension",
})


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
        return json.dumps(
            {"success": False, "error": f"Could not resolve {candidate_id!r}: {exc}"}
        )

    cleaned["_resolvedUrl"] = fr.download_url
    cleaned["_resolvedLicense"] = fr.license_at_fetch
    cleaned["_resolvedAttribution"] = fr.attribution_text or ""
    cleaned["_resolvedArchiveFormat"] = fr.archive_format
    cleaned["_resolvedFileExtension"] = fr.file_extension
    return cleaned


async def dispatch_tool_call(name: str, arguments: dict[str, Any]) -> str:
    """
    Execute a tool call by dispatching to the Unity bridge.

    Returns the tool result as a JSON string.
    All tools (core + extended) are dispatchable even if not in the listed set.
    """
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
    get_mcp_tools()
    if _all_tool_names and name not in _all_tool_names:
        return json.dumps(
            {
                "success": False,
                "message": f"Unknown tool: {name}. {len(_all_tool_names)} tools available.",
            }
        )

    try:
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
