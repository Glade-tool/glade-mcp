"""
Heuristic skill level calibration — local JSON storage, no account required.

Analyzes vocabulary in user messages to infer whether they're a beginner,
intermediate, or expert Unity developer. State is persisted to a local JSON
file in the Unity project directory so it carries over between sessions.

Detection is pure heuristics (regex + vocabulary matching, no LLM).
The skill level is injected into the system prompt to adapt response verbosity.

Storage: {project_root}/.gladekit/skill_level.json
  Falls back to ~/.gladekit/skill_level.json when project path is unavailable.

This feature runs entirely locally — no GladeKit account or API key needed.
"""

from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

logger = logging.getLogger("gladekit-mcp")

# EMA weight for blending new session score against stored confidence.
_EMA_ALPHA = 0.35

# Ratio thresholds: (expert_signals / total_signals)
_EXPERT_THRESHOLD = 0.28
_BEGINNER_THRESHOLD = 0.10

# Minimum messages before we commit a skill level to disk
_MIN_MESSAGES = 3

# ── Vocabulary lists ─────────────────────────────────────────────────────────

_EXPERT_TERMS: frozenset = frozenset(
    {
        "scriptableobject",
        "monobehaviour",
        "monobehavior",
        "rigidbody",
        "rigidbody2d",
        "charactercontroller",
        "navmesh",
        "navmeshagent",
        "navmeshobstacle",
        "animator",
        "animationclip",
        "animatorcontroller",
        "cinemachine",
        "vcam",
        "prefab",
        "addressables",
        "assetbundle",
        "timeline",
        "playable",
        "playablegraph",
        "hdrp",
        "urp",
        "srp",
        "shader",
        "hlsl",
        "shaderlab",
        "shadergraph",
        "materialproperty",
        "materialpropertyblock",
        "layermask",
        "physicsmaterial",
        "raycast",
        "spherecast",
        "overlapbox",
        "overlapsphere",
        "coroutine",
        "ienumerator",
        "waitforseconds",
        "quaternion",
        "slerp",
        "lerp",
        "mathf",
        "vector3",
        "vector2",
        "vector4",
        "editorwindow",
        "scriptedimporter",
        "propertydrawer",
        "jobsystem",
        "burst",
        "dots",
        "ecs",
        "serialization",
        "jsonutility",
        "serializefield",
        "uitoolkit",
        "textmeshpro",
        "singleton",
        "observer",
        "factory",
        "delegate",
        "lambda",
        "override",
        "virtual",
        "abstract",
        "async",
        "await",
    }
)

_EXPERT_PHRASES: frozenset = frozenset(
    {
        "blend tree",
        "state machine",
        "prefab variant",
        "asset bundle",
        "shader graph",
        "layer mask",
        "physics material",
        "inverse kinematics",
        "animator controller",
        "animation controller",
        "character controller",
        "nav mesh",
        "scriptable object",
        "virtual camera",
        "dot product",
        "cross product",
        "abstract class",
        "dependency injection",
        "event system",
        "input system",
        "render pipeline",
        "render texture",
        "post processing",
        "post-processing",
    }
)

_BEGINNER_PATTERNS: list[re.Pattern] = [
    re.compile(p, re.IGNORECASE)
    for p in [
        r"\bhow (do|can|should) i\b",
        r"\bwhat is\b",
        r"\bwhat are\b",
        r"\bwhat does\b",
        r"\bwhat'?s (a|an|the)\b",
        r"\bcan you\b",
        r"\bhelp me\b",
        r"\bi don'?t know\b",
        r"\bi'?m new\b",
        r"\bi'?m a beginner\b",
        r"\bi'?m (still )?learning\b",
        r"\bi'?m trying to\b",
        r"\bi want to\b",
        r"\bi need help\b",
        r"\bwhy (is|does|did|doesn'?t|isn'?t|won'?t)\b",
        r"\bwhat happens\b",
        r"\bexplain (to me|how|what|why)\b",
        r"\bfor beginners?\b",
        r"\btutorial\b",
    ]
]


# ── Scoring + classification ─────────────────────────────────────────────────


def _score_message(text: str) -> tuple[int, int]:
    """Return (expert_hits, beginner_hits) for a single message."""
    lowered = text.lower()
    tokens = set(re.findall(r"\b\w+\b", lowered))
    already_counted: set[str] = set()
    expert_hits = 0

    for phrase in _EXPERT_PHRASES:
        if phrase in lowered:
            expert_hits += 1
            already_counted.update(phrase.split())

    for term in _EXPERT_TERMS:
        if term in tokens and term not in already_counted:
            expert_hits += 1

    beginner_hits = sum(1 for pat in _BEGINNER_PATTERNS if pat.search(lowered))
    return expert_hits, beginner_hits


def _classify(confidence: float) -> str:
    if confidence >= _EXPERT_THRESHOLD:
        return "expert"
    if confidence <= _BEGINNER_THRESHOLD:
        return "beginner"
    return "intermediate"


# ── Session accumulator ──────────────────────────────────────────────────────

