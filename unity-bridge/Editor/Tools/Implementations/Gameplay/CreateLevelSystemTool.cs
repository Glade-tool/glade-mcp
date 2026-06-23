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
    /// Drops the PROGRESSION hub into the scene in ONE call: a LevelSystem that tracks
    /// XP and LEVEL, levels the player up when XP fills, grows the player's max health
    /// (and heals to full) on each level up, and builds its own on-screen HUD (a level
    /// readout + an XP bar). The counterpart to create_game_manager's score/lives — the
    /// part that makes the game worth continuing to play.
    ///
    /// Why a template tool: an XP curve + level-up + HUD is easy to get subtly wrong
    /// (XP that doesn't roll over on a big reward, a bar that divides by zero at the
    /// cap, growth that fights whichever object initializes first). The vetted
    /// LevelSystem.cs avoids those and exposes a static <c>LevelSystem.Instance</c> so
    /// gameplay code reaches it without a hard reference: <c>LevelSystem.Instance?.AddXP(5)</c>.
    /// Pair it with create_loot_drop so enemies feed it.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the vetted script
    /// (and ensures Health.cs, the stat it grows), creates the LevelSystem object now,
    /// and QUEUES the LevelSystem component to attach on the next compile. The HUD is
    /// built at runtime by the script. Call once per scene; your only remaining step is
    /// compile_scripts.
    /// </summary>
    public class CreateLevelSystemTool : ITool
    {
        public string Name => "create_level_system";

        private const string ComponentType = "LevelSystem";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string systemName = ToolUtils.GetStringArg(args, "name", "LevelSystem");
            if (string.IsNullOrEmpty(systemName)) systemName = "LevelSystem";
            int baseXP = Mathf.Max(1, ToolUtils.GetIntArg(args, "baseXP", 5));
            int xpGrowth = Mathf.Max(0, ToolUtils.GetIntArg(args, "xpGrowth", 3));
            int healthPerLevel = Mathf.Max(0, ToolUtils.GetIntArg(args, "healthPerLevel", 1));
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND system — two HUDs / two XP counters would fight. The
            // runtime singleton is a backstop; catching it here keeps the scene clean
            // and signals the model to reuse the existing one via LevelSystem.Instance.
            GameObject existing = FindExistingSystem(systemName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "system", existing.name },
                    { "reason", "levelSystemAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A LevelSystem already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via LevelSystem.Instance (e.g. " +
                    "LevelSystem.Instance?.AddXP(5)). Delete the existing one first if you want a fresh one.",
                    dupExtras);
            }

            var notes = new List<string>();

            // LevelSystem grows the player's Health.maxHealth — ensure that type compiles.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component leveling grows");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "LevelSystem.cs.txt", "LevelSystem.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // The HUD is built at runtime by the script's Awake, so nothing UI-related
            // is needed here.
            var system = new GameObject(systemName);
            Undo.RegisterCreatedObjectUndo(system, "Create LevelSystem");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    systemName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("baseXP", "int", baseXP.ToString()),
                        new PendingControllerWiring.FieldValue("xpGrowth", "int", xpGrowth.ToString()),
                        new PendingControllerWiring.FieldValue("healthPerLevel", "int", healthPerLevel.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(system.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "systemObject", systemName },
                { "baseXP", baseXP },
                { "xpGrowth", xpGrowth },
                { "healthPerLevel", healthPerLevel },
                { "queuedComponents", new List<string> { $"LevelSystem → {systemName}" } },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "add_xp", "LevelSystem.Instance?.AddXP(5)" },
                    }
                },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a LevelSystem — the progression hub. This tool is ATOMIC: it wrote a VETTED script, created " +
                $"the '{systemName}' object, and QUEUED the LevelSystem component to attach as soon as scripts compile " +
                "(the HUD — a level readout + XP bar — is built at runtime). DO NOT call add_component. On level up the " +
                $"player's max health grows by {healthPerLevel} and heals to full, and OnLevelUp(level) is broadcast to " +
                "the player for custom growth. Feed it XP via the static LevelSystem.Instance (LevelSystem.Instance?." +
                "AddXP(5)) — or call create_loot_drop on your enemies so kills grant XP automatically. Your ONLY " +
                "remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        // An existing system: a loaded LevelSystem component (after the first compile),
        // or — before the type is loaded — a GameObject by the system name.
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
