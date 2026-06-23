using System;
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
    /// Drops the VISUAL half of "juice" into the scene in ONE call: a HitVFX system that
    /// pops a particle burst where a hit lands and where something dies — the spark that
    /// makes a hit read as CONNECTING. It builds its own ParticleSystem at runtime (no art,
    /// no prefab) and auto-wires combat: it watches every Health and bursts on damage
    /// (small) and on death (big). It also composes with create_screen_shake — if a
    /// CameraShake exists it nudges it on each burst (via reflection, no hard dependency).
    ///
    /// Why a template tool: a runtime particle burst with no imported material reliably
    /// renders pink/invisible (the default ParticleSystem material isn't pipeline-safe).
    /// The vetted HitVFX builds a Sprites/Default material with a generated soft-dot
    /// texture, which renders in both URP and the built-in pipeline, and reuses one pooled
    /// system instead of leaking a GameObject per hit.
    ///
    /// Reach it from anywhere via the static API: <c>HitVFX.Burst(transform.position)</c>
    /// (or <c>HitVFX.Burst(point, 2f)</c> for a bigger pop). Combat bursts fire on their own.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the vetted script
    /// (and ensures Health.cs, the type its combat hook reads), creates the HitVFX object
    /// now, and QUEUES the HitVFX component to attach on the next compile. Call once per
    /// scene; your only remaining step is compile_scripts.
    /// </summary>
    public class CreateHitVfxTool : ITool
    {
        public string Name => "create_hit_vfx";

        private const string ComponentType = "HitVFX";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string systemName = ToolUtils.GetStringArg(args, "name", "HitVFX");
            if (string.IsNullOrEmpty(systemName)) systemName = "HitVFX";
            string colorHex = ToolUtils.GetStringArg(args, "colorHex", "#FFD27F");
            if (string.IsNullOrEmpty(colorHex)) colorHex = "#FFD27F";
            bool autoHookCombat = ToolUtils.GetBoolArg(args, "autoHookCombat", true);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND system — two would double every burst. The runtime singleton
            // is a backstop; catching it here keeps the scene clean and signals reuse.
            GameObject existing = FindExistingSystem(systemName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "system", existing.name },
                    { "reason", "hitVfxAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A HitVFX already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via the static HitVFX.Burst(position). " +
                    "Delete the existing one first if you want a fresh one.",
                    dupExtras);
            }

            var notes = new List<string>();

            // The combat auto-hook reads Health — ensure that type compiles.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component its hit/death bursts watch");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "HitVFX.cs.txt", "HitVFX.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            var system = new GameObject(systemName);
            Undo.RegisterCreatedObjectUndo(system, "Create HitVFX");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    systemName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("colorHex", "string", colorHex),
                        new PendingControllerWiring.FieldValue("autoHookCombat", "bool", autoHookCombat ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(system.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "systemObject", systemName },
                { "colorHex", colorHex },
                { "autoHookCombat", autoHookCombat },
                { "queuedComponents", new List<string> { $"HitVFX → {systemName}" } },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "burst", "HitVFX.Burst(transform.position)" },
                        { "big_burst", "HitVFX.Burst(point, 2f)" },
                    }
                },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a HitVFX system — the visual half of juice. This tool is ATOMIC: it wrote a VETTED script, " +
                $"created the '{systemName}' object, and QUEUED the HitVFX component to attach as soon as scripts " +
                "compile (the ParticleSystem + its pipeline-safe material are built at runtime — no art needed). DO " +
                "NOT call add_component. Combat bursts are automatic: a small spark when any Health takes damage, a big " +
                "one on death. It composes with create_screen_shake (nudges CameraShake on each burst if present). " +
                "Trigger a manual burst from gameplay code with HitVFX.Burst(transform.position). Your ONLY remaining " +
                "step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        // An existing system: a loaded HitVFX component (after the first compile), or —
        // before the type is loaded — a GameObject by the system name.
        private static GameObject FindExistingSystem(string systemName)
        {
            Type type = ToolUtils.FindComponentType(ComponentType);
            if (type != null)
            {
                var found = UnityEngine.Object.FindFirstObjectByType(type) as Component;
                if (found != null) return found.gameObject;
            }
            return GameObject.Find(systemName);
        }
    }
}
