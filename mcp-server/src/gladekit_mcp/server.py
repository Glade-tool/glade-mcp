"""
GladeKit MCP Server — connects AI clients to Unity Editor.

Uses the low-level mcp.server.Server API for tool registration (we have
222+ pre-existing JSON schemas) and FastMCP-style helpers for resources.
Runs on stdio transport for compatibility with Cursor, Claude Code, Windsurf.
"""

from __future__ import annotations

import json
import logging
import os

from mcp import types
from mcp.server import Server
from mcp.server.stdio import stdio_server

from . import (
    DEFAULT_HTTP_HOST,
    DEFAULT_HTTP_PATH,
    DEFAULT_HTTP_PORT,
    bridge,
    bridge_version,
    cloud,
    godot_bridge_version,
    search,
    skill,
    telemetry,
)
from .prompts import build_prompt_from_bridge
from .tools.registry import dispatch_tool_call, get_active_engine, get_mcp_tools_async, sanitize_args
from .tools.task_filter import get_relevant_tool_summary

logger = logging.getLogger("gladekit-mcp")

_INSTRUCTIONS = (
    "You are connected to a live game-engine editor (Unity or Godot) via GladeKit. "
    "Use the tools exposed in this session for all engine work: scene and node "
    "creation, scripts, materials, physics, UI, lighting, audio, and animation. "
    "Do not edit serialized scene or asset files directly (.unity, .prefab, .asset, "
    ".meta, .tscn, .tres); they will corrupt. Inspect live state via the read tools "
    "(get_scene_hierarchy on Unity, get_scene_tree on Godot, plus get_gameobject_info "
    "/ get_node_info and the find_* tools) instead of inferring from files.\n\n"
    "On Unity: before creating scripts involving player movement or input handling, "
    "read the 'Project Configuration' resource (unity://project/info) to determine "
    "which Input System API to use (NEW InputSystem vs. legacy Input.GetAxis). "
    "Call get_relevant_tools with a task description to discover extended tools "
    "beyond the core set.\n\n"
    "On Godot: call get_project_info first for a single-call snapshot of the project "
    "(engine version, renderer, current scene, enabled addons, input map) so you do "
    "not burn calls on cold-start exploration."
)

server = Server(
    "gladekit-mcp",
    instructions=_INSTRUCTIONS,
)

# ── In-session memory ─────────────────────────────────────────────────────────
# Facts the AI stores during the current session. Under stdio (one process =
# one conversation) there's a single ServerSession. Under streamable-HTTP each
# mcp-session-id gets its own ServerSession, so using id(session) as the key
# scopes state per client without reaching into the transport internals.
_session_memory: dict[str, list[str]] = {}


def _current_session_id() -> str:
    """Return a stable per-client key. Falls back to "_stdio" outside a request."""
    try:
        ctx = server.request_context
    except LookupError:
        return "_stdio"
    return f"mcp-{id(ctx.session)}"


def _current_session_memory() -> list[str]:
    return _session_memory.setdefault(_current_session_id(), [])


# ── Meta-tools ────────────────────────────────────────────────────────────────

