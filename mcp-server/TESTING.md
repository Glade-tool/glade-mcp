# GladeKit MCP Testing Guide

This guide walks you through verifying that GladeKit works correctly with your AI client and Unity Editor.

## Setup (one-time)

1. **Unity**: Open your project and install the bridge package.
   - **Window > Package Manager > + > Add package from git URL...**
   - Paste: `https://github.com/Glade-tool/glade-mcp.git?path=/unity-bridge`
   - Wait for import, then open an empty scene.

2. **AI Client**: Follow the config instructions in [README.md](README.md) for your client (Cursor, Claude Code, Windsurf, etc).

3. **Verify**: In your AI client, check that the MCP server is connected.
   - Claude Code: `/mcp` → `gladekit-unity` shows green dot with tool count.
   - Cursor: Settings > MCP > `gladekit-unity` shows green indicator.

4. **Optional**: Create a `GLADE.md` file in your Unity project root with a line like:
   ```markdown
   # My Game

   Genre: 3D platformer
   ```
   The server will inject this into prompts automatically.

---

## Test 1: Bridge Health & Resources

These tests verify that the MCP server can talk to Unity and read project context.

### Test 1a: Bridge is healthy

**Prompt:**

```
Read the `unity://health` resource.
```

**Expected result:**
A JSON object showing:

- `status`: "ok"
- `unityVersion`: your Unity version (e.g., "6000.3.13f1")
- `projectName`: your project name
- `isCompiling`: false
- `error`: empty string

If the bridge isn't running, you'll see an error message and a note to open Unity.

---

### Test 1b: Scene hierarchy

**Prompt:**

```
Read the `unity://scene/hierarchy` resource.
```

**Expected result:**
A JSON list of all GameObjects in the open scene, including:

- Position, rotation, scale
- Component types (Camera, Light, Collider, etc.)
- Which object is the MainCamera
- Active/inactive status

You can use this to verify GladeKit sees your scene correctly.

---

### Test 1c: Project context

**Prompt:**

```
Read the `unity://context` resource.
```

**Expected result:**
A detailed snapshot of your project including:

- **Render Pipeline**: what you're using (URP, HDRP, Built-in)
- **Input System**: is the new Input System installed? (or legacy Input)
- **Scene Hierarchy**: same as Test 1b
- **Scripts**: list of C# scripts in Assets/
- **Selection**: what's currently selected in the Inspector

This is the full context that GladeKit uses to understand your project.

---

### Test 1d: GLADE.md (optional)

If you created a `GLADE.md` file in your project root:

**Prompt:**

```
Read the `unity://glade-md` resource.
```

**Expected result:**
The exact contents of your GLADE.md file. If the file doesn't exist, you'll get a friendly message suggesting you create one.

---

### Test 1e: Scripts in project

**Prompt:**

```
Read the `unity://project/scripts` resource.
```

**Expected result:**
A list of all C# scripts in your project, showing their name and path (e.g., `Assets/Scripts/PlayerMover.cs`).

---

## Test 2: Meta-Tools (Tool Discovery & Memory)

These tests verify that GladeKit can discover specialized tools and remember facts.

### Test 2a: Discover tools for a task

**Prompt:**

```
Call `get_relevant_tools` with message='set up a blend tree with IK pass-through'. What tools does it suggest?
```

**Expected result:**
A list of relevant tools, which may include:

- Animation tools (Animator, blend trees, states)
- IK tools (if you're using animation-IK)
- Extended tools not in the default ~80-tool list

This is useful when you want to do something specialized and need to know which tools to ask for.

---

### Test 2b: Store and recall a fact

**Prompt:**

```
Call `remember_for_session` with fact='Player uses CharacterController, not Rigidbody for movement'.
```

Then in a follow-up message:

**Prompt:**

```
Call `recall_session_memories` to show what facts you've stored.
```

**Expected result:**
The fact you stored is echoed back. GladeKit uses this to remember context across multiple messages in the same conversation—useful for reminding it about your project conventions mid-session.

---

### Test 2c: Batch-execute multiple tools

**Prompt:**

```
Call `batch_execute` to do three things in one request:
1. Create a cube named 'TestCube'
2. Rename it to 'Player'
3. Move it to position (0, 1, 0)
```

**Expected result:**
A single response with three sub-results, all executed in one round-trip to Unity. This is faster than asking for each tool separately.

---

## Test 3: Golden Path (Creating Objects)

These tests verify the core workflow: describing what you want in natural language and having it appear in Unity.

### Setup

Create an empty scene in Unity (File > New Scene > 3D). Make sure it's the active scene.

### Test 3a: Create and position primitives

**Prompt:**

```
Create a red cube at origin, a blue sphere 2 units to the right at (2, 0, 0), and a green capsule above the cube at (0, 2, 0).
```

**Check in Unity:**

- Scene now has three GameObjects with those names/colors/positions.
- Materials are assigned (not just white defaults).
- Transforms match the requested positions.

---

### Test 3b: Script creation & attachment

**Prompt:**

```
Create a C# script called PlayerMover in Assets/Scripts/ that moves the GameObject forward on W/A/S/D input. Then attach it to the cube.
```

**Check in Unity:**

- Script file exists at `Assets/Scripts/PlayerMover.cs`.
- Script compiles (no errors in console).
- The cube has the PlayerMover component in its Inspector.
- Code looks reasonable (uses Input.GetKey for WASD, transforms position).

---

### Test 3c: Physics setup

**Prompt:**

```
Add a Rigidbody to the cube with mass 2, drag 0.1, and freeze the rotation on the Y axis. Also add a BoxCollider.
```

**Check in Unity:**

- Cube's Inspector shows a Rigidbody component with mass=2, drag=0.1.
- Rigidbody shows frozen rotation: Y=true, X=false, Z=false.
- Cube also has a BoxCollider component.

---

### Test 3d: Lighting

**Prompt:**

```
Add a directional light pointing down and to the right (rotation ~45, -30, 0) with warm color (1, 0.9, 0.8) and intensity 1.2.
```

**Check in Unity:**

- Scene now has a Directional Light with approximately those settings.
- The scene looks warmer/different now that the light is there.

---

### Test 3e: UI

**Prompt:**

```
Create a Canvas with EventSystem, add a Panel in the center (dark gray), and add a centered Button labeled 'Start Game' on top.
```

**Check in Unity:**

- Scene has a Canvas with a RectTransform.
- Canvas has an EventSystem child.
- Canvas has a Panel child (dark gray Image component).
- Panel has a Button child with text "Start Game".
- Play the scene briefly—the button should be clickable.

---

### Test 3f: Prefab workflow

**Prompt:**

```
Turn the cube into a prefab at Assets/Prefabs/PlayerCube.prefab, then instantiate 3 copies in a row at (0, 0, 0), (3, 0, 0), and (6, 0, 0).
```

**Check in Unity:**

- Assets/Prefabs/ folder exists.
- PlayerCube.prefab is inside it.
- Original cube and 3 instances all exist in the hierarchy.
- All 4 are linked to the prefab (white names in hierarchy).

---

### Test 3g: Animator setup

**Prompt:**

```
Create an Animator Controller at Assets/Anim/Player.controller with two states: Idle and Run. Add a Bool parameter 'isRunning' that transitions from Idle→Run (true) and Run→Idle (false).
```

**Check in Unity:**

- Assets/Anim/ folder exists.
- Player.controller is inside it.
- Opening the controller in the Animator window shows two states and the transition logic.

---

## Test 4: Error Handling & Edge Cases

### Test 4a: Bad input gracefully fails

**Prompt:**

```
Create a GameObject named 'Test' with invalid component 'FakeComponent'.
```

**Expected result:**
A clear error message saying the component doesn't exist, rather than a crash or unclear error.

---

### Test 4b: Console errors surfaced

**Prompt:**

```
Create a C# script with a syntax error (missing semicolon).
```

Then ask:

**Prompt:**

```
What compilation errors did that script have?
```

**Expected result:**
The error is caught and reported clearly (syntax error, line number, etc.), and GladeKit suggests how to fix it.

---

### Test 4c: Bridge disconnect handling

**In Unity:** Stop playing (if in play mode), then force-quit or close Unity.

**Prompt (in your AI client):**

```
Try to create a cube.
```

**Expected result:**
A clear error message: "Unity bridge is unreachable" or similar, with a suggestion to open Unity.

---

## Test 5: Skill Calibration (Expertise Detection)

GladeKit adjusts response style based on whether you seem like a beginner or expert.

### Test 5a: Beginner mode

**New conversation.** Use informal, questioning language:

**Prompt:**

```
Um, how do I make the cube bounce? Like, when it hits the ground it bounces back?
```

**Expected result:**
Response is plain-language and encouraging. Explanation is step-by-step. Code examples are simple.

Check: `{ProjectRoot}/.gladekit/skill_level.json` updates to track your vocabulary.

---

### Test 5b: Expert mode

**New conversation.** Use precise, technical language:

**Prompt:**

```
Add a PhysicMaterial with bounciness 0.8 and bounceCombine=Maximum to the cube's collider.
```

**Expected result:**
Response is terse, technical. No hand-holding. Quick execution.

---

## Test 6: GLADE.md Injection

If you created a GLADE.md file:

**Prompt:**

```
What game are we building? What naming conventions should I follow?
```

**Expected result:**
GladeKit cites your GLADE.md and answers based on what you wrote there.

---

**Prompt (after adding "Naming: snake_case for scripts" to GLADE.md):**

```
Create a player movement script.
```

**Expected result:**
Script is named something like `player_movement.cs` (following your convention), not `PlayerMovement.cs`.

---

## Test 7: Optional — HTTP Transport

If you want to test the HTTP transport (instead of stdio):

**Terminal:**

```bash
gladekit-mcp --transport http --port 8766
```

**Check health:**

```bash
curl http://127.0.0.1:8766/health
```

**Expected result:**

```json
{"status": "ok", "unityVersion": "...", ...}
```

**Security check:**

```bash
curl -H "Host: evil.com" http://127.0.0.1:8766/health
```

**Expected result:**
HTTP 421 Misdirected Request (DNS rebinding protection).

---

## Troubleshooting

**"Bridge not connecting"**

- Check **Window > GladeKit MCP** in Unity—the Bridge indicator should be green.
- On Windows, verify nothing else is using port 8765: `netstat -ano | findstr 8765`
- Check that Assets/ imported successfully (no red errors in console).

**"AI client can't find tools"**

- Verify the MCP server launched: check your AI client's logs for "gladekit-mcp" messages.
- Run `uvx gladekit-mcp` in a terminal (should print version on stderr).
- If `uvx` not found, either install [uv](https://docs.astral.sh/uv/) or use `pip install gladekit-mcp` and change the command to `"python"` with args `["-m", "gladekit_mcp"]`.

**"Tool execution seems slow"**

- Check **Window > GladeKit MCP** > Bridge tab—is anything compiling?
- C# scripts trigger a recompile on creation; wait for it to finish before the next tool call.

**"GLADE.md not being read"**

- File must be named exactly `GLADE.md` (case-sensitive on Mac/Linux).
- Must be in the Unity project root (same directory as `Assets/`, `Packages/`).
- Verify: read `unity://glade-md` resource—it should show your file contents.

---

## What to Watch For

- **Real-time feedback**: Tool execution should feel snappy (<1s for simple ops like creating objects).
- **Visible mutations**: Every change should appear in Unity without needing to refresh.
- **Structured errors**: Bad input or failures should come back as clear error messages, not MCP crashes.
- **Parity**: The same prompt should give the same result in Cursor vs Claude Code vs other clients.

---

## Next Steps

Once all tests pass:

- **Try your own project**: Install the bridge in your actual game project, create a GLADE.md, and start using GladeKit for real tasks.
- **Experiment with tasks**: Start with simple object creation, then move to script writing, material assignment, animator setup.
- **Provide feedback**: If anything feels wrong or slow, or if a tool doesn't exist for something you need, let us know!

Happy building! 🚀