# Messages accumulated per session id. stdio always uses the "_stdio" key
# (one process = one conversation). HTTP uses the mcp-session-id header so
# concurrent clients don't pollute each other's calibration signal.
_session_messages: dict[str, list[str]] = {}

# Messages persisted per (session_id) — used to throttle disk writes so we
# don't re-persist on every single get_relevant_tools call.
_last_persisted_count: dict[str, int] = {}

# Persist after the threshold, then re-persist every Nth new message.
_PERSIST_EVERY_N_AFTER_THRESHOLD = 3


def record_message(message: str, session_id: str = "_stdio") -> None:
    """Add a user message to the given session's message pool."""
    if message and message.strip():
        _session_messages.setdefault(session_id, []).append(message.strip())


def should_persist_now(session_id: str = "_stdio") -> bool:
    """Cheap check — true iff the next maybe_persist call would actually write.

    Use this to gate expensive project-path lookups on the hot path so a
    no-op `maybe_persist` doesn't cost a bridge round-trip.
    """
    count = len(_session_messages.get(session_id, []))
    if count < _MIN_MESSAGES:
        return False
    last = _last_persisted_count.get(session_id, 0)
    return last == 0 or (count - last) >= _PERSIST_EVERY_N_AFTER_THRESHOLD


def maybe_persist(project_path: Optional[str], session_id: str = "_stdio") -> Optional[str]:
    """Persist skill level if this session has accumulated enough new signal.

    Called opportunistically from the hot path (no explicit session-end hook
    exists for stdio MCP). Writes on first crossing of `_MIN_MESSAGES`, then
    every `_PERSIST_EVERY_N_AFTER_THRESHOLD` new messages after that.
    """
    if not should_persist_now(session_id):
        return None
    level = update_from_session(project_path, session_id=session_id)
    _last_persisted_count[session_id] = len(_session_messages.get(session_id, []))
    return level


# ── Persistence ──────────────────────────────────────────────────────────────


def _skill_file_path(project_path: Optional[str]) -> Path:
    """Return the path to the skill_level.json file."""
    if project_path:
        base = Path(project_path) / ".gladekit"
    else:
        base = Path.home() / ".gladekit"
    return base / "skill_level.json"


def load_skill_level(project_path: Optional[str] = None) -> Optional[str]:
    """
    Load the persisted skill level from disk.

    Returns 'beginner', 'intermediate', 'expert', or None if not yet calibrated.
    Only returns a level once we have at least _MIN_MESSAGES sample_count.
    """
    path = _skill_file_path(project_path)
    if not path.exists():
        return None
    try:
        with open(path) as f:
            data = json.load(f)
        if data.get("sample_count", 0) < _MIN_MESSAGES:
            return None
        return data.get("skill_level") or None
    except json.JSONDecodeError:
        logger.warning(f"Corrupt skill_level.json at {path} — resetting. Delete the file to suppress this warning.")
        return None
    except Exception as exc:
        logger.debug(f"Could not load skill level: {exc}")
        return None


def _save_skill_level(project_path: Optional[str], level: str, confidence: float, count: int) -> None:
    path = _skill_file_path(project_path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as f:
            json.dump(
                {
                    "skill_level": level,
                    "confidence": round(confidence, 4),
                    "sample_count": count,
                    "updated_at": datetime.now(timezone.utc).isoformat(),
                },
                f,
                indent=2,
            )
        logger.debug(f"Saved skill level: {level} (confidence={confidence:.2f}, n={count})")
    except Exception as exc:
        logger.warning(f"Could not save skill level: {exc}")


def update_from_session(project_path: Optional[str] = None, session_id: str = "_stdio") -> Optional[str]:
    """
    Analyze accumulated session messages and update the persisted skill level.

    Returns the newly computed skill level, or None if too few messages.
    Called opportunistically from maybe_persist() — stdio has no session-end hook.
    """
    msgs = _session_messages.get(session_id, [])
    if len(msgs) < _MIN_MESSAGES:
        return None

    total_expert = 0
    total_beginner = 0
    for msg in msgs:
        e, b = _score_message(msg)
        total_expert += e
        total_beginner += b

    total_signals = total_expert + total_beginner
    if total_signals == 0:
        return None

    session_score = total_expert / total_signals

    # Load existing data for EMA blending
    path = _skill_file_path(project_path)
    old_confidence = session_score
    old_count = 0
    if path.exists():
        try:
            with open(path) as f:
                old_data = json.load(f)
            old_confidence = max(0.0, min(1.0, float(old_data.get("confidence", session_score))))
            old_count = int(old_data.get("sample_count", 0))
        except Exception:
            pass

    new_confidence = max(0.0, min(1.0, _EMA_ALPHA * session_score + (1 - _EMA_ALPHA) * old_confidence))
    new_level = _classify(new_confidence)
    new_count = old_count + len(msgs)

    _save_skill_level(project_path, new_level, new_confidence, new_count)
    logger.info(
        f"Skill calibration: {new_level} (confidence={new_confidence:.2f}, "
        f"expert={total_expert}, beginner={total_beginner}, n={len(msgs)})"
    )
    return new_level
