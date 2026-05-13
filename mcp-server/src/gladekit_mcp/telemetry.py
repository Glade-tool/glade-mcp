"""Batch discipline telemetry.

Tracks how often the AI client uses ``batch_execute`` versus issuing
read-only tool calls one at a time. Phase 2.1 + ``batch_execute`` are
shipped latency wins, but only if the model actually uses them — every
sequential-when-batchable burst is wasted latency the infrastructure
already paid to save.

Heuristic for "should have batched":
    A read-only tool call lands within ``gap_window_s`` (default 4s) of
    another single read-only tool call from the same session, with no
    intervening mutating call or ``batch_execute`` invocation. The MCP
    protocol gives us no AI-message boundaries, so a tight time gap is
    the only signal we have for "the model could have emitted both calls
    in one shot."

Counters are per MCP session and reset on session end. Each transition
is also emitted as a structured ``BATCH_DISCIPLINE`` log line so offline
analysis (CloudWatch / grep) can aggregate without a metrics pipeline.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Optional

logger = logging.getLogger("gladekit-mcp")

# ── Read-only tool catalog ────────────────────────────────────────────────────
# Kept as a literal set rather than derived from the schema so the classification
# stays stable across schema refactors (renaming a tool's category should not
# silently reclassify it as mutating).
READ_ONLY_TOOLS: frozenset[str] = frozenset(
    {
        # Asset / material queries
        "check_asset_exists",
        "list_materials",
        "get_material_usage",
        "find_materials_by_shader",
        "get_shader_info",
        "list_available_shaders",
        "list_assets",
        # GameObject / component queries
        "get_gameobject_info",
        "get_gameobject_components",
        "get_component_inspector_properties",
        "get_selection",
        "find_game_objects",
        "list_children",
        # Prefab queries
        "get_prefab_info",
        # Scene queries
        "get_scene_hierarchy",
        "get_unity_console_logs",
        # Script queries
        "get_script_content",
        "find_scripts",
        "search_scripts",
        # Lighting queries
        "get_light_info",
        "get_render_settings",
        "get_lighting_settings",
        # Project settings queries
        "get_quality_settings",
        "get_render_pipeline_asset_settings",
        # Camera queries
        "get_camera_properties",
        "get_cinemachine_virtual_camera_properties",
        # VFX queries
        "get_particle_system_properties",
        # Audio queries
        "get_audio_source_properties",
        # Physics queries
        "get_rigidbody_properties",
        "get_character_controller_properties",
        "get_collider_properties",
        "raycast",
        "linecast",
        "overlap_sphere",
        "overlap_box",
        "sphere_cast",
        "box_cast",
        "get_collision_matrix",
        # UI queries
        "list_ui_hierarchy",
        "get_ui_element_info",
        "find_ui_elements_by_type",
        "check_ui_element_exists",
        "get_ui_event_handlers",
        # Animation queries
        "get_animation_clip_info",
        "get_animation_clip_curves",
        "get_sprite_animation_info",
        "get_animator_controller_info",
        "get_animator_state_info",
        "get_animator_transition_info",
        "get_animator_layer_info",
        "get_animator_parameter_info",
        "get_blend_tree_info",
        # NavMesh queries
        "get_navmesh_areas",
        "get_navmesh_info",
        "get_navmesh_bounds",
        "calculate_navmesh_path",
        "sample_navmesh_position",
        # Profiler queries
        "start_profiler",
        "stop_profiler",
        "get_frame_timing",
        "get_memory_stats",
        "get_gc_allocations",
        "get_profiler_counters",
        "enable_frame_debugger",
        "get_frame_debugger_events",
        # Input system queries
        "get_input_system_info",
        "list_legacy_input_axes",
        # Session introspection
        "get_session_summary",
    }
)


def is_read_only(tool_name: str) -> bool:
    """Return True if ``tool_name`` is a read-only Unity tool."""
    return tool_name in READ_ONLY_TOOLS


# ── Tracker state ─────────────────────────────────────────────────────────────

DEFAULT_GAP_WINDOW_S: float = 4.0


@dataclass
class BatchDisciplineCounters:
    """Per-session running totals.

    A "burst" is a sequence of read-only single calls separated by less than
    ``gap_window_s`` from each other, with no mutation or batch_execute in
    between. Every call after the first in a burst is counted as
    ``should_have_batched`` — that's the metric callers care about.
    """

    # Read-only calls that arrived inside a batch_execute payload.
    batched_readonly_calls: int = 0
    # Mutating calls that arrived inside a batch_execute payload.
    batched_mutating_calls: int = 0
    # Number of batch_execute invocations (regardless of size).
    batch_invocations: int = 0
    # Read-only single calls that started a fresh burst (or were isolated).
    single_readonly_calls: int = 0
    # Read-only single calls that landed inside an existing burst — the
    # model could have emitted these as part of the previous batch.
    should_have_batched: int = 0
    # Mutating single calls. Tracked so we can compute correct ratios.
    single_mutating_calls: int = 0
    # Bursts that contained ≥2 read-only calls (one missed-batch opportunity).
    missed_batch_bursts: int = 0

    # Internal: timestamp of the most recent read-only single call. Reset to
    # None whenever a mutation or a batch_execute lands (both legitimately
    # interrupt a burst).
    _last_single_readonly_ts: Optional[float] = None
    # Internal: did the current burst already contribute a missed-batch burst?
    # Prevents double-counting when 3 reads land in a row.
    _current_burst_flagged: bool = False

    _started_at: float = field(default_factory=time.time)


# Session-id → counters. The session_id key is supplied by the caller (in
# server.py we use ``id(server.request_context.session)`` packaged via
# ``_current_session_id``); under stdio there's only one session.
_session_counters: Dict[str, BatchDisciplineCounters] = {}


def _counters_for(session_id: str) -> BatchDisciplineCounters:
    return _session_counters.setdefault(session_id, BatchDisciplineCounters())


def reset(session_id: Optional[str] = None) -> None:
    """Drop counters for a session (or all sessions if ``session_id`` is None)."""
    if session_id is None:
        _session_counters.clear()
    else:
        _session_counters.pop(session_id, None)


# A clock indirection so tests can supply a deterministic monotonic source.
# Defaults to ``time.monotonic`` because we only need elapsed deltas.
_now: Callable[[], float] = time.monotonic


def set_clock(clock: Callable[[], float]) -> None:
    """Override the monotonic clock — for tests only."""
    global _now
    _now = clock


def reset_clock() -> None:
    """Restore the default monotonic clock."""
    global _now
    _now = time.monotonic


# ── Recording ─────────────────────────────────────────────────────────────────


def record_single_call(
    session_id: str,
    tool_name: str,
    *,
    gap_window_s: float = DEFAULT_GAP_WINDOW_S,
) -> str:
    """Record one tool call dispatched outside ``batch_execute``.

    Returns the classification label so callers (and tests) can reason about
    it: ``"single_readonly"``, ``"should_have_batched"``, or ``"single_mutating"``.
    """
    c = _counters_for(session_id)
    now = _now()

    if is_read_only(tool_name):
        c.single_readonly_calls += 1
        last_ts = c._last_single_readonly_ts
        if last_ts is not None and (now - last_ts) <= gap_window_s:
            c.should_have_batched += 1
            if not c._current_burst_flagged:
                c.missed_batch_bursts += 1
                c._current_burst_flagged = True
            kind = "should_have_batched"
        else:
            # Fresh burst — either no prior call or the gap was too long.
            c._current_burst_flagged = False
            kind = "single_readonly"
        c._last_single_readonly_ts = now
    else:
        c.single_mutating_calls += 1
        # Mutation interrupts the burst — subsequent reads legitimately
        # depend on the mutation completing.
        c._last_single_readonly_ts = None
        c._current_burst_flagged = False
        kind = "single_mutating"

    _emit(session_id, kind=kind, tool=tool_name)
    return kind


def record_batch_execute(session_id: str, calls: list) -> None:
    """Record a ``batch_execute`` invocation containing ``calls`` (list of dicts
    each shaped ``{"toolName": str, ...}``).

    A batch_execute invocation always counts as good discipline regardless of
    contents — the model picked the cheap meta-tool. We only break out
    read-only vs. mutating in the per-call counters so the totals stay
    comparable to ``single_*`` counters.
    """
    c = _counters_for(session_id)
    c.batch_invocations += 1
    for call in calls:
        tool_name = (call or {}).get("toolName", "") if isinstance(call, dict) else ""
        if is_read_only(tool_name):
            c.batched_readonly_calls += 1
        else:
            c.batched_mutating_calls += 1
    # A batch interrupts any prior burst — the model demonstrated discipline.
    c._last_single_readonly_ts = None
    c._current_burst_flagged = False
    _emit(session_id, kind="batch_execute", num_calls=len(calls))


# ── Reporting ─────────────────────────────────────────────────────────────────


def get_summary(session_id: str) -> Dict[str, Any]:
    """Return a serializable snapshot of one session's discipline."""
    c = _counters_for(session_id)
    total_readonly = c.batched_readonly_calls + c.single_readonly_calls
    # Of the read-only calls, what fraction came in via batch_execute?
    batched_ratio: Optional[float] = None
    if total_readonly > 0:
        batched_ratio = c.batched_readonly_calls / total_readonly
    # Of the read-only single calls, what fraction were "should have batched"?
    missed_ratio: Optional[float] = None
    if c.single_readonly_calls > 0:
        missed_ratio = c.should_have_batched / c.single_readonly_calls
    return {
        "session_id": session_id,
        "batch_invocations": c.batch_invocations,
        "batched_readonly_calls": c.batched_readonly_calls,
        "batched_mutating_calls": c.batched_mutating_calls,
        "single_readonly_calls": c.single_readonly_calls,
        "single_mutating_calls": c.single_mutating_calls,
        "should_have_batched": c.should_have_batched,
        "missed_batch_bursts": c.missed_batch_bursts,
        "batched_readonly_ratio": _round(batched_ratio),
        "missed_batch_ratio": _round(missed_ratio),
        "total_readonly_calls": total_readonly,
        "total_calls": (
            c.batched_readonly_calls + c.batched_mutating_calls + c.single_readonly_calls + c.single_mutating_calls
        ),
        "session_age_s": round(time.time() - c._started_at, 1),
    }


