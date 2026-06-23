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
    /// Adds a HEALTH component (hit points) to an existing object in ONE call —
    /// the foundation of the combat loop. Other systems damage it via
    /// Health.TakeDamage; at 0 HP it dies (and, by default, the object is
    /// destroyed). create_projectile damages Health; create_health_bar visualizes it.
    ///
    /// ATOMIC but DEFERRED: it writes the vetted Health.cs and QUEUES the Health
    /// component (with maxHealth / destroyOnDeath) to attach on the next compile, so
    /// the only remaining step is compile_scripts. For a PLAYER pass
    /// destroyOnDeath=false — the GameManager already owns player death via lives.
    /// </summary>
    public class CreateHealthTool : ITool
    {
        public string Name => "create_health";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string target = ToolUtils.GetStringArg(args, "target", "Player");
            if (string.IsNullOrEmpty(target)) target = "Player";
            int maxHealth = Mathf.Max(1, ToolUtils.GetIntArg(args, "maxHealth", 3));
            bool destroyOnDeath = ToolUtils.GetBoolArg(args, "destroyOnDeath", true);

            var notes = new List<string>();
            string err = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component");
            if (!string.IsNullOrEmpty(err)) return ToolUtils.CreateErrorResponse(err);

            GameObject go = ResolveTarget(target);
            if (go == null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Target '{target}' not found in the scene. Create the object first (e.g. the Player via " +
                    "create_third_person_controller, or an enemy via create_enemy), or pass an existing object's name.");
            }

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    go.name, null, "Health",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("maxHealth", "int", maxHealth.ToString()),
                        new PendingControllerWiring.FieldValue("destroyOnDeath", "bool", destroyOnDeath ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(go.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { $"{dir}/Health.cs" } },
                { "requiresCompilation", true },
                { "target", go.name },
                { "maxHealth", maxHealth },
                { "destroyOnDeath", destroyOnDeath },
                { "queuedComponents", new List<string> { $"Health → {go.name}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added Health ({maxHealth} HP) to '{go.name}'. This tool is ATOMIC: it wrote the VETTED Health.cs and " +
                "QUEUED the Health component to attach on the next compile. DO NOT call add_component. Damage it with " +
                "Health.TakeDamage (create_projectile already does); show it with create_health_bar. " +
                (destroyOnDeath
                    ? "It destroys the object at 0 HP (right for enemies/destructibles)."
                    : "destroyOnDeath is OFF — right for a player, whose death the GameManager handles via lives.") +
                " Your only remaining step is to call compile_scripts and wait until status='idle'.",
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
