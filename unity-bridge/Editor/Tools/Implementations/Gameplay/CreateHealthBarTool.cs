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
    /// Adds a floating HEALTH BAR above an object that has Health, in ONE call: a
    /// camera-facing bar (green → red) that tracks the target's Current/Max each
    /// frame and disappears when the target dies. Pairs with create_enemy /
    /// create_health — it visualizes their Health.
    ///
    /// Why a template tool: a hand-rolled bar usually gets the fiddly parts wrong —
    /// scaling the fill from the centre instead of the left, not billboarding, or
    /// leaving a render-pipeline-specific material that shows up magenta. The vetted
    /// HealthBar.cs uses pivot-left SpriteRenderers (no Canvas, no custom material)
    /// so it just works.
    ///
    /// ATOMIC but DEFERRED: it creates a child bar object under the target now and
    /// QUEUES the HealthBar component to attach on the next compile. The target must
    /// already have (or be queued to get) a Health component — add one with
    /// create_health, or use create_enemy (enemies carry Health).
    /// </summary>
    public class CreateHealthBarTool : ITool
    {
        public string Name => "create_health_bar";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string targetName = ToolUtils.GetStringArg(args, "target", "Enemy");
            if (string.IsNullOrEmpty(targetName)) targetName = "Enemy";
            float offsetY = ToolUtils.GetFloatArg(args, "offsetY", 2.2f);
            float width = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "width", 1.2f));
            float height = Mathf.Max(0.02f, ToolUtils.GetFloatArg(args, "height", 0.18f));
            bool hideWhenFull = ToolUtils.GetBoolArg(args, "hideWhenFull", false);

            var notes = new List<string>();

            // HealthBar reads the Health type — ensure that contract compiles.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component the bar reads");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "HealthBar.cs.txt", "HealthBar.cs", dir, ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false),
                out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            GameObject targetGo = ResolveTarget(targetName);
            if (targetGo == null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Target '{targetName}' not found. Create it first (e.g. create_enemy) and give it Health, " +
                    "then add the bar. Pass the name of an existing Health-bearing object.");
            }

            // The bar is a CHILD object so it can billboard without rotating the
            // target. It finds the target's Health via GetComponentInParent.
            string barName = GameplayScaffold.UniqueName($"{targetGo.name} HealthBar");
            var bar = new GameObject(barName);
            bar.transform.SetParent(targetGo.transform, false);
            Undo.RegisterCreatedObjectUndo(bar, "Create Health Bar");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    barName, null, "HealthBar",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("offsetY", "float", offsetY.ToString()),
                        new PendingControllerWiring.FieldValue("width", "float", width.ToString()),
                        new PendingControllerWiring.FieldValue("height", "float", height.ToString()),
                        new PendingControllerWiring.FieldValue("hideWhenFull", "bool", hideWhenFull ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(bar.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "target", targetGo.name },
                { "barObject", barName },
                { "queuedComponents", new List<string> { $"HealthBar → {barName}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added a floating health bar above '{targetGo.name}'. This tool is ATOMIC: it wrote the VETTED " +
                "HealthBar.cs, created a child bar object, and QUEUED the HealthBar component to attach on the next " +
                "compile. DO NOT call add_component. The bar reads the target's Health (give it one via create_health, " +
                "or use create_enemy), tracks Current/Max, faces the camera, and vanishes when the target dies. " +
                "Your only remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        private static GameObject ResolveTarget(string target)
        {
            try
            {
                var byTag = GameObject.FindWithTag(target);
                if (byTag != null) return byTag;
            }
            catch { /* not a defined tag */ }
            return GameObject.Find(target);
        }
    }
}
