# Contributing to GladeKit MCP

Thanks for your interest in contributing! This guide covers everything you need to get started.

## Setup

```bash
# Clone the repo
git clone https://github.com/Glade-tool/glade-mcp.git
cd glade-mcp/mcp-server

# Create a virtual environment and install dependencies
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"
```

## Development workflow

1. **Fork the repo** and create a feature branch from `main`.
2. **Make your changes** — keep commits focused and atomic.
3. **Run tests and lint** before submitting:

```bash
# Run tests
pytest tests/ -v

# Run linter
ruff check src/ tests/

# Format code
ruff format src/ tests/
```

4. **Open a pull request** against `main` with a clear description of what changed and why.

## Adding a new tool

A new Unity tool requires changes in two places:

**1. C# implementation** (`unity-bridge/Editor/Tools/Implementations/<Category>/MyTool.cs`):

```csharp
public class MyTool : ITool
{
    public string Name => "my_tool";
    public string Execute(Dictionary<string, object> args)
    {
        // ... Unity Editor API calls ...
        return ToolUtils.CreateSuccessResponse("Done", extras);
    }
}
```

**2. Python schema** (`mcp-server/src/gladekit_mcp/tools/<category>.py`):

Add an entry to the category's tool list following the existing format (OpenAI function-calling schema). Keep descriptions precise — the AI reads them to decide when to call the tool.

Tools are auto-discovered via reflection at startup — no manual registration needed beyond these two files.

## Code style

- Python 3.10+, async/await throughout
- Formatted with `ruff format`, linted with `ruff check`
- Type hints on all public functions
- Line length: 120 characters

## Testing

- Unit tests live in `tests/` and use `pytest` + `pytest-asyncio`
- Tests mock the Unity bridge HTTP calls — no running Unity instance needed
- The `eval/` directory contains integration test harnesses for live testing

## Reporting issues

Open an issue on GitHub with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, Python version, Unity version, AI client)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
