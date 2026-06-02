using System;
using System.Collections.Generic;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    public class CreateScriptTool : ITool
    {
        public string Name => "create_script";

        public string Execute(Dictionary<string, object> args)
        {
            string scriptPath = args.ContainsKey("scriptPath") ? args["scriptPath"].ToString() : "";
            // Tool schema uses "scriptContent", but also check "scriptText" for backward compatibility
            string scriptContent = args.ContainsKey("scriptContent") ? args["scriptContent"].ToString()
                : (args.ContainsKey("scriptText") ? args["scriptText"].ToString() : "");
            // Mirrors ModifyScriptTool's gate: caller must explicitly acknowledge
            // it has user permission to overwrite a pre-existing project script.
            // Same flag name as modify_script so the agent learns one pattern.
            bool confirmExistingFileModification = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            if (string.IsNullOrEmpty(scriptPath))
            {
                return ToolUtils.CreateErrorResponse("scriptPath is required");
            }

            if (string.IsNullOrEmpty(scriptContent))
            {
                return ToolUtils.CreateErrorResponse("scriptContent is required");
            }

            // Ensure path starts with Assets/
            if (!scriptPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
            {
                scriptPath = "Assets/" + scriptPath;
            }

            // Detect file extension from path, default to .cs if no extension
            string extension = System.IO.Path.GetExtension(scriptPath);
            if (string.IsNullOrEmpty(extension))
            {
                scriptPath += ".cs";
                extension = ".cs";
            }

            // Determine file type for messages
            string fileType = extension.Equals(".shader", StringComparison.OrdinalIgnoreCase) ? "shader" : "script";

            // ── Session-aware overwrite guard ────────────────────────────────
            // Refuse create_script against an existing on-disk file the caller
            // did NOT create in the current Unity session, unless they
            // explicitly opt in via confirmExistingFileModification=true.
            //
            // Sibling hole to the ModifyScriptTool gate: previously the model
            // could clobber any real project script by calling create_script
            // with a colliding path. Demonstrated 2026-06-01: a trial's
            // create_script overwrote ThirdPersonCameraFollow.cs (151 lines)
            // with a 21-line scaffold stub. The modify_script gate did nothing
            // because the tool used was create_script, not modify_script.
            //
            // File doesn't exist → create freely. File exists and we created
            // it earlier this session → allow (regenerate-from-scratch flow).
            // File exists and we did NOT create it → refuse without the flag.
            if (System.IO.File.Exists(scriptPath)
                && !SessionTracker.WasScriptCreatedThisSession(scriptPath)
                && !confirmExistingFileModification)
            {
                var refusedExtras = new Dictionary<string, object>
                {
                    { "scriptPath", scriptPath },
                    { "reason", "preExistingScriptWithoutConfirmation" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"Refused to overwrite '{scriptPath}' — this {fileType} already exists and was not created in the current Unity session. " +
                    "If the user explicitly named this file to regenerate or replace, retry create_script with confirmExistingFileModification=true. " +
                    "Otherwise pick a different path so you don't clobber existing user code. " +
                    "This gate exists to protect user code against AI clients that misread fresh-scaffold prompts as overwrite-existing.",
                    refusedExtras
                );
            }

            // Ensure directory exists
            string dir = System.IO.Path.GetDirectoryName(scriptPath);
            if (!System.IO.Directory.Exists(dir))
            {
                System.IO.Directory.CreateDirectory(dir);
            }

            // Write file
            System.IO.File.WriteAllText(scriptPath, scriptContent);

            // Refresh AssetDatabase
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            // Determine if compilation is needed (only for .cs files)
            bool requiresCompilation = extension.Equals(".cs", StringComparison.OrdinalIgnoreCase);
            
            var extras = new Dictionary<string, object>
            {
                { "scriptPath", scriptPath }
            };
            if (requiresCompilation)
            {
                extras.Add("requiresCompilation", true);
            }
            
            string message = requiresCompilation
                ? $"Created {fileType} at '{scriptPath}'. IMPORTANT: Unity is compiling this script. You MUST call compile_scripts and wait until it reports 'Compilation complete' BEFORE calling add_component with this script type."
                : $"Created {fileType} at '{scriptPath}'. Unity will import the {fileType}.";
            
            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
