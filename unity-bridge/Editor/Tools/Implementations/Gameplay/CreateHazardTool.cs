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
    /// Adds a HAZARD (spikes / lava / a pit trigger) to the scene in ONE call: a
    /// visible cube with a trigger collider that, when the player touches it, costs
    /// the player lives via the GameManager — which respawns the player while lives
    /// remain and ends the game at zero. With create_game_manager and
    /// create_collectible it completes the core gameplay loop — the way to LOSE.
    ///
    /// Why a template tool: the danger volume is easy to get subtly wrong —
    /// forgetting the trigger flag, reacting to non-player bodies, or hitting every
    /// physics frame the player overlaps it. The vetted Hazard.cs fires once on
    /// entry and only for the player. It calls GameManager.Instance, so this tool
    /// ensures GameManager.cs exists (the compile contract); call create_game_manager
    /// too for lives/respawn to actually happen.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the scripts
    /// and builds the cube now, QUEUES the Hazard component (with its `damage`) to
    /// attach on the next compile. Call repeatedly for many hazards.
    /// </summary>
    public class CreateHazardTool : ITool
    {
        public string Name => "create_hazard";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string baseName = ToolUtils.GetStringArg(args, "name", "Hazard");
            if (string.IsNullOrEmpty(baseName)) baseName = "Hazard";
            int damage = Mathf.Max(1, ToolUtils.GetIntArg(args, "damage", 1));
            float x = ToolUtils.GetFloatArg(args, "x", 0f);
            float y = ToolUtils.GetFloatArg(args, "y", 0.5f);
            float z = ToolUtils.GetFloatArg(args, "z", 0f);
            float size = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "size", 1f));
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            var notes = new List<string>();

            string gmErr = GameplayScaffold.EnsureGameManagerScript(dir, notes);
            if (!string.IsNullOrEmpty(gmErr)) return ToolUtils.CreateErrorResponse(gmErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "Hazard.cs.txt", "Hazard.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // Build a visible cube with a trigger collider (placeholder art).
            string objName = GameplayScaffold.UniqueName(baseName);
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
            go.name = objName;
            go.transform.position = new Vector3(x, y, z);
            go.transform.localScale = Vector3.one * size;
            var col = go.GetComponent<Collider>();
            if (col != null) col.isTrigger = true;
            Undo.RegisterCreatedObjectUndo(go, "Create Hazard");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    objName, null, "Hazard",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("damage", "int", damage.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(go.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "hazardObject", objName },
                { "damage", damage },
                { "queuedComponents", new List<string> { $"Hazard → {objName}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added a hazard costing {damage} life/lives ('{objName}'). This tool is ATOMIC: it wrote a VETTED " +
                "trigger danger script, built a cube with a trigger collider, and QUEUED the Hazard component to " +
                "attach as soon as scripts compile. On player touch it calls GameManager.Instance.LoseLife — which " +
                "respawns the player while lives remain and ends the game at zero — so call create_game_manager too " +
                "(without it nothing happens on contact). Place more by calling this again (the script is reused; " +
                "each gets a unique name). Your remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }
    }
}
