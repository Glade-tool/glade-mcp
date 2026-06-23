using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Adds a COLLECTIBLE (coin / star / pickup) to the scene in ONE call: a
    /// visible sphere with a trigger collider that, when the player touches it,
    /// adds to the score via the GameManager and removes itself. With
    /// create_game_manager and create_hazard it completes the core gameplay loop —
    /// a reason to move through the level and a way to win.
    ///
    /// Why a template tool: the pickup is easy to get subtly wrong — forgetting to
    /// make the collider a trigger, reacting to non-player bodies, or double-scoring
    /// before destroy. The vetted Collectible.cs handles all three. It also calls
    /// GameManager.Instance, so this tool ensures GameManager.cs exists in the
    /// project (the compile contract) — call create_game_manager too for the score
    /// to actually count and a win to fire.
    ///
    /// ATOMIC but DEFERRED, like the other gameplay scaffolders: it writes the
    /// scripts and builds the sphere now, then QUEUES the Collectible component
    /// (with its `value`) to attach on the next compile. Call this repeatedly for
    /// many pickups — the script is shared and each object gets a unique name.
    /// </summary>
    public class CreateCollectibleTool : ITool
    {
        public string Name => "create_collectible";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string baseName = ToolUtils.GetStringArg(args, "name", "Collectible");
            if (string.IsNullOrEmpty(baseName)) baseName = "Collectible";
            int value = Mathf.Max(0, ToolUtils.GetIntArg(args, "value", 1));
            float x = ToolUtils.GetFloatArg(args, "x", 0f);
            float y = ToolUtils.GetFloatArg(args, "y", 1f);
            float z = ToolUtils.GetFloatArg(args, "z", 0f);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            var notes = new List<string>();

            // The Collectible template references GameManager.Instance — guarantee
            // the contract script compiles (exactly one GameManager.cs in the project).
            string gmErr = GameplayScaffold.EnsureGameManagerScript(dir, notes);
            if (!string.IsNullOrEmpty(gmErr)) return ToolUtils.CreateErrorResponse(gmErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "Collectible.cs.txt", "Collectible.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // Build a visible sphere with a trigger collider (placeholder art).
            string objName = GameplayScaffold.UniqueName(baseName);
            var go = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            go.name = objName;
            go.transform.position = new Vector3(x, y, z);
            go.transform.localScale = Vector3.one * 0.5f;
            var col = go.GetComponent<Collider>();
            if (col != null) col.isTrigger = true;
            Undo.RegisterCreatedObjectUndo(go, "Create Collectible");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    objName, null, "Collectible",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("value", "int", value.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(go.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "collectibleObject", objName },
                { "value", value },
                { "queuedComponents", new List<string> { $"Collectible → {objName}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added a collectible worth {value} ('{objName}'). This tool is ATOMIC: it wrote a VETTED trigger " +
                "pickup script, built a sphere with a trigger collider, and QUEUED the Collectible component to " +
                "attach as soon as scripts compile. It calls GameManager.Instance.AddScore on player touch and " +
                "frees itself — so call create_game_manager too (or the pickup vanishes without scoring). Place more " +
                "by calling this again (the script is reused; each gets a unique name). Replace the sphere with real " +
                "art when you like. Your remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }
    }
}
