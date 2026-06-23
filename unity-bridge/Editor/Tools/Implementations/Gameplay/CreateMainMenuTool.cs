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
    /// Drops a self-contained START / TITLE SCREEN into the scene in ONE call: a StartMenu
    /// that freezes the game (Time.timeScale = 0) on play and shows a full-screen title
    /// with Play and Quit buttons, then un-freezes and tears itself down when the player
    /// presses Play. It builds its own Canvas, buttons and EventSystem at runtime, so no
    /// UI setup — and no second scene or Build Settings change — is needed.
    ///
    /// Why an in-scene overlay (not a separate menu scene): a menu scene needs both scenes
    /// saved AND registered in Build Settings or Play does nothing — brittle to scaffold.
    /// Freezing the live scene behind an overlay gives the same "title → game" flow
    /// immediately, in any scene.
    ///
    /// Why a template tool: hand-written title screens reliably re-derive the same bugs —
    /// a missing EventSystem / input module (Play unclickable), a menu that doesn't freeze
    /// the game (it plays out behind the card), or a dismiss that forgets to restore
    /// timeScale (the game stays frozen after Play). The vetted StartMenu.cs handles all
    /// three.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the vetted script,
    /// creates the StartMenu object now, and QUEUES the StartMenu component to attach on
    /// the next compile. Call once per scene; your only remaining step is compile_scripts.
    /// </summary>
    public class CreateMainMenuTool : ITool
    {
        public string Name => "create_main_menu";

        private const string ComponentType = "StartMenu";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string menuName = ToolUtils.GetStringArg(args, "name", "StartMenu");
            if (string.IsNullOrEmpty(menuName)) menuName = "StartMenu";
            string title = ToolUtils.GetStringArg(args, "title", "My Game");
            if (string.IsNullOrEmpty(title)) title = "My Game";
            string subtitle = ToolUtils.GetStringArg(args, "subtitle", "Press Play to start");
            bool freezeUntilStart = ToolUtils.GetBoolArg(args, "freezeUntilStart", true);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND start menu — two title cards would stack and double-freeze.
            // The runtime singleton is a backstop; catching it here keeps the scene clean.
            GameObject existing = FindExistingMenu(menuName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "menu", existing.name },
                    { "reason", "startMenuAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A start menu already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via StartMenu.Instance (e.g. StartMenu.Instance?.Play()). " +
                    "Delete the existing one first if you want a fresh one.",
                    dupExtras);
            }

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "StartMenu.cs.txt", "StartMenu.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // The title card + EventSystem are built at runtime by the script's Awake, so
            // nothing UI-related is needed here — just the host object.
            var menu = new GameObject(menuName);
            Undo.RegisterCreatedObjectUndo(menu, "Create StartMenu");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    menuName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("title", "string", title),
                        new PendingControllerWiring.FieldValue("subtitle", "string", subtitle ?? ""),
                        new PendingControllerWiring.FieldValue("freezeUntilStart", "bool", freezeUntilStart ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(menu.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "menuObject", menuName },
                { "title", title },
                { "freezeUntilStart", freezeUntilStart },
                { "queuedComponents", new List<string> { $"StartMenu → {menuName}" } },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a start screen titled '{title}'. This tool is ATOMIC: it wrote a VETTED script, created the " +
                $"'{menuName}' object, and QUEUED the StartMenu component to attach as soon as scripts compile (the " +
                "title card, buttons, and EventSystem are built at runtime). DO NOT call add_component, create_canvas, " +
                "or create_event_system. On play the game freezes behind a title card with Play / Quit; pressing Play " +
                "un-freezes and removes the menu. This is an in-scene overlay (no second scene / Build Settings needed). " +
                "Your ONLY remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        // An existing menu: a loaded StartMenu component (after the first compile), or —
        // before the type is loaded — a GameObject by the menu name.
        private static GameObject FindExistingMenu(string menuName)
        {
            Type type = ToolUtils.FindComponentType(ComponentType);
            if (type != null)
            {
                var found = UnityEngine.Object.FindFirstObjectByType(type) as Component;
                if (found != null) return found.gameObject;
            }
            return GameObject.Find(menuName);
        }
    }
}
