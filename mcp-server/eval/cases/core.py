"""
Core MCP eval cases — tests the most common tool dispatch paths.

These verify that tools are callable through the MCP server → bridge path
and return valid results. Covers the everyday surface: GameObjects, scripts,
components, materials, transforms.
"""

from __future__ import annotations

from eval.cases import MCPEvalCase, ToolParamAssertion
from eval.harness.mock_bridge import SCENE_WITH_ENEMY

# ── GameObjects ──────────────────────────────────────────────────────────────

CORE = [
    MCPEvalCase(
        id="mcp-go-01",
        prompt="Create a new empty GameObject called Player",
        description="Basic create_game_object dispatch through MCP",
        category="gameobjects",
        required_tools=["create_game_object"],
        param_assertions=[
            ToolParamAssertion("create_game_object", {"name": "Player"}),
        ],
        tags=["beginner", "regression"],
        suite_type="regression",
    ),
    MCPEvalCase(
        id="mcp-go-02",
        prompt="Create a Cube primitive",
        description="create_primitive dispatch",
        category="gameobjects",
        required_tools=["create_primitive"],
        param_assertions=[
            ToolParamAssertion("create_primitive", {"primitiveType": "Cube"}),
        ],
        tags=["beginner", "regression"],
        suite_type="regression",
    ),
    MCPEvalCase(
        id="mcp-go-03",
        prompt="Destroy the Enemy object",
        description="destroy_game_object dispatch",
        category="gameobjects",
        required_tools=["destroy_game_object"],
        param_assertions=[
            ToolParamAssertion("destroy_game_object", {"gameObjectName": "Enemy"}),
        ],
        mock_scene=SCENE_WITH_ENEMY,
        tags=["beginner"],
    ),
    # ── Transforms ───────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-tf-01",
        prompt="Move the Player to position (3, 0, -5)",
        description="set_transform with position params",
        category="transforms",
        required_tools=["set_transform"],
        param_assertions=[
            ToolParamAssertion("set_transform", {"gameObjectName": "Player"}),
        ],
        tags=["beginner", "regression"],
        suite_type="regression",
    ),
    # ── Physics ──────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-phys-01",
        prompt="Add a Rigidbody to the Player",
        description="add_rigidbody dispatch",
        category="physics",
        required_tools=["add_rigidbody"],
        param_assertions=[
            ToolParamAssertion("add_rigidbody", {"gameObjectName": "Player"}),
        ],
        tags=["beginner", "regression"],
        suite_type="regression",
    ),
    MCPEvalCase(
        id="mcp-phys-02",
        prompt="Add a BoxCollider to the Ground",
        description="create_collider dispatch",
        category="physics",
        required_tools=["create_collider"],
        param_assertions=[
            ToolParamAssertion("create_collider", {"gameObjectName": "Ground"}),
        ],
        tags=["beginner"],
    ),
    # ── Scripts ──────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-scr-01",
        prompt="Create a C# script called PlayerController",
        description="create_script dispatch + compilation wait",
        category="scripting",
        required_tools=["create_script"],
        param_assertions=[
            ToolParamAssertion("create_script", {"scriptName": "PlayerController"}, match="contains"),
        ],
        tags=["beginner", "regression"],
        suite_type="regression",
    ),
    # ── Materials ─────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-mat-01",
        prompt="Create a new material called RedMetal",
        description="create_material dispatch",
        category="materials",
        required_tools=["create_material"],
        param_assertions=[
            ToolParamAssertion("create_material", {"name": "RedMetal"}, match="contains"),
        ],
        tags=["beginner"],
    ),
    # ── Lighting ──────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-lit-01",
        prompt="Create a Point Light",
        description="create_light dispatch",
        category="lighting",
        required_tools=["create_light"],
        param_assertions=[
            ToolParamAssertion("create_light", {"lightType": "Point"}),
        ],
        tags=["beginner"],
    ),
    # ── Camera ───────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-cam-01",
        prompt="Create a new camera",
        description="create_camera dispatch",
        category="camera",
        required_tools=["create_camera"],
        tags=["beginner"],
    ),
    # ── Audio ────────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-aud-01",
        prompt="Add an AudioSource to the Player",
        description="create_audio_source dispatch",
        category="audio",
        required_tools=["create_audio_source"],
        param_assertions=[
            ToolParamAssertion("create_audio_source", {"gameObjectName": "Player"}),
        ],
        tags=["beginner"],
    ),
    # ── UI ────────────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-ui-01",
        prompt="Create a Canvas",
        description="create_canvas dispatch",
        category="ui",
        required_tools=["create_canvas"],
        tags=["beginner"],
    ),
    # ── Prefabs ──────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-pfb-01",
        prompt="Create a prefab from the Player object",
        description="create_prefab dispatch",
        category="prefabs",
        required_tools=["create_prefab"],
        param_assertions=[
            ToolParamAssertion("create_prefab", {"gameObjectName": "Player"}),
        ],
        tags=["beginner"],
    ),
    # ── Animation ─────────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-anim-01",
        prompt="Create an animator controller called PlayerAnimator",
        description="create_animator_controller dispatch",
        category="animation",
        required_tools=["create_animator_controller"],
        param_assertions=[
            ToolParamAssertion("create_animator_controller", {"name": "PlayerAnimator"}, match="contains"),
        ],
        tags=["intermediate"],
    ),
    # ── Scene queries ────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-scene-01",
        prompt="Get the current scene hierarchy",
        description="get_scene_hierarchy dispatch (read-only)",
        category="scene",
        required_tools=["get_scene_hierarchy"],
        forbidden_tools=["destroy_game_object", "create_game_object"],
        tags=["beginner", "read-only", "regression"],
        suite_type="regression",
    ),
    # ── Meta-tools ───────────────────────────────────────────────────────────
    MCPEvalCase(
        id="mcp-meta-01",
        prompt="Store a fact: Player uses CharacterController",
        description="Session memory store + recall",
        category="meta",
        required_tools=["remember_for_session"],
        param_assertions=[
            ToolParamAssertion("remember_for_session", {"fact": "Player uses CharacterController"}, match="contains"),
        ],
        tags=["meta"],
    ),
    MCPEvalCase(
        id="mcp-meta-02",
        prompt="Find relevant tools for adding physics",
        description="get_relevant_tools meta-tool",
        category="meta",
        required_tools=["get_relevant_tools"],
        param_assertions=[
            ToolParamAssertion("get_relevant_tools", {"message": "adding physics"}, match="contains"),
        ],
        tags=["meta"],
    ),
]