_META_TOOLS = [
    types.Tool(
        name="get_relevant_tools",
        description=(
            "Given a Unity task description, returns the most relevant tools "
            "for that task — including extended tools beyond the core listed set. "
            "Call this before starting specialized work (animator blend trees, "
            "navmesh, IK, terrain, particle systems, cinemachine, etc.) to "
            "discover the right tool names. Extended tools are callable even "
            "though they don't appear in the tool list."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "message": {
                    "type": "string",
                    "description": "The user's task description (e.g. 'make the cube red', 'set up a blend tree').",
                },
            },
            "required": ["message"],
        },
    ),
    types.Tool(
        name="remember_for_session",
        description=(
            "Store a fact or piece of context for the current session. "
            "Use this to remember project-specific details, user preferences, "
            "or intermediate findings that you'll need to reference later in this conversation. "
            "Facts are stored in memory for the lifetime of this MCP session only."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "fact": {
                    "type": "string",
                    "description": "The fact or context to remember (e.g. 'Player uses CharacterController, not Rigidbody').",
                },
            },
            "required": ["fact"],
        },
    ),
    types.Tool(
        name="recall_session_memories",
        description=(
            "Retrieve all facts stored with remember_for_session during this session. "
            "Call this to recall project context you captured earlier in the conversation."
        ),
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    types.Tool(
        name="batch_execute",
        description=(
            "Execute multiple tool calls in a single request to Unity. "
            "Reduces round-trip overhead for multi-step operations like "
            "create object → set transform → add component → create material → assign material. "
            "Each call runs sequentially on the Unity main thread. "
            "Returns per-call results with individual success/failure status — "
            "partial failures do not abort the batch."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "calls": {
                    "type": "array",
                    "description": "Array of tool calls to execute sequentially.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "toolName": {
                                "type": "string",
                                "description": "The tool name (e.g. 'create_game_object').",
                            },
                            "arguments": {
                                "type": "object",
                                "description": "Arguments for the tool call.",
                            },
                        },
                        "required": ["toolName"],
                    },
                    "minItems": 1,
                    "maxItems": 50,
                },
            },
            "required": ["calls"],
        },
    ),
    types.Tool(
        name="search_project_scripts",
        description=(
            "Semantically search project scripts by relevance to a query. "
            "Returns the top matching scripts ranked by cosine similarity. "
            f"{'Requires OPENAI_API_KEY — not currently set, will return unranked results.' if not search.is_available() else 'Semantic search enabled (OPENAI_API_KEY detected).'}"
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "What you're looking for (e.g. 'player movement', 'health system', 'inventory').",
                },
                "top_n": {
                    "type": "integer",
                    "description": "Number of results to return (default: 5, max: 20).",
                    "default": 5,
                },
            },
            "required": ["query"],
        },
    ),
]


# ── Tool handlers ─────────────────────────────────────────────────────────────


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    """Return the active engine's tools + meta-tools as MCP tool definitions.

    Probes for the active bridge kind on first call (cached for the
    lifetime of the process) and returns Unity or Godot schemas
    accordingly. Meta-tools are Unity-specific today — get_relevant_tools,
    remember_for_session, batch_execute, search_project_scripts all
    assume the Unity bridge's tool surface and context-gather endpoint.
    On Godot we expose just the 63 native tools.
    """
    engine_tools = await get_mcp_tools_async()
    if get_active_engine() == "godot":
        return engine_tools
    return engine_tools + _META_TOOLS


@server.call_tool()
async def call_tool(
    name: str,
    arguments: dict,
) -> list[types.ContentBlock]:
    """Public entry — dispatches to _handle_tool_call and prepends a one-shot
    bridge-staleness warning to the first text content. Engine-aware: probes
    the active bridge kind and queries that engine's version-gate module.
    Computed before dispatch so even error responses carry the warning on the
    first call after startup."""
    # Pick the right version-gate module for the active engine. Probe is
    # cached so this stays cheap after the first call.
    active = get_active_engine()
    if active == "godot":
        warning = await godot_bridge_version.get_warning_prefix()
    else:
        # Default to Unity for the legacy / unknown case.
        warning = await bridge_version.get_warning_prefix()
    result = await _handle_tool_call(name, arguments)
    if warning and result and getattr(result[0], "text", None) is not None:
        result[0] = types.TextContent(type="text", text=warning + result[0].text)
    return result


