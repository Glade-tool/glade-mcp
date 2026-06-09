# GladeKit MCP Eval Harness

Regression and capability test suite for the MCP server and Unity bridge
integration. Tests the complete dispatch path: MCP tool call → bridge HTTP →
Unity response, using a mock Unity bridge (no real Unity instance needed).

Scope: this harness covers the MCP server's tool dispatch surface.

---

## Three test layers

| Layer | Tool | What it tests | Speed |
|-------|------|--------------|-------|
| **Unit tests** | `pytest` | Schema validity, registry logic, arg sanitization, task filter | Fast (<5s) |
| **Integration tests** | `pytest` + mock HTTP | Full MCP→bridge round-trip, meta-tools, resources | Medium (~10s) |
| **E2E eval harness** | `python -m eval.run` | Tool dispatch through MCP server against mock/live Unity | Configurable |

---

## Quick start

```bash
# From mcp-server/

# 1. Install dev dependencies
pip install -e ".[dev]"

# 2. Run pytest (unit + integration tests)
pytest tests/ -v

# 3. Run the MCP eval harness (core suite, mock bridge)
python -m eval.run

# 4. Run all eval suites
python -m eval.run --suite all --save

# 5. Run against live Unity
python -m eval.run --live-unity --verbose
```

---

## Pytest test suite

```bash
# All tests
pytest tests/ -v

# Specific test files
pytest tests/test_registry.py -v      # schema validation, core tools, arg sanitization
pytest tests/test_task_filter.py -v    # keyword → category mapping
pytest tests/test_meta_tools.py -v     # session memory, resources, meta-tools
pytest tests/test_integration.py -v    # full HTTP round-trip with mock bridge
pytest tests/test_bridge.py -v         # bridge error handling
pytest tests/test_server.py -v         # tool listing smoke test
pytest tests/test_cloud.py -v          # cloud integration (RAG, memory)
pytest tests/test_search.py -v         # semantic search fallback
pytest tests/test_skill.py -v          # skill level persistence
```

### What the tests cover

**test_registry.py** — Tool schema validation
- All 222+ schemas have required fields (type, name, description, parameters)
- No duplicate tool names
- All names are snake_case
- Core tools are a subset of all tools and fit within Claude Code's ~128 budget
- Essential everyday tools are in the core set
- OpenAI → MCP schema conversion works correctly
- Null values stripped, numbers coerced, bools preserved (LLM quirk handling)
- Unknown tool dispatch returns error JSON, not exception

**test_task_filter.py** — Task-aware filtering
- 30+ parametrized cases: message → correct category (physics, materials, animation, etc.)
- Empty/unrecognized messages return empty set (fail-open)
- Multi-domain messages match multiple categories
- Always-included categories (core, scene, scripting) are in filtered results
- Unrecognized messages get all 235+ tools

**test_meta_tools.py** — MCP server features
- Session memory: store, recall, multiple facts, empty fact rejection
- get_relevant_tools returns category info
- Resource listing includes all expected URIs
- Resource reading: health (up/down), context, session memory
- Unknown resource returns error JSON

**test_integration.py** — Full round-trip
- Real HTTP mock server simulating Unity bridge
- Tool dispatch: args forwarded correctly through bridge
- Scene context gathering works
- Unreachable bridge returns errors gracefully
- Meta-tools bypass bridge (session memory works without Unity)
- Compilation wait returns on count increment

---

## Eval harness suites

| Suite | Cases | File | Focus |
|-------|-------|------|-------|
| `core` | 17 | `cases/core.py` | Single-tool dispatch for each major category |
| `extended` | 12 | `cases/extended.py` | Multi-step workflows (create+position, material pipeline, animator setup) |
| `negative` | 8 | `cases/negative.py` | Error handling, sanitization, edge cases |
| `all` | 37 | — | All suites combined |

```bash
python -m eval.run --suite core        # fast smoke test
python -m eval.run --suite negative    # error handling tests
python -m eval.run --suite all         # full regression
```

---

## Eval options

| Flag | Default | Description |
|------|---------|-------------|
| `--suite` | `core` | Test suite to run |
| `--filter SUBSTR` | — | Only run cases whose id or tag contains SUBSTR |
| `--concurrency N` | `1` | Parallel cases |
| `--timeout N` | `60` | Per-case timeout in seconds |
| `--latency-budget N` | — | Global latency budget |
| `--live-unity` | off | Use real Unity bridge instead of mock |
| `--unity-url` | `http://localhost:8765` | Unity bridge URL (with `--live-unity`) |
| `--save` | off | Write `eval/results/mcp_eval_<timestamp>.json` |
| `--verbose` | off | Show tool calls for passing cases too |

---

## Running specific groups

```bash
# By category
python -m eval.run --suite all --filter gameobjects
python -m eval.run --suite all --filter scripting
python -m eval.run --suite all --filter animation

# By difficulty
python -m eval.run --suite all --filter beginner
python -m eval.run --suite all --filter intermediate

# Error handling only
python -m eval.run --suite all --filter error-handling

# Multi-step workflows
python -m eval.run --suite all --filter multi-tool

# Regression cases only
python -m eval.run --suite all --filter regression

# Meta-tools (session memory, get_relevant_tools)
python -m eval.run --suite all --filter meta
```

---

## How it works

```
eval client              MCP server              mock bridge
─────────────           ────────────────         ─────────────
call_tool() ──────────► dispatch_tool_call()
                        sanitize args
                        ──────────────────────►  POST /api/tools/execute
                        ◄──────────────────────  {"success": true, ...}
                        parse result
◄──────────── TextContent result
assert tools,
params, timing
```

### Assertion model

Each `MCPEvalCase` has:

| Field | Meaning |
|-------|---------|
| `required_tools` | ALL must be called |
| `any_of_tools` | At least one must be called |
| `forbidden_tools` | None may be called |
| `param_assertions` | Parameter value checks (exact, contains, approx) |

---

## Adding new cases

```python
from eval.cases import MCPEvalCase, ToolParamAssertion

MCPEvalCase(
    id="mcp-nav-01",
    prompt="Add a NavMeshAgent to the Enemy",
    description="NavMesh component via MCP dispatch",
    category="navmesh",
    required_tools=["set_navmesh_agent"],
    param_assertions=[
        ToolParamAssertion("set_navmesh_agent", {"gameObjectName": "Enemy"}),
    ],
    mock_scene=SCENE_WITH_ENEMY,
    tags=["intermediate", "navmesh"],
    suite_type="capability",
)
```

Add to the appropriate suite file and import in `eval/run.py`.

---

## CI integration

```yaml
# .github/workflows/mcp-tests.yml
- name: Run MCP unit + integration tests
  run: |
    pip install -e ".[dev]"
    pytest tests/ -v --tb=short
  working-directory: mcp-server

- name: Run MCP eval harness
  run: python -m eval.run --suite all --save
  working-directory: mcp-server
```

Exit code 1 on any failure, compatible with standard CI gates.

---

## Scope

This harness tests the MCP server + bridge dispatch path. It calls the MCP
server API directly with a mock HTTP bridge — no live LLM is involved. The
goal is to answer "does the MCP→bridge path work?" — schema validity, tool
dispatch, argument shaping, and bridge contract conformance.
