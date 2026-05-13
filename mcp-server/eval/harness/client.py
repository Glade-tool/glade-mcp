"""
MCP eval client — drives tool calls through the MCP server via subprocess.

Two modes:
1. Direct mode (default): calls the MCP server's Python API directly in-process.
   Fast, no subprocess overhead, good for most evals.
2. Stdio mode (--stdio): spawns the MCP server as a subprocess and communicates
   via JSON-RPC over stdio, testing the real transport path.

For AI-in-the-loop evals, use the AI client mode (--ai) which sends prompts
to an LLM and observes what MCP tools it calls.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Optional

from eval.cases import MCPEvalCase, MCPEvalResult


def _compute_quality_score(
    tool_calls_made: list[str],
    total_iterations: int,
    duration: float,
    passed: bool,
    case: MCPEvalCase,
    param_assertion_failures: list[str],
) -> int:
    """Score 0-100: full marks on pass, deductions for assertion failures."""
    if not passed:
        return 0

    score = 100
    expected_count = len(case.required_tools) + (1 if case.any_of_tools else 0)
    if expected_count > 0:
        extra = max(0, len(tool_calls_made) - expected_count)
        score -= min(30, extra * 5)

    extra_iters = max(0, total_iterations - 1)
    score -= min(30, extra_iters * 5)

    if case.max_duration_seconds and case.max_duration_seconds > 0:
        ratio = duration / case.max_duration_seconds
        if ratio > 0.9:
            score -= 20
        elif ratio > 0.75:
            score -= 10

    score -= min(30, len(param_assertion_failures) * 10)
    return max(0, score)


async def run_case_direct(
    case: MCPEvalCase,
    bridge_url: str,
    timeout: float = 120,
    latency_budget: Optional[float] = None,
) -> MCPEvalResult:
    """
    Run a case by calling MCP server functions directly (in-process).

    This tests the MCP server logic + bridge HTTP path without the stdio
    transport layer. For most eval purposes this is sufficient and fast.
    """
    from unittest.mock import patch

    from gladekit_mcp import bridge as bridge_mod
    from gladekit_mcp.server import call_tool

    tool_calls_made: list[str] = []
    tool_calls_with_args: list[dict] = []
    streaming_text = ""
    total_iterations = 0
    error: Optional[str] = None
    time_to_first_tool_call: Optional[float] = None
    start = time.monotonic()

    # Wrap bridge.execute_tool to route to our mock/live bridge URL
    _original_execute = bridge_mod.execute_tool

    async def _patched_execute(name, args, bridge_url_ignored=None, **kwargs):
        return await _original_execute(name, args, bridge_url=bridge_url, **kwargs)

    try:
        with patch.object(bridge_mod, "execute_tool", _patched_execute):
            for tool_name in case.required_tools:
                # Build default args based on tool name
                args = _default_args_for_tool(tool_name, case)
                elapsed = time.monotonic() - start
                if elapsed > timeout:
                    error = f"timed out after {timeout}s"
                    break

                if time_to_first_tool_call is None:
                    time_to_first_tool_call = round(time.monotonic() - start, 3)

                result = await call_tool(tool_name, args)
                total_iterations += 1

                tool_calls_made.append(tool_name)
                tool_calls_with_args.append({"name": tool_name, "args": args})

                # Check result is valid
                text = result[0].text if result else ""
                try:
                    data = json.loads(text)
                    if not data.get("success", True):
                        error = f"{tool_name} failed: {data.get('message', 'unknown')}"
                        break
                except json.JSONDecodeError:
                    pass  # Non-JSON responses (meta-tools) are fine

    except asyncio.TimeoutError:
        error = f"timed out after {timeout}s"
    except Exception as exc:
        error = f"unexpected error: {exc}"

    duration = round(time.monotonic() - start, 2)

    # Evaluate assertions
    tool_set = set(tool_calls_made)
    required_missing = [t for t in case.required_tools if t not in tool_set]
    forbidden_called = [t for t in case.forbidden_tools if t in tool_set]
    any_of_satisfied = not case.any_of_tools or any(t in tool_set for t in case.any_of_tools)

    param_assertion_failures: list[str] = []
    for pa in case.param_assertions:
        failure = pa.check(tool_calls_with_args)
        if failure:
            param_assertion_failures.append(failure)

    effective_budget = case.max_duration_seconds or latency_budget
    latency_budget_exceeded = effective_budget is not None and duration > effective_budget

    passed = (
        error is None
        and not required_missing
        and not forbidden_called
        and any_of_satisfied
        and not param_assertion_failures
        and not latency_budget_exceeded
    )

    quality_score = _compute_quality_score(
        tool_calls_made, total_iterations, duration, passed, case, param_assertion_failures
    )

    return MCPEvalResult(
        case_id=case.id,
        prompt=case.prompt,
        passed=passed,
        tool_calls_made=tool_calls_made,
        tool_calls_with_args=tool_calls_with_args,
        required_missing=required_missing,
        forbidden_called=forbidden_called,
        any_of_satisfied=any_of_satisfied,
        param_assertion_failures=param_assertion_failures,
        total_iterations=total_iterations,
        duration_seconds=duration,
        category=case.category,
        suite_type=case.suite_type,
        streaming_text=streaming_text,
        error=error,
        time_to_first_tool_call=time_to_first_tool_call,
        latency_budget_exceeded=latency_budget_exceeded,
        quality_score=quality_score,
    )


def _default_args_for_tool(tool_name: str, case: MCPEvalCase) -> dict:
    """Generate minimal valid args for a tool call based on the case context."""
    # Check param_assertions for expected args
    for pa in case.param_assertions:
        if pa.tool_name == tool_name:
            return dict(pa.expected_params)

    # Fallback: minimal args for common tools
    _DEFAULTS: dict[str, dict] = {
        "create_game_object": {"name": "TestObject"},
        "create_primitive": {"primitiveType": "Cube"},
        "destroy_game_object": {"gameObjectName": "TestObject"},
        "set_transform": {"gameObjectName": "TestObject", "position": "0,0,0"},
        "set_local_transform": {"gameObjectName": "TestObject", "position": "0,0,0"},
        "add_component": {"gameObjectName": "TestObject", "componentType": "BoxCollider"},
        "remove_component": {"gameObjectName": "TestObject", "componentType": "BoxCollider"},
        "add_rigidbody": {"gameObjectName": "TestObject"},
        "create_collider": {"gameObjectName": "TestObject", "colliderType": "Box"},
        "create_script": {
            "scriptName": "TestScript",
            "code": "using UnityEngine;\npublic class TestScript : MonoBehaviour { }",
        },
        "modify_script": {
            "scriptName": "TestScript",
            "code": "using UnityEngine;\npublic class TestScript : MonoBehaviour { void Start() {} }",
        },
        "get_scene_hierarchy": {},
        "get_gameobject_info": {"gameObjectName": "Player"},
        "find_game_objects": {"searchTerm": "Player"},
        "create_material": {"name": "TestMaterial"},
        "assign_material_to_renderer": {"gameObjectName": "TestObject", "materialPath": "Assets/Materials/Test.mat"},
        "create_light": {"lightType": "Point"},
        "set_light_properties": {"gameObjectName": "Point Light", "intensity": "1.0"},
        "create_prefab": {"gameObjectName": "TestObject"},
        "instantiate_prefab": {"prefabPath": "Assets/Prefabs/Test.prefab"},
        "create_animator_controller": {"name": "TestAnimator"},
        "add_animator_state": {"controllerPath": "Assets/Animations/Test.controller", "stateName": "Idle"},
        "add_animator_transition": {
            "controllerPath": "Assets/Animations/Test.controller",
            "sourceState": "Idle",
            "destinationState": "Run",
        },
        "add_animator_parameters": {
            "controllerPath": "Assets/Animations/Test.controller",
            "parameterName": "Speed",
            "parameterType": "Float",
        },
        "assign_animator_controller": {
            "gameObjectName": "TestObject",
            "controllerPath": "Assets/Animations/Test.controller",
        },
        "create_canvas": {},
        "create_ui_element": {"elementType": "Button", "parentName": "Canvas"},
        "create_camera": {},
        "set_camera_properties": {"gameObjectName": "Main Camera", "fieldOfView": "60"},
        "create_audio_source": {"gameObjectName": "TestObject"},
        "set_audio_source_properties": {"gameObjectName": "TestObject", "volume": "1.0"},
        "set_game_object_active": {"gameObjectName": "TestObject", "active": True},
        "set_game_object_parent": {"gameObjectName": "Child", "parentName": "Parent"},
        "duplicate_game_object": {"gameObjectName": "TestObject"},
        "rename_game_object": {"gameObjectName": "TestObject", "newName": "RenamedObject"},
        "save_scene": {},
        "think": {"thought": "Planning next step"},
        "set_render_settings": {"ambientIntensity": "1.0"},
        "create_character_controller": {"gameObjectName": "TestObject"},
        "change_material_shader": {"materialPath": "Assets/Materials/Test.mat", "shaderName": "Standard"},
        "set_material_property": {
            "materialPath": "Assets/Materials/Test.mat",
            "propertyName": "_Color",
            "value": "1,0,0,1",
        },
        "compile_scripts": {},
        "get_unity_console_logs": {},
    }
    return _DEFAULTS.get(tool_name, {})
