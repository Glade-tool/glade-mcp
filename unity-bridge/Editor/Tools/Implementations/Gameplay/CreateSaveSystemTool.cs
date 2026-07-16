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
    /// Adds a full SAVE/LOAD system in ONE call: writes a VETTED SaveSystem
    /// MonoBehaviour verbatim, drops a SaveSystem object into the scene, and queues
    /// the component to attach on the next compile. It is the missing piece that
    /// turns a session-only prototype into a game that REMEMBERS — coins, unlocked
    /// levels, high scores, and settings survive a quit.
    ///
    /// Why a template tool: hand-rolled save systems reliably ship data-loss bugs —
    /// the #1 being saving via PlayerPrefs (a size-limited registry/plist bucket,
    /// the wrong scope for game state) or writing under the project folder (read-only
    /// in a built player). The vetted SaveSystem.cs.txt avoids all of these: it
    /// persists JSON to <c>Application.persistentDataPath</c> (the only writable,
    /// per-user, cross-platform location), tolerates a missing/corrupt file by
    /// starting empty, supports multiple save slots, and auto-saves on quit.
    ///
    /// Unity has no autoload equivalent, so the template also self-bootstraps via a
    /// <c>[RuntimeInitializeOnLoadMethod]</c>: the singleton auto-creates on Play even
    /// when entering from a scene that lacks the object. Reach it from anywhere via
    /// the static Instance (no reference / group lookup):
    ///     SaveSystem.Instance.SetInt("coins", 42);
    ///     int coins = SaveSystem.Instance.GetInt("coins", 0);
    ///     SaveSystem.Instance.Save();
    ///
    /// Like <see cref="CreateGameManagerTool"/> this tool is ATOMIC but the component
    /// attach is DEFERRED: a MonoBehaviour can't be AddComponent'd until its script
    /// compiles and a domain reload loads the assembly. So it writes the vetted
    /// script, creates the SaveSystem object now, and QUEUES the SaveSystem component
    /// to attach on the next compile. The caller's only remaining step is
    /// compile_scripts.
    /// </summary>
    public class CreateSaveSystemTool : ITool
    {
        public string Name => "create_save_system";

        private const string TemplateFile = "SaveSystem.cs.txt";
        private const string ScriptFileName = "SaveSystem.cs";
        private const string ComponentType = "SaveSystem";

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

            string systemName = ToolUtils.GetStringArg(args, "saveSystemName", "SaveSystem");
            if (string.IsNullOrEmpty(systemName)) systemName = "SaveSystem";
            bool autosave = ToolUtils.GetBoolArg(args, "autosave", true);
            int defaultSlot = Math.Max(0, ToolUtils.GetIntArg(args, "defaultSlot", 0));
            bool confirmExistingFileModification =
                ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            string templatePath = ToolUtils.ResolveTemplatePath(TemplateFile);
            if (string.IsNullOrEmpty(templatePath))
            {
                return ToolUtils.CreateErrorResponse(
                    $"Template '{TemplateFile}' could not be found in any known bridge location. " +
                    "The bridge install may be incomplete — reinstall com.gladekit.mcp-bridge.");
            }

            string scriptPath = $"{directory}/{ScriptFileName}";

            // The save script is a shared, vetted template — not user code. When it
            // already exists (the project built a save system before), REUSE it
            // instead of clobbering: only (re)write the file when absent or explicitly
            // confirmed, so a user's manual edits survive. Mirrors create_game_manager.
            // autosave/defaultSlot are BAKED INTO the file (an auto-bootstrapped
            // singleton has no scene component to configure), so they only take effect
            // on a (re)write — surface that when reusing.
            bool scriptExists = File.Exists(scriptPath);
            bool wroteScript = false;
            if (scriptExists && !confirmExistingFileModification
                && !SessionTracker.WasScriptCreatedThisSession(scriptPath))
            {
                // It exists and we didn't create it this session: reuse it as-is.
            }
            else if (!scriptExists || confirmExistingFileModification)
            {
                if (!Directory.Exists(directory)) Directory.CreateDirectory(directory);
                string src = File.ReadAllText(templatePath)
                    .Replace("__AUTOSAVE__", autosave ? "true" : "false")
                    .Replace("__DEFAULT_SLOT__", defaultSlot.ToString());
                File.WriteAllText(scriptPath, src);
                SessionTracker.MarkScriptCreated(scriptPath);
                scriptExists = true;
                wroteScript = true;
            }
            bool reusedExistingScript = scriptExists && !wroteScript;

            // Reuse an existing SaveSystem object rather than spawning a second (two
            // savers would fight over the same file). The runtime singleton in the
            // template is a backstop; catching it here keeps the scene clean.
            GameObject existing = FindExistingSystem(systemName);
            bool reusedExistingObject = existing != null;
            if (!reusedExistingObject)
            {
                var systemObj = new GameObject(systemName);
                Undo.RegisterCreatedObjectUndo(systemObj, "Create SaveSystem");

                // Queue the SaveSystem component. It attaches automatically once
                // SaveSystem.cs compiles (deferred — the type isn't loaded yet). No
                // field values: autosave/defaultSlot are baked into the script's
                // serialized defaults, so a freshly attached component picks them up.
                PendingControllerWiring.Queue(new[]
                {
                    new PendingControllerWiring.WiringRequest(
                        systemName, null, ComponentType, null),
                });

                try { EditorSceneManager.MarkSceneDirty(systemObj.scene); } catch { /* no open scene */ }
            }

            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "saveSystemObject", systemName },
                { "autosave", autosave },
                { "defaultSlot", defaultSlot },
                { "reusedExistingScript", reusedExistingScript },
                { "reusedExistingObject", reusedExistingObject },
                {
                    "queuedComponents",
                    reusedExistingObject
                        ? new List<string>()
                        : new List<string> { $"SaveSystem → {systemName}" }
                },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "set_int", "SaveSystem.Instance.SetInt(\"coins\", 42)" },
                        { "get_int", "int coins = SaveSystem.Instance.GetInt(\"coins\", 0)" },
                        { "save", "SaveSystem.Instance.Save()" },
                        { "has_save", "if (SaveSystem.Instance.HasSave()) { /* gate a Continue button on this */ }" },
                        { "set_slot", "SaveSystem.Instance.SetSlot(1)" },
                    }
                },
            };

            string reuseNote = "";
            if (reusedExistingScript)
            {
                reuseNote = " The SaveSystem.cs script already existed, so it was REUSED and the " +
                            "autosave/defaultSlot args were NOT applied — pass confirmExistingFileModification=true " +
                            "to regenerate it with new values.";
            }
            if (reusedExistingObject)
            {
                reuseNote += $" A SaveSystem object ('{existing.name}') already exists in the scene, so it was " +
                             "REUSED rather than duplicated.";
            }

            return ToolUtils.CreateSuccessResponse(
                $"Added a save/load system — the piece that makes this game REMEMBER between sessions. This tool is " +
                "ATOMIC: it wrote a VETTED, known-good script VERBATIM, created the " +
                $"'{systemName}' object, and QUEUED the SaveSystem component to attach automatically as soon as the " +
                "script compiles (it also self-bootstraps on Play, so it works even in scenes without the object). " +
                "DO NOT call add_component for SaveSystem, and DO NOT hand-write save/load code — the template already " +
                "persists JSON to Application.persistentDataPath (the only writable, per-user, cross-platform " +
                "location — NOT PlayerPrefs), tolerates a missing or corrupt file, supports multiple slots, and " +
                "auto-saves on quit. Reach it globally via the static SaveSystem.Instance: SetInt(\"coins\", 42) to " +
                "remember a value, GetInt(\"coins\", 0) to read it back (with a default when unset), Save() to flush " +
                "to disk, and HasSave() to gate a Continue button (SetFloat/SetString/SetBool exist too). Your ONLY " +
                "remaining step is to call compile_scripts and wait until status='idle'." + reuseNote,
                extras);
        }

        /// <summary>Returns an existing save system if one is present — a loaded
        /// SaveSystem component (after the first compile) or, before the type is
        /// loaded, a GameObject by the system name.</summary>
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