async def _handle_tool_call(
    name: str,
    arguments: dict,
) -> list[types.ContentBlock]:
    """Dispatch a tool call to the Unity bridge or handle meta-tools."""
    arguments = arguments or {}

    # ── get_relevant_tools ────────────────────────────────────────────────────
    if name == "get_relevant_tools":
        message = arguments.get("message", "")
        # Side-effect: accumulate message for skill calibration, then persist
        # opportunistically (every 3rd message past the threshold). stdio has
        # no session-end hook, so inline-throttled persistence is the only
        # reliable way to commit calibration to disk. skill.should_persist_now
        # cheaply short-circuits the common case so we don't pay for a bridge
        # health check on every call.
        if message:
            sid = _current_session_id()
            skill.record_message(message, session_id=sid)
            if skill.should_persist_now(session_id=sid):
                try:
                    health = await bridge.check_health()
                    project_path = health.get("projectPath") or None
                except bridge.UnityBridgeError:
                    project_path = None
                skill.maybe_persist(project_path, session_id=sid)
        result = get_relevant_tool_summary(message)

        # Inject RAG context from cloud knowledge base (paid tier), scoped to
        # the active engine so a Godot session pulls Godot knowledge.
        if message and cloud.is_available():
            engine = get_active_engine()
            if engine not in ("unity", "godot"):
                engine = "unity"
            rag_context = await cloud.fetch_rag_context(message, engine=engine)
            if rag_context:
                result += f"\n\n## {engine.capitalize()} Knowledge Base\n\n{rag_context}"

        return [types.TextContent(type="text", text=result)]

    # ── remember_for_session ──────────────────────────────────────────────────
    if name == "remember_for_session":
        fact = arguments.get("fact", "").strip()
        if not fact:
            return [types.TextContent(type="text", text="No fact provided.")]
        memory = _current_session_memory()
        memory.append(fact)

        # Persist to cloud memory (paid tier, best-effort)
        if cloud.is_available():
            try:
                health = await bridge.check_health()
                project_name = os.path.basename(health.get("projectPath", ""))
                if project_name:
                    await cloud.save_session_memory(project_name, fact)
            except Exception:
                pass  # Cloud save is best-effort

        return [
            types.TextContent(
                type="text",
                text=f"Stored. Session memory now has {len(memory)} item(s).",
            )
        ]

    # ── recall_session_memories ───────────────────────────────────────────────
    if name == "recall_session_memories":
        memory = _current_session_memory()
        if not memory:
            return [types.TextContent(type="text", text="No session memories stored yet.")]
        items = "\n".join(f"{i + 1}. {fact}" for i, fact in enumerate(memory))
        return [types.TextContent(type="text", text=f"Session memories:\n{items}")]

    # ── batch_execute ────────────────────────────────────────────────────────
    if name == "batch_execute":
        calls = arguments.get("calls", [])
        if not calls:
            return [types.TextContent(type="text", text="No tool calls provided.")]
        if len(calls) > 50:
            return [types.TextContent(type="text", text="Maximum 50 tool calls per batch.")]

        # Sanitize arguments the same way dispatch_tool_call does
        sanitized_calls = [
            {
                "toolName": call.get("toolName", ""),
                "arguments": sanitize_args(call.get("arguments", {}) or {}),
            }
            for call in calls
        ]

        # Record discipline BEFORE dispatch — what we measure is the model's
        # decision to batch, not the bridge's success.
        telemetry.record_batch_execute(_current_session_id(), sanitized_calls)

        try:
            results = await bridge.execute_batch(sanitized_calls)
        except Exception as exc:
            return [types.TextContent(type="text", text=f"Batch execution error: {exc}")]

        # Format results as readable text
        lines = [f"Batch executed {len(sanitized_calls)} tool(s):\n"]
        for i, r in enumerate(results):
            status = "OK" if r.get("success") else "FAILED"
            tool = r.get("toolName", sanitized_calls[i]["toolName"] if i < len(sanitized_calls) else "?")
            if r.get("success"):
                result_str = r.get("result", "")
                # Truncate very long results in the summary
                if len(result_str) > 500:
                    result_str = result_str[:500] + "..."
                lines.append(f"[{i + 1}] {tool}: {status} — {result_str}")
            else:
                lines.append(f"[{i + 1}] {tool}: {status} — {r.get('error', 'Unknown error')}")

        return [types.TextContent(type="text", text="\n".join(lines))]

    # ── search_project_scripts ────────────────────────────────────────────────
    if name == "search_project_scripts":
        query = arguments.get("query", "")
        top_n = min(int(arguments.get("top_n", 5)), 20)
        if not query:
            return [types.TextContent(type="text", text="No query provided.")]
        try:
            ctx = await bridge.gather_scene_context()
            scripts = ctx.get("scripts", [])
            if not scripts:
                return [types.TextContent(type="text", text="No scripts found in Unity project.")]
            results = await search.search_scripts(query, scripts, top_n=top_n)
            if not results:
                return [types.TextContent(type="text", text="No matching scripts found.")]
            lines = [f"Top {len(results)} scripts for '{query}':\n"]
            for r in results:
                sim = r.get("similarity")
                sim_str = f" (similarity: {sim:.3f})" if sim is not None else ""
                lines.append(f"- {r.get('name', '?')} [{r.get('path', '')}]{sim_str}")
            if not search.is_available():
                lines.append("\nNote: Set OPENAI_API_KEY to enable semantic ranking.")
            return [types.TextContent(type="text", text="\n".join(lines))]
        except bridge.UnityBridgeError as e:
            return [types.TextContent(type="text", text=f"Could not reach Unity bridge: {e}")]

    # ── Unity bridge tools ────────────────────────────────────────────────────
    # Record discipline for direct (non-batched) dispatch. Meta-tools like
    # get_relevant_tools and remember_for_session are excluded above so they
    # don't pollute the metric — they're prompt-continuation sugar, not
    # batchable Unity calls.
    telemetry.record_single_call(_current_session_id(), name)
    result = await dispatch_tool_call(name, arguments)
    image_blocks = _maybe_image_content(result)
    if image_blocks is not None:
        return image_blocks
    return [types.TextContent(type="text", text=result)]


