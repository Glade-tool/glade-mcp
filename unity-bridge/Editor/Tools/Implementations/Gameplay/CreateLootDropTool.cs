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
    /// Makes an object GRANT XP WHEN IT DIES in ONE call — turning an enemy (or any
    /// Health-bearing destructible) into a source of progression, so killing it levels
    /// the player up. Closes the progression loop alongside create_level_system.
    ///
    /// Why a template tool: the reliable way to reward a kill is to hook the object's
    /// Health.onDeath (fires once, right before destroy) — not to poll for the object
    /// being gone or to bake the reward into the killer. The vetted LootDrop.cs does
    /// exactly that and no-ops cleanly when no LevelSystem is present.
    ///
    /// ATOMIC but DEFERRED: writes the vetted script (and ensures Health.cs + the
    /// LevelSystem.cs contract it grants XP to) and QUEUES the LootDrop component onto
    /// the target to attach on the next compile. Call create_level_system too, or the
    /// XP has nowhere to go. Call repeatedly to reward many enemies. Currently 3D.
    /// </summary>
    public class CreateLootDropTool : ITool
    {
        public string Name => "create_loot_drop";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string targetName = ToolUtils.GetStringArg(args, "target", "Enemy");
            if (string.IsNullOrEmpty(targetName)) targetName = "Enemy";
            int xp = Mathf.Max(1, ToolUtils.GetIntArg(args, "xp", 3));
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            var notes = new List<string>();

            // LootDrop hooks Health.onDeath and feeds LevelSystem.Instance — ensure both
            // contract types compile. Creating the contracts does NOT build the hub
            // (no HUD / leveling) — call create_level_system for that.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component whose death the drop hooks");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);
            string lErr = GameplayScaffold.EnsureContractScript(
                "LevelSystem.cs.txt", "LevelSystem.cs", dir, notes,
                "the progression hub this grants XP to — call create_level_system to add the HUD + leveling");
            if (!string.IsNullOrEmpty(lErr)) return ToolUtils.CreateErrorResponse(lErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "LootDrop.cs.txt", "LootDrop.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            GameObject target = ResolveTarget(targetName);
            if (target == null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Target '{targetName}' not found. Create the enemy first (e.g. create_enemy), or pass the name " +
                    "of an existing Health-bearing object to reward.");
            }

            // LootDrop [RequireComponent(typeof(Health))] — note when the target has no
            // Health yet so the model can add one (create_enemy does; a bare prop won't).
            // Health lives in the user's assembly, so resolve it by reflection (the
            // bridge can't reference it directly). Best-effort: skip the note if the
            // type isn't loaded yet (first compile of a fresh project).
            var healthType = ToolUtils.FindComponentType("Health");
            if (healthType != null && target.GetComponent(healthType) == null)
            {
                notes.Add($"'{target.name}' has no Health yet — RequireComponent will add one, but use " +
                          "create_enemy / create_health to give it real hit points.");
            }

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    target.name, null, "LootDrop",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("xp", "int", xp.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(target.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "target", target.name },
                { "xp", xp },
                { "queuedComponents", new List<string> { $"LootDrop → {target.name}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"'{target.name}' will grant {xp} XP when it dies. This tool is ATOMIC: it wrote a VETTED LootDrop " +
                "script and QUEUED the LootDrop component onto the target to attach on the next compile. DO NOT call " +
                "add_component. It hooks the target's Health.onDeath, so the reward fires once, right before the " +
                "object is destroyed. Call create_level_system too (the XP needs a LevelSystem to land in), and call " +
                "this again for each enemy you want to reward. Your remaining step is to call compile_scripts and " +
                "wait until status='idle'.",
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
