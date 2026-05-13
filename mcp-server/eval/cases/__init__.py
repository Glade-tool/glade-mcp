"""MCPEvalCase and MCPEvalResult — the core contracts of the MCP eval harness.

Test cases exercise the MCP protocol path: AI client → MCP server (stdio) →
Unity bridge (HTTP). Each case declares a prompt and an assertion contract
(required/forbidden tools, parameter checks); the harness runs it against
a mock bridge and produces a pass/fail result.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional


@dataclass
class ToolParamAssertion:
    """Assert that a specific tool was called with expected parameter values.

    Example:
        ToolParamAssertion("create_game_object", {"name": "Player"})
        → passes if any call to create_game_object included name="Player"

        ToolParamAssertion("set_transform", {"y": 5}, match="approx", tolerance=0.5)
        → passes if set_transform was called with y ≈ 5 (within 0.5)
    """

    tool_name: str
    expected_params: dict[str, Any]
    match: str = "exact"  # "exact", "contains", "approx"
    tolerance: float = 0.1  # only used when match="approx"

    def check(self, tool_calls_with_args: list[dict]) -> Optional[str]:
        """Return None on success, or a failure message."""
        matching_calls = [tc for tc in tool_calls_with_args if tc.get("name") == self.tool_name]
        if not matching_calls:
            return f"tool '{self.tool_name}' was never called"

        for tc in matching_calls:
            args = tc.get("args", {})
            if self._params_match(args):
                return None

        actual_params = [tc.get("args", {}) for tc in matching_calls]
        return (
            f"tool '{self.tool_name}' called but params didn't match: "
            f"expected {self.expected_params}, got {actual_params}"
        )

    def _params_match(self, actual: dict) -> bool:
        for key, expected_val in self.expected_params.items():
            actual_val = actual.get(key)
            if actual_val is None:
                return False

            if self.match == "approx":
                try:
                    if abs(float(actual_val) - float(expected_val)) > self.tolerance:
                        return False
                except (TypeError, ValueError):
                    return False
            elif self.match == "contains":
                if str(expected_val).lower() not in str(actual_val).lower():
                    return False
            else:  # exact
                if str(actual_val).lower() != str(expected_val).lower():
                    return False
        return True


@dataclass
class MCPEvalCase:
    """A single MCP evaluation test case."""

    id: str
    prompt: str
    description: str
    category: str

    # --- Assertion contract -------------------------------------------------
    required_tools: list[str] = field(default_factory=list)
    """ALL of these tool names must appear in tool_calls_made."""

    any_of_tools: list[str] = field(default_factory=list)
    """AT LEAST ONE of these must appear (OR-group)."""

    forbidden_tools: list[str] = field(default_factory=list)
    """NONE of these may appear."""

    param_assertions: list[ToolParamAssertion] = field(default_factory=list)
    """Tool parameter checks."""

    # --- Context / mock data -----------------------------------------------
    mock_scene: Optional[dict] = None
    """Scene context returned by the mock bridge's get_scene_hierarchy."""

    mock_tool_results: Optional[dict[str, Any]] = None
    """Per-tool result overrides: tool_name → result dict."""

    # --- Run config --------------------------------------------------------
    tags: list[str] = field(default_factory=list)
    """Arbitrary labels for filtering (e.g. 'beginner', 'scripting')."""

    max_iterations: int = 10
    """Max agentic loop iterations before force-stopping."""

    max_duration_seconds: Optional[float] = None
    """Per-case latency budget."""

    suite_type: str = "capability"
    """'capability' or 'regression'."""

    # --- Client-specific ---------------------------------------------------
    client: str = "any"
    """Target MCP client: 'any', 'claude-code', 'cursor', 'windsurf'."""

    llm_rubric: Optional[str] = None
    """Natural language rubric for LLM-based grading."""


@dataclass
class MCPEvalResult:
    """Outcome of running a single MCPEvalCase."""

    case_id: str
    prompt: str
    passed: bool

    tool_calls_made: list[str] = field(default_factory=list)
    """All tool names called, in order."""

    tool_calls_with_args: list[dict] = field(default_factory=list)
    """All tool calls with full arguments."""

    required_missing: list[str] = field(default_factory=list)
    forbidden_called: list[str] = field(default_factory=list)
    any_of_satisfied: bool = True
    param_assertion_failures: list[str] = field(default_factory=list)

    total_iterations: int = 0
    duration_seconds: float = 0.0
    category: str = ""
    suite_type: str = "capability"

    streaming_text: str = ""
    error: Optional[str] = None

    time_to_first_tool_call: Optional[float] = None
    latency_budget_exceeded: bool = False

    quality_score: int = 0

    @property
    def failure_reasons(self) -> list[str]:
        reasons: list[str] = []
        if self.error:
            reasons.append(f"error: {self.error}")
        if self.required_missing:
            reasons.append(f"missing required tools: {self.required_missing}")
        if self.forbidden_called:
            reasons.append(f"forbidden tools were called: {self.forbidden_called}")
        if not self.any_of_satisfied:
            reasons.append("none of the any_of_tools were called")
        if self.param_assertion_failures:
            for msg in self.param_assertion_failures:
                reasons.append(f"param check failed: {msg}")
        if self.latency_budget_exceeded:
            reasons.append(f"latency budget exceeded ({self.duration_seconds:.1f}s)")
        return reasons
