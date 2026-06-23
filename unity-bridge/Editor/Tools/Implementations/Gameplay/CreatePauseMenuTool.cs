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
    /// Drops a self-contained PAUSE MENU into the scene in ONE call: a PauseMenu that
    /// freezes the game (Time.timeScale = 0) on a key press (Escape by default) and shows
    /// a dimmed overlay with Resume / Restart / Quit, then un-freezes on resume. It builds
    /// its own Canvas, buttons and EventSystem at runtime, so no UI setup is needed.
    ///
    /// Why a template tool: a hand-written pause menu reliably re-derives the same bugs —
    /// it reads the unpause key on a timeScale-bound clock (so the menu can't be closed),
    /// forgets the EventSystem / input module (so the buttons are dead), or fails to
    /// restore timeScale before a scene reload (so Restart loads a frozen scene). The
    /// vetted PauseMenu.cs polls the key through the new Input System (immune to timeScale),
    /// ensures an EventSystem, and restores the interrupted timeScale on resume.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the vetted script,
    /// creates the PauseMenu object now, and QUEUES the PauseMenu component to attach on
    /// the next compile. Call once per scene; your only remaining step is compile_scripts.
    /// </summary>
    public class CreatePauseMenuTool : ITool
    {
        public string Name => "create_pause_menu";

        private const string ComponentType = "PauseMenu";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string menuName = ToolUtils.GetStringArg(args, "name", "PauseMenu");
            if (string.IsNullOrEmpty(menuName)) menuName = "PauseMenu";
            string pauseKey = ToolUtils.GetStringArg(args, "pauseKey", "Escape");
            if (string.IsNullOrEmpty(pauseKey)) pauseKey = "Escape";
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND pause menu — two overlays would fight over Time.timeScale.
            // The runtime singleton is a backstop; catching it here keeps the scene clean
            // and signals the model to reuse the existing one via PauseMenu.Instance.
            GameObject existing = FindExistingMenu(menuName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "menu", existing.name },
                    { "reason", "pauseMenuAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A PauseMenu already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via PauseMenu.Instance (e.g. " +
                    "PauseMenu.Instance?.SetPausable(false)). Delete the existing one first if you want a fresh one.",
                    dupExtras);
            }

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "PauseMenu.cs.txt", "PauseMenu.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // The overlay + EventSystem are built at runtime by the script's Awake, so
            // nothing UI-related is needed here — just the host object.
            var menu = new GameObject(menuName);
            Undo.RegisterCreatedObjectUndo(menu, "Create PauseMenu");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    menuName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("pauseKey", "string", pauseKey),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(menu.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "menuObject", menuName },
                { "pauseKey", pauseKey },
                { "queuedComponents", new List<string> { $"PauseMenu → {menuName}" } },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "lock_pausing", "PauseMenu.Instance?.SetPausable(false)" },
                    }
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a PauseMenu. This tool is ATOMIC: it wrote a VETTED script, created the '{menuName}' " +
                $"object, and QUEUED the PauseMenu component to attach as soon as scripts compile (the overlay, " +
                "buttons, and EventSystem are built at runtime). DO NOT call add_component, create_canvas, or " +
                $"create_event_system. At runtime, pressing {pauseKey} freezes the game and shows Resume / Restart / " +
                "Quit; pressing it again resumes. Lock pausing from gameplay code via PauseMenu.Instance?." +
                "SetPausable(false). Your ONLY remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        // An existing menu: a loaded PauseMenu component (after the first compile), or —
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
