using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    // This namespace has sibling sub-namespaces `...Implementations.GameObject`
    // and `...Implementations.Camera`. When resolving a bare `GameObject` /
    // `Camera`, C# searches enclosing namespaces (here, `...Implementations`)
    // for a matching member BEFORE it ever consults a file-level using-alias, so
    // an alias placed outside this block is shadowed by those namespaces and the
    // name binds to the namespace (CS0118). A using-alias declared INSIDE the
    // namespace body is consulted first, so it correctly wins — alias both names
    // to their Unity types here rather than fully qualifying every usage.
    using GameObject = UnityEngine.GameObject;
    using Camera = UnityEngine.Camera;

    /// <summary>
    /// Produces a complete, playable third-person player in ONE call. It copies
    /// two vetted template scripts VERBATIM — ThirdPersonController.cs
    /// (CharacterController movement + grounded jump) and FollowCamera.cs
    /// (modern mouse / right-stick orbit camera) — then assembles the scene around them:
    /// ensures a Player capsule and a Main Camera exist, adds the built-in
    /// CharacterController immediately, and QUEUES the two custom components to
    /// attach automatically once the scripts compile.
    ///
    /// Why a template tool instead of generating the controller from scratch:
    /// an AI client asked to write a third-person controller tends to re-derive
    /// subtly-broken gameplay code — most commonly a self-referential camera
    /// offset that makes the player circle, and a fragile grounded-check that
    /// blocks the jump. Both compile cleanly and look correct, so they slip past
    /// a quick review and only show up in Play mode. Copying known-good code
    /// verbatim removes that failure mode.
    ///
    /// Why this tool is ATOMIC (does the wiring itself, see
    /// <see cref="PendingControllerWiring"/>): even with verbatim scripts, the
    /// caller used to have to wait for compilation and then issue separate
    /// add_component calls — a multi-step contract an AI client frequently
    /// dropped under load, leaving a bare capsule with no controller. A
    /// MonoBehaviour type cannot be AddComponent'd until its script has compiled
    /// AND a domain reload has loaded the new assembly, so this tool can't attach
    /// the custom components synchronously. Instead it queues them; Unity's normal
    /// compile → reload cycle fires the attach. The caller has nothing left to do
    /// but let compilation finish.
    ///
    /// The .cs.txt template files in Editor/Tools/Templates/ are the single
    /// source of truth for the script bodies.
    /// </summary>
    public class CreateThirdPersonControllerScriptTool : ITool
    {
        public string Name => "create_third_person_controller";

        // (template file name on disk, written file name in the project)
        private static readonly (string template, string scriptName)[] Scripts =
        {
            ("ThirdPersonController.cs.txt", "ThirdPersonController.cs"),
            ("FollowCamera.cs.txt", "FollowCamera.cs"),
        };

        public string Execute(Dictionary<string, object> args)
        {
            // Where to write the scripts. Default mirrors the project convention.
            string directory = ToolUtils.GetStringArg(args, "directory", "Assets/Scripts");
            bool confirmExistingFileModification =
                ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);
            string playerName = ToolUtils.GetStringArg(args, "playerName", "Player");
            if (string.IsNullOrEmpty(playerName)) playerName = "Player";
            bool createGround = ToolUtils.GetBoolArg(args, "createGround", true);

            if (string.IsNullOrEmpty(directory)) directory = "Assets/Scripts";
            directory = directory.Replace('\\', '/').TrimEnd('/');
            if (!directory.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase)
                && !directory.Equals("Assets", StringComparison.OrdinalIgnoreCase))
            {
                directory = "Assets/" + directory;
            }

            // Resolve every template up front so a missing-template failure happens
            // before we write anything (no half-written controller).
            var resolved = new List<(string templatePath, string scriptPath)>();
            foreach (var (template, scriptName) in Scripts)
            {
                string templatePath = ToolUtils.ResolveTemplatePath(template);
                if (string.IsNullOrEmpty(templatePath))
                {
                    return ToolUtils.CreateErrorResponse(
                        $"Template '{template}' could not be found in any known bridge location. " +
                        "The bridge install may be incomplete — reinstall com.gladekit.mcp-bridge.");
                }
                resolved.Add((templatePath, $"{directory}/{scriptName}"));
            }

            // ── Session-aware overwrite guard (mirrors CreateScriptTool) ──────
            // Refuse to clobber a pre-existing file we did NOT create this session
            // unless the caller explicitly opts in. Checked for ALL targets before
            // any write so we never leave one script overwritten and the other not.
            if (!confirmExistingFileModification)
            {
                foreach (var (_, scriptPath) in resolved)
                {
                    if (File.Exists(scriptPath)
                        && !SessionTracker.WasScriptCreatedThisSession(scriptPath))
                    {
                        var refusedExtras = new Dictionary<string, object>
                        {
                            { "scriptPath", scriptPath },
                            { "reason", "preExistingScriptWithoutConfirmation" },
                        };
                        return ToolUtils.CreateErrorResponse(
                            $"Refused to overwrite '{scriptPath}' — it already exists and was not created in this session. " +
                            "If the user explicitly asked to regenerate the controller, retry with confirmExistingFileModification=true. " +
                            "Otherwise pass a different 'directory' so you don't clobber existing user code.",
                            refusedExtras);
                    }
                }
            }

            if (!Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var createdScripts = new List<string>();
            foreach (var (templatePath, scriptPath) in resolved)
            {
                string content = File.ReadAllText(templatePath);
                File.WriteAllText(scriptPath, content);
                // Mark so a follow-up create_script / modify_script on this path is
                // recognized as session-created and not refused by the guard.
                SessionTracker.MarkScriptCreated(scriptPath);
                createdScripts.Add(scriptPath);
            }

            // ── Assemble the scene around the scripts (the ATOMIC part) ───────
            // Everything below uses only built-in types (Capsule/CharacterController/
            // Camera/Plane), so it can run synchronously right now. The two custom
            // MonoBehaviours can't exist until the scripts above compile, so they
            // are QUEUED for PendingControllerWiring to attach after the reload.
            var sceneNotes = new List<string>();
            GameObject player = EnsurePlayer(playerName, sceneNotes);
            GameObject camera = EnsureMainCamera(sceneNotes);
            if (createGround) EnsureGround(sceneNotes);

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(player.name, "Player", "ThirdPersonController"),
                new PendingControllerWiring.WiringRequest(camera.name, "MainCamera", "FollowCamera"),
            });

            // The created GameObjects survive the impending domain reload (edit-mode
            // scene objects persist across assembly reloads), but mark the scene
            // dirty so the changes are recognised as part of the open scene.
            try { EditorSceneManager.MarkSceneDirty(camera.scene); } catch { /* no open scene */ }

            // Triggers compile + domain reload; PendingControllerWiring fires on the
            // afterAssemblyReload that follows, attaching the two components.
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", createdScripts },
                { "requiresCompilation", true },
                { "playerObject", player.name },
                { "cameraObject", camera.name },
                { "sceneSetup", sceneNotes },
                {
                    "queuedComponents",
                    new List<string>
                    {
                        $"ThirdPersonController → {player.name}",
                        $"FollowCamera → {camera.name}",
                    }
                },
                {
                    "wiring",
                    "Automatic — this tool already created the Player + Main Camera, added " +
                    "CharacterController to the Player, and queued ThirdPersonController + FollowCamera " +
                    "to attach the moment the scripts finish compiling. The scripts self-resolve their " +
                    "references (ThirdPersonController → Camera.main, FollowCamera → the 'Player' tag), " +
                    "so no object-reference wiring is needed."
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a complete, playable third-person controller in '{directory}'. " +
                "This tool is ATOMIC — it wrote the two vetted scripts, ensured a Player capsule and a " +
                "Main Camera exist, added CharacterController to the Player, and QUEUED ThirdPersonController + " +
                "FollowCamera to attach automatically as soon as the scripts compile. " +
                "DO NOT call add_component for these components — that happens for you on the next compile, " +
                "and the scripts self-resolve their references so no object-reference wiring is needed. " +
                "Your ONLY remaining step is to call compile_scripts and wait until status='idle'; after that " +
                "the player moves with WASD and jumps with Space, and the camera follows.",
                extras);
        }

        // ── Scene-assembly helpers (built-in types only — safe to run now) ────

        /// <summary>Returns the existing Player (by 'Player' tag, then by name) or
        /// creates a Capsule named <paramref name="playerName"/> at y=1. Either way
        /// the returned object has a CharacterController (the movement script's
        /// RequireComponent, added now since it is a built-in type).</summary>
        private static GameObject EnsurePlayer(string playerName, List<string> notes)
        {
            GameObject player = FindByTag("Player") ?? GameObject.Find(playerName);
            if (player == null)
            {
                player = GameObject.CreatePrimitive(PrimitiveType.Capsule);
                player.name = playerName;
                player.transform.position = new Vector3(0f, 1f, 0f);
                Undo.RegisterCreatedObjectUndo(player, "Create Player");
                notes.Add($"created Player capsule '{playerName}' at (0,1,0)");
            }
            else
            {
                notes.Add($"reused existing player '{player.name}'");
            }

            TrySetTag(player, "Player");

            if (player.GetComponent<CharacterController>() == null)
            {
                player.AddComponent<CharacterController>();
                notes.Add("added CharacterController to player");
            }

            return player;
        }

        /// <summary>Returns the scene's Main Camera, retagging the first camera it
        /// finds as MainCamera if none is tagged, or creating one if the scene has
        /// no camera at all.</summary>
        private static GameObject EnsureMainCamera(List<string> notes)
        {
            if (Camera.main != null)
            {
                notes.Add($"reused Main Camera '{Camera.main.gameObject.name}'");
                return Camera.main.gameObject;
            }

            var anyCamera = UnityEngine.Object.FindFirstObjectByType<Camera>();
            if (anyCamera != null)
            {
                TrySetTag(anyCamera.gameObject, "MainCamera");
                notes.Add($"tagged existing camera '{anyCamera.gameObject.name}' as MainCamera");
                return anyCamera.gameObject;
            }

            var camGo = new GameObject("Main Camera");
            camGo.AddComponent<Camera>();
            camGo.AddComponent<AudioListener>();
            TrySetTag(camGo, "MainCamera");
            camGo.transform.position = new Vector3(0f, 4f, -7f);
            camGo.transform.rotation = Quaternion.Euler(20f, 0f, 0f);
            Undo.RegisterCreatedObjectUndo(camGo, "Create Main Camera");
            notes.Add("created a Main Camera (scene had none)");
            return camGo;
        }

        /// <summary>Creates a scaled-up ground Plane if the scene has nothing that
        /// looks like a floor — so a standalone call yields a player that can stand
        /// somewhere. Skipped when the scene already has a plausible ground (the
        /// common case when the caller built the level first).</summary>
        private static void EnsureGround(List<string> notes)
        {
            if (SceneHasGround()) return;

            var ground = GameObject.CreatePrimitive(PrimitiveType.Plane);
            ground.name = "Ground";
            ground.transform.localScale = new Vector3(5f, 1f, 5f);
            Undo.RegisterCreatedObjectUndo(ground, "Create Ground");
            notes.Add("created a 50x50 Ground plane (scene had none)");
        }

        private static bool SceneHasGround()
        {
            foreach (var go in UnityEngine.Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None))
            {
                string n = go.name.ToLowerInvariant();
                if (n.Contains("ground") || n.Contains("floor") || n.Contains("terrain"))
                    return true;

                var mf = go.GetComponent<MeshFilter>();
                if (mf != null && mf.sharedMesh != null &&
                    mf.sharedMesh.name.IndexOf("Plane", StringComparison.OrdinalIgnoreCase) >= 0)
                    return true;
            }
            return false;
        }

        private static GameObject FindByTag(string tag)
        {
            try { return GameObject.FindWithTag(tag); }
            catch { return null; } // tag not defined in this project
        }

        private static void TrySetTag(GameObject go, string tag)
        {
            try { go.tag = tag; }
            catch { /* tag not defined — the scripts also fall back to name lookup */ }
        }
    }
}
