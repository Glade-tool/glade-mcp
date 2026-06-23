using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Drops the HUB of a simple game into the scene in ONE call: a GameManager
    /// that tracks SCORE and LIVES, handles RESPAWN and WIN/LOSE, and builds its
    /// own on-screen HUD (score + lives readouts and a centered win/lose banner).
    /// It is the piece that turns a playable character into an actual game —
    /// something you can win or lose — and it is the counterpart the
    /// create_collectible and create_hazard tools wire into.
    ///
    /// Why a template tool: the game-state hub is small but easy to get subtly
    /// wrong — scoring that keeps counting after the game ends, respawn that
    /// forgets to clear the player's velocity, a HUD that breaks depending on
    /// which object initializes first. The vetted GameManager.cs.txt avoids all of
    /// those, and exposes a static <c>GameManager.Instance</c> (the Unity
    /// counterpart of a Godot group) so gameplay code reaches it without a hard
    /// reference: <c>GameManager.Instance?.AddScore(1)</c>.
    ///
    /// Like <see cref="Scripts.CreateThirdPersonControllerScriptTool"/> this tool
    /// is ATOMIC but the component attach is DEFERRED: a MonoBehaviour can't be
    /// AddComponent'd until its script compiles and a domain reload loads the
    /// assembly. So it writes the vetted script, creates the empty GameManager
    /// object now, and QUEUES the GameManager component (with the caller's lives /
    /// score-to-win baked into the queued request) to attach on the next compile.
    /// The caller's only remaining step is compile_scripts.
    /// </summary>
    public class CreateGameManagerTool : ITool
    {
        public string Name => "create_game_manager";

        private const string TemplateFile = "GameManager.cs.txt";
        private const string ScriptFileName = "GameManager.cs";
        private const string ComponentType = "GameManager";

        public string Execute(Dictionary<string, object> args)
        {
            string directory = ToolUtils.GetStringArg(args, "directory", "Assets/Scripts");
            if (string.IsNullOrEmpty(directory)) directory = "Assets/Scripts";
            directory = directory.Replace('\\', '/').TrimEnd('/');
            if (!directory.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase)
                && !directory.Equals("Assets", StringComparison.OrdinalIgnoreCase))
            {
                directory = "Assets/" + directory;
            }

            string managerName = ToolUtils.GetStringArg(args, "managerName", "GameManager");
            if (string.IsNullOrEmpty(managerName)) managerName = "GameManager";
            int startingLives = Math.Max(0, ToolUtils.GetIntArg(args, "startingLives", 3));
            int scoreToWin = Math.Max(0, ToolUtils.GetIntArg(args, "scoreToWin", 0));
            bool confirmExistingFileModification =
                ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND manager — two HUDs / two score counters would fight.
            // The runtime singleton in the template is a backstop, but catching it
            // here keeps the scene clean and gives the model a clear signal to
            // reuse the existing manager via GameManager.Instance.
            GameObject existing = FindExistingManager(managerName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "manager", existing.name },
                    { "reason", "managerAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A GameManager already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via GameManager.Instance (e.g. " +
                    "GameManager.Instance?.AddScore(1)). Delete the existing manager first if you want a fresh one.",
                    dupExtras);
            }

            string templatePath = ToolUtils.ResolveTemplatePath(TemplateFile);
            if (string.IsNullOrEmpty(templatePath))
            {
                return ToolUtils.CreateErrorResponse(
                    $"Template '{TemplateFile}' could not be found in any known bridge location. " +
                    "The bridge install may be incomplete — reinstall com.gladekit.mcp-bridge.");
            }

            string scriptPath = $"{directory}/{ScriptFileName}";

            // The manager script is a shared, vetted template — not user code. When
            // it already exists (the project built a game before), REUSE it instead
            // of refusing: the duplicate-manager guard above already prevents two
            // managers, so a fresh scene should still get one wired to the existing
            // script. Only (re)write the file when absent or explicitly confirmed,
            // so a user's manual edits survive. Mirrors create_third_person_controller.
            bool scriptExists = File.Exists(scriptPath);
            if (scriptExists && !confirmExistingFileModification
                && !SessionTracker.WasScriptCreatedThisSession(scriptPath))
            {
                // It exists and we didn't create it this session: reuse it as-is
                // (don't clobber), and still build + wire the manager object.
            }
            else if (!scriptExists || confirmExistingFileModification)
            {
                if (!Directory.Exists(directory)) Directory.CreateDirectory(directory);
                File.WriteAllText(scriptPath, File.ReadAllText(templatePath));
                SessionTracker.MarkScriptCreated(scriptPath);
                scriptExists = true;
            }

            // ── Build the manager object (the HUD is built at runtime by the
            //    script's Awake, so nothing UI-related is needed here) ──
            var manager = new GameObject(managerName);
            Undo.RegisterCreatedObjectUndo(manager, "Create GameManager");

            // Queue the GameManager component with the caller's config. It attaches
            // automatically once GameManager.cs compiles (deferred — the type isn't
            // loaded yet), and ApplyFields sets startingLives / scoreToWin then.
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    managerName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("startingLives", "int", startingLives.ToString()),
                        new PendingControllerWiring.FieldValue("scoreToWin", "int", scoreToWin.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(manager.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            string winNote = scoreToWin > 0
                ? $"auto-win at score {scoreToWin}"
                : "win by collecting all collectibles (or call GameManager.Instance.Win() from a goal)";

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "managerObject", managerName },
                { "startingLives", startingLives },
                { "scoreToWin", scoreToWin },
                { "queuedComponents", new List<string> { $"GameManager → {managerName}" } },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "add_score", "GameManager.Instance?.AddScore(1)" },
                        { "lose_life", "GameManager.Instance?.LoseLife()" },
                        { "win", "GameManager.Instance?.Win()" },
                    }
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a GameManager — the hub that makes this a winnable/losable game. This tool is ATOMIC: it " +
                $"wrote a VETTED, known-good script VERBATIM, created the '{managerName}' object, and QUEUED the " +
                "GameManager component to attach automatically as soon as the script compiles (the HUD — score + " +
                "lives readouts and a centered win/lose banner — is built at runtime by the script, so no UI wiring " +
                $"is needed). DO NOT call add_component for GameManager. Lives={startingLives}, {winNote}. Gameplay " +
                "code reaches it via the static GameManager.Instance: AddScore(1) on a pickup, LoseLife() on a hit, " +
                "Win() at a goal. Add pickups with create_collectible and dangers with create_hazard (both already " +
                "call this manager). Your ONLY remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        /// <summary>Returns an existing manager if one is present — a loaded
        /// GameManager component (after the first compile) or, before the type is
        /// loaded, a GameObject by the manager name.</summary>
        private static GameObject FindExistingManager(string managerName)
        {
            Type type = ToolUtils.FindComponentType(ComponentType);
            if (type != null)
            {
                var found = UnityEngine.Object.FindFirstObjectByType(type) as Component;
                if (found != null) return found.gameObject;
            }
            return GameObject.Find(managerName);
        }
    }
}
