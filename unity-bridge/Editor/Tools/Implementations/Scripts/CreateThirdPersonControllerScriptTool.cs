using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    /// <summary>
    /// Writes a ready-to-use third-person player controller into the project by
    /// copying two vetted template scripts VERBATIM — ThirdPersonController.cs
    /// (CharacterController movement + grounded jump) and FollowCamera.cs
    /// (stable fixed-offset follow).
    ///
    /// Why a template tool instead of generating the controller from scratch:
    /// an AI client asked to write a third-person controller tends to re-derive
    /// subtly-broken gameplay code — most commonly a self-referential camera
    /// offset that makes the player circle, and a fragile grounded-check that
    /// blocks the jump. Both compile cleanly and look correct, so they slip past
    /// a quick review and only show up in Play mode. Copying known-good code
    /// verbatim removes that failure mode: the caller only has to instantiate
    /// and attach the components.
    ///
    /// The .cs.txt template files in Editor/Tools/Templates/ are the single
    /// source of truth for this code.
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
                $"Wrote {createdScripts.Count} script(s) to '{directory}'. THE TASK IS NOT DONE — " +
                "this tool only wrote files. You MUST still execute the four-step wiring sequence " +
                "below for the player to actually move and jump. " +
                "STEP 1 (REQUIRED NEXT): call compile_scripts and wait until status='idle'. " +
                "STEP 2 (REQUIRED): add_component CharacterController to the Player capsule. " +
                "STEP 3 (REQUIRED): add_component ThirdPersonController to the Player capsule (the script just written). " +
                "STEP 4 (REQUIRED): add_component FollowCamera to the Main Camera (the other script just written) — " +
                "without this, the camera will not follow and the player will appear stationary on screen even though it moves. " +
                "No object-reference wiring needed afterwards — ThirdPersonController auto-resolves Camera.main and " +
                "FollowCamera auto-resolves the Player by name/tag. Do NOT stop after compile_scripts; " +
                "stopping there leaves the Player as a bare capsule with no controller component.",
                extras);
        }
    }
}
