using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    /// <summary>
    /// Writes a Play-tested third-person player controller into the project by
    /// copying two vetted template scripts VERBATIM — ThirdPersonController.cs
    /// (CharacterController movement + grounded jump) and FollowCamera.cs
    /// (stable fixed-offset follow).
    ///
    /// Why a template tool instead of letting the model write the controller:
    /// the 2026-06-01 multi-system spike showed the model composes scenes
    /// flawlessly but RE-DERIVES subtly-broken gameplay code every run — a
    /// self-referential camera offset that sends the player in circles, and a
    /// fragile isGrounded that kills the jump. Both passed every structural
    /// assertion; only Play-mode caught them. Copying the vetted code verbatim
    /// removes the broken step: the model only has to instantiate + wire, which
    /// it already does reliably.
    ///
    /// The template files are the single source of truth for this code. The
    /// human-readable spec (tool sequence, acceptance criteria, anti-patterns)
    /// lives in Proxy/app/lib/system_recipes/player_controller_third_person.md,
    /// which references these templates rather than duplicating them.
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

            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", createdScripts },
                { "requiresCompilation", true },
                {
                    "wiring",
                    "After compile_scripts reports idle: (1) ensure a Player object exists " +
                    "(a Capsule at y=1 on a ground plane) — it must be NAMED 'Player' or TAGGED " +
                    "'Player' so the camera can find it; (2) add_component CharacterController then " +
                    "ThirdPersonController to the Player; (3) add_component FollowCamera to the Main " +
                    "Camera. That's it — no object-reference wiring needed: ThirdPersonController " +
                    "auto-resolves Camera.main and FollowCamera auto-resolves the Player target. Do " +
                    "NOT skip step 3 — without FollowCamera on the camera, the camera won't follow."
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Wrote a Play-tested third-person controller ({createdScripts.Count} scripts) to '{directory}'. " +
                "IMPORTANT: Unity is compiling. Call compile_scripts and wait for idle BEFORE add_component with these types.",
                extras);
        }
    }
}