def _maybe_image_content(result: str):
    """Turn a vision tool's result into native MCP image content.

    Tools like ``look_at_game_view`` return a normal JSON result that also
    carries an ``image_base64`` field. When present, return a
    ``[TextContent, ImageContent]`` pair so MCP clients render the screenshot
    instead of dumping a base64 wall of text. Returns ``None`` for ordinary
    (text-only) results.
    """
    if not result or "image_base64" not in result:
        return None
    try:
        parsed = json.loads(result)
    except (json.JSONDecodeError, TypeError, ValueError):
        return None
    if not isinstance(parsed, dict):
        return None
    b64 = parsed.get("image_base64")
    if not isinstance(b64, str) or not b64:
        return None
    mime = parsed.get("image_mime") or "image/png"
    message = parsed.get("message") or "Captured the game view."
    return [
        types.TextContent(type="text", text=message),
        types.ImageContent(type="image", data=b64, mimeType=mime),
    ]


# ── Resources ─────────────────────────────────────────────────────────────────


@server.list_resources()
async def list_resources() -> list[types.Resource]:
    return [
        types.Resource(
            uri="unity://health",
            name="Unity Bridge Health",
            description="Connection status and Unity project info",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://context",
            name="Unity Project Context",
            description="Full scene hierarchy, scripts, packages, selection, and project settings",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://scene/hierarchy",
            name="Scene Hierarchy",
            description="Current scene's GameObject hierarchy",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://project/scripts",
            name="Project Scripts",
            description="List of C# scripts in the Unity project",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://selection",
            name="Current Selection",
            description="Currently selected GameObjects in the Unity Editor",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://glade-md",
            name="Game Design Document (GLADE.md)",
            description="Game design document from the Unity project root — genre, mechanics, art style, design pillars",
            mimeType="text/markdown",
        ),
        types.Resource(
            uri="unity://session-memory",
            name="Session Memory",
            description="Facts and context stored with remember_for_session during this conversation",
            mimeType="text/plain",
        ),
        types.Resource(
            uri="unity://project/info",
            name="Project Configuration",
            description="Input system mode (NEW/OLD/BOTH), render pipeline, default shader, and other project settings",
            mimeType="application/json",
        ),
        types.Resource(
            uri="unity://telemetry/batch-discipline",
            name="Batch Discipline Telemetry",
            description=(
                "Per-session counters and ratios for batch_execute usage vs. "
                "sequential read-only single calls. Diagnostic only — useful "
                "for verifying that the model is actually using batch_execute "
                "for sibling read-only lookups."
            ),
            mimeType="application/json",
        ),
    ]