def render_summary_text(session_id: str) -> str:
    """Render a human-readable summary, suitable for an MCP resource body."""
    s = get_summary(session_id)
    if s["total_calls"] == 0:
        return "No tool calls recorded yet for this session."
    lines = [
        f"Batch discipline (session {session_id}):",
        f"  total tool calls: {s['total_calls']}  (read-only: {s['total_readonly_calls']})",
        f"  batch_execute invocations: {s['batch_invocations']}",
        f"  read-only via batch_execute: {s['batched_readonly_calls']}",
        f"  read-only single calls: {s['single_readonly_calls']}",
        f"  ↳ should-have-batched: {s['should_have_batched']} across {s['missed_batch_bursts']} burst(s)",
        f"  mutating single calls: {s['single_mutating_calls']}",
    ]
    if s["batched_readonly_ratio"] is not None:
        lines.append(
            f"  batched_readonly_ratio: "
            f"{s['batched_readonly_ratio']:.2f} "
            "(read-only calls that arrived via batch_execute)"
        )
    if s["missed_batch_ratio"] is not None:
        lines.append(
            f"  missed_batch_ratio: "
            f"{s['missed_batch_ratio']:.2f} "
            "(single read-only calls that landed inside a tight-gap burst)"
        )
    if (s["batched_readonly_ratio"] is not None and s["batched_readonly_ratio"] < 0.5) or (
        s["missed_batch_ratio"] is not None and s["missed_batch_ratio"] >= 0.3
    ):
        lines.append(
            "  Hint: the model is leaving latency on the table — prefer batch_execute for sibling read-only lookups."
        )
    return "\n".join(lines)


# ── Internal helpers ──────────────────────────────────────────────────────────


def _emit(session_id: str, *, kind: str, **fields: Any) -> None:
    """Emit a structured BATCH_DISCIPLINE log line.

    Logged at INFO so it surfaces alongside ``TURN_TIMING``-style structured
    events without enabling debug logging. Failure to serialize is silently
    swallowed — telemetry must never break the request path.
    """
    payload = {"session_id": session_id, "kind": kind, **fields}
    try:
        logger.info("BATCH_DISCIPLINE %s", json.dumps(payload, separators=(",", ":")))
    except Exception:
        pass


def _round(v: Optional[float]) -> Optional[float]:
    return round(v, 3) if v is not None else None