@server.read_resource()
async def read_resource(uri: str) -> str:
    uri_str = str(uri)

    if uri_str == "unity://health":
        try:
            health = await bridge.check_health()
            return json.dumps(health, indent=2)
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e), "status": "unreachable"})

    if uri_str == "unity://context":
        try:
            ctx = await bridge.gather_scene_context()

            # Best-effort GLADE.md enrichment — failures here must not fail the resource.
            try:
                health = await bridge.check_health()
                project_path = health.get("projectPath", "")
                if project_path:
                    glade_path = os.path.join(project_path, "GLADE.md")
                    if os.path.exists(glade_path):
                        with open(glade_path, "r", encoding="utf-8") as f:
                            glade_content = f.read()
                            if len(glade_content) <= 2000:
                                ctx["gladeMarkdown"] = glade_content
                            else:
                                ctx["gladeMarkdown"] = glade_content[:2000] + "\n\n[GLADE.md truncated...]"
            except Exception:
                pass

            return json.dumps(ctx, indent=2)
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e)})

    if uri_str == "unity://scene/hierarchy":
        try:
            ctx = await bridge.gather_scene_context()
            return json.dumps(ctx.get("sceneHierarchy", []), indent=2)
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e)})

    if uri_str == "unity://project/scripts":
        try:
            ctx = await bridge.gather_scene_context()
            scripts = ctx.get("scripts", [])
            return json.dumps(
                [{"name": s.get("name"), "path": s.get("path")} for s in scripts],
                indent=2,
            )
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e)})

    if uri_str == "unity://selection":
        try:
            ctx = await bridge.gather_scene_context()
            return json.dumps(ctx.get("selection", {}), indent=2)
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e)})

    if uri_str == "unity://glade-md":
        try:
            health = await bridge.check_health()
            project_path = health.get("projectPath", "")
            if not project_path:
                return "GLADE.md not available: Unity bridge did not report project path."
            glade_path = os.path.join(project_path, "GLADE.md")
            if not os.path.exists(glade_path):
                return "No GLADE.md found in project root. Create one to provide game design context."
            with open(glade_path, "r", encoding="utf-8") as f:
                content = f.read()
            if len(content) > 6000:
                content = content[:6000] + "\n\n[GLADE.md truncated at ~1500 tokens]"
            return content
        except bridge.UnityBridgeError as e:
            return f"GLADE.md not available: {e}"

    if uri_str == "unity://session-memory":
        memory = _current_session_memory()
        if not memory:
            return "No session memories stored yet. Use remember_for_session to store facts."
        return "\n".join(f"{i + 1}. {fact}" for i, fact in enumerate(memory))

    if uri_str == "unity://telemetry/batch-discipline":
        summary = telemetry.get_summary(_current_session_id())
        return json.dumps(summary, indent=2)

    if uri_str == "unity://project/info":
        try:
            ctx = await bridge.gather_scene_context()
            project_info = ctx.get("projectInfo", {})
            # Extract only essential project configuration
            filtered_info = {
                "inputSystem": project_info.get("inputSystem"),
                "renderPipeline": project_info.get("renderPipeline"),
                "defaultShader": project_info.get("defaultShader"),
                "unityVersion": project_info.get("unityVersion"),
                "projectName": project_info.get("projectName"),
            }
            return json.dumps(filtered_info, indent=2)
        except bridge.UnityBridgeError as e:
            return json.dumps({"error": str(e)})

    return json.dumps({"error": f"Unknown resource: {uri_str}"})


# ── Prompts ───────────────────────────────────────────────────────────────────


@server.list_prompts()
async def list_prompts() -> list[types.Prompt]:
    return [
        types.Prompt(
            name="unity-assistant",
            description=(
                "Full GladeKit system prompt for Unity development. Includes render pipeline "
                "guidance, input system rules, tool discipline, and GLADE.md game design context. "
                "Use this prompt to get the best results from Unity tools."
            ),
        ),
    ]


@server.get_prompt()
async def get_prompt(name: str, arguments: dict | None = None) -> types.GetPromptResult:
    if name == "unity-assistant":
        # Determine project path for skill calibration
        project_path = None
        try:
            health = await bridge.check_health()
            project_path = health.get("projectPath")
        except bridge.UnityBridgeError:
            pass

        # Load persisted skill level
        skill_level = skill.load_skill_level(project_path)

        # Build combined memory block: cloud memories + session notes
        memory_parts = []

        # Cloud memories (paid tier — conventions + past sessions)
        if cloud.is_available() and project_path:
            project_name = os.path.basename(project_path)
            cloud_memories = await cloud.fetch_cloud_memories(project_name)
            if cloud_memories:
                memory_parts.append(cloud_memories)

        # Session memories (current conversation, always available)
        session_memory = _current_session_memory()
        if session_memory:
            items = "\n".join(f"- {fact}" for fact in session_memory)
            memory_parts.append(f"### Session Notes\n\n{items}")

        project_memories = "\n\n".join(memory_parts) if memory_parts else None

        prompt_text = await build_prompt_from_bridge(
            skill_level=skill_level,
            project_memories=project_memories,
        )
        return types.GetPromptResult(
            messages=[
                types.PromptMessage(
                    role="user",
                    content=types.TextContent(type="text", text=prompt_text),
                )
            ],
        )
    raise ValueError(f"Unknown prompt: {name}")


# ── Entry point ───────────────────────────────────────────────────────────────


def _banner(transport: str) -> str:
    from . import __version__
    from . import search as search_mod

    bridge_url = os.environ.get("UNITY_BRIDGE_URL", "http://localhost:8765")
    search_status = "ENABLED" if search_mod.is_available() else "DISABLED (set OPENAI_API_KEY to enable)"
    cloud_status = "ENABLED" if cloud.is_available() else "DISABLED (set GLADEKIT_API_KEY to enable)"
    return (
        f"gladekit-mcp v{__version__} | transport: {transport} | bridge: {bridge_url} "
        f"| search: {search_status} | cloud: {cloud_status}"
    )


async def run_server():
    """Run the MCP server on stdio transport."""
    import sys

    print(_banner("stdio"), file=sys.stderr)
    # Warn early if either bridge is reachable but stale. Both checks are
    # silent when their respective bridge is offline — we re-check on the
    # first tool call. Order doesn't matter — both are independent.
    await bridge_version.check_on_startup()
    await godot_bridge_version.check_on_startup()
    try:
        async with stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream,
                write_stream,
                server.create_initialization_options(),
            )
    finally:
        await bridge.aclose_client()
        await cloud.aclose_client()


def build_http_app(
    host: str = DEFAULT_HTTP_HOST,
    port: int = DEFAULT_HTTP_PORT,
    path: str = DEFAULT_HTTP_PATH,
):
    """Build a Starlette ASGI app serving the MCP server over streamable HTTP.

    - Mounts the streamable-HTTP transport at ``path`` (default ``/mcp``).
    - Adds a ``/health`` endpoint for connection checks.
    - Enables DNS rebinding protection when binding to localhost. When the user
      explicitly opts into LAN binding (non-loopback host), protection is
      disabled so external clients can reach the server.
    """
    import contextlib

    from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
    from mcp.server.transport_security import TransportSecuritySettings
    from starlette.applications import Starlette
    from starlette.requests import Request
    from starlette.responses import JSONResponse
    from starlette.routing import Route

    from . import __version__

    is_loopback = host in ("127.0.0.1", "localhost", "::1")
    if is_loopback:
        security_settings = TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=[f"127.0.0.1:{port}", f"localhost:{port}"],
            allowed_origins=[f"http://127.0.0.1:{port}", f"http://localhost:{port}"],
        )
    else:
        security_settings = TransportSecuritySettings(enable_dns_rebinding_protection=False)

    session_manager = StreamableHTTPSessionManager(
        app=server,
        json_response=False,
        stateless=False,
        security_settings=security_settings,
        session_idle_timeout=1800,
    )

    class _MCPAsgiApp:
        """Pass-through ASGI wrapper so Starlette routes it as an ASGI app
        (accepting all methods) rather than a GET-only view function. Per-client
        state is keyed off the MCP ServerSession identity via _current_session_id()
        at handler time, so we don't need to inspect headers here.
        """

        def __init__(self, manager):
            self._manager = manager

        async def __call__(self, scope, receive, send):
            await self._manager.handle_request(scope, receive, send)

    mcp_asgi = _MCPAsgiApp(session_manager)

    async def health(_request: Request) -> JSONResponse:
        return JSONResponse(
            {
                "status": "ok",
                "version": __version__,
                "transport": "http",
                "mcpPath": path,
            }
        )

    normalized_path = path if path.startswith("/") else "/" + path

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        async with session_manager.run():
            yield

    return Starlette(
        routes=[
            Route("/health", endpoint=health, methods=["GET"]),
            Route(normalized_path, endpoint=mcp_asgi),
        ],
        lifespan=lifespan,
    )


def run_http_server(
    host: str = DEFAULT_HTTP_HOST,
    port: int = DEFAULT_HTTP_PORT,
    path: str = DEFAULT_HTTP_PATH,
) -> None:
    """Run the MCP server on streamable HTTP transport via uvicorn."""
    import sys

    try:
        import uvicorn
    except ImportError as e:  # pragma: no cover
        raise SystemExit(
            "HTTP transport requires uvicorn + starlette. Install with: pip install 'gladekit-mcp[http]'"
        ) from e

    is_loopback = host in ("127.0.0.1", "localhost", "::1")
    if not is_loopback:
        print(
            f"WARNING: binding to {host}:{port} exposes GladeKit MCP on the network. "
            "DNS-rebinding protection is disabled for non-loopback binds — ensure the "
            "network is trusted.",
            file=sys.stderr,
        )

    print(_banner("http"), file=sys.stderr)
    print(
        f"gladekit-mcp HTTP server listening at http://{host}:{port}{path}",
        file=sys.stderr,
    )

    app = build_http_app(host=host, port=port, path=path)
    uvicorn.run(app, host=host, port=port, log_level="warning")
