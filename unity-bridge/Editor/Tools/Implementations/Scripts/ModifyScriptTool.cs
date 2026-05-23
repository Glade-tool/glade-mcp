using System;
using System.Collections.Generic;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    public class ModifyScriptTool : ITool
    {
        public string Name => "modify_script";

        public string Execute(Dictionary<string, object> args)
        {
            string scriptPath = args.ContainsKey("scriptPath") ? args["scriptPath"].ToString() : "";
            // Tool schema uses "scriptContent", but also check "scriptText" for backward compatibility
            string scriptContent = args.ContainsKey("scriptContent") ? args["scriptContent"].ToString()
                : (args.ContainsKey("scriptText") ? args["scriptText"].ToString() : "");
            // Defense-in-depth flag: the caller must explicitly acknowledge
            // it has user permission to modify a pre-existing project script.
            // Defaults false. AI clients should set this only when the user
            // named the file or used language like "extend" / "modify".
            // Without this gate, an AI client that misreads a "scaffold a
            // new system" prompt as "extend an existing one" can silently
            // overwrite real user code.
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

            // Determine file type for error messages
            string fileType = extension.Equals(".shader", StringComparison.OrdinalIgnoreCase) ? "shader" : "script";

            // Check if file exists
            if (!System.IO.File.Exists(scriptPath))
            {
                return ToolUtils.CreateErrorResponse($"{fileType.Substring(0, 1).ToUpper() + fileType.Substring(1)} does not exist at '{scriptPath}'. Use create_script to create a new {fileType}.");
            }

            // ── Session-aware safety check ───────────────────────────────────
            // Refuse modify_script against scripts the caller did NOT create
            // in the current Unity session, unless they explicitly opt in
            // via confirmExistingFileModification=true.
            //
            // This protects user code against AI clients that misread a
            // "scaffold a new system" prompt as "extend an existing one"
            // and call modify_script on the closest-name-matching project
            // script. Such a misread can silently overwrite hundreds of
            // lines of user code. The expected client contract: set the
            // flag only when the user explicitly named the file (e.g.
            // "update FooController.cs") or used language like "extend" /
            // "modify the existing X". On fresh-scaffold prompts the
            // correct call is create_script with a new path.
            if (!SessionTracker.WasScriptCreatedThisSession(scriptPath) && !confirmExistingFileModification)
            {
                var refusedExtras = new Dictionary<string, object>
                {
                    { "scriptPath", scriptPath },
                    { "reason", "preExistingScriptWithoutConfirmation" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"Refused to modify '{scriptPath}' — this {fileType} was not created in the current Unity session via create_script. " +
                    "If the user explicitly named this file to extend or modify, retry modify_script with confirmExistingFileModification=true. " +
                    "Otherwise treat this as a fresh-scaffold task and call create_script with a new path instead. " +
                    "This gate exists to protect user code against AI clients that misread fresh-scaffold prompts as extend-existing.",
                    refusedExtras
                );
            }
            
            // NOTE: Backup is handled by the revert system via /api/file/backup endpoint
            // The frontend calls backupFile() before executing modify_script
            // No need to create .backup files in Assets folder anymore
            
            // Write modified file
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
                ? $"Modified {fileType} at '{scriptPath}'. Unity will auto-compile the script."
                : $"Modified {fileType} at '{scriptPath}'. Unity will import the {fileType}.";
            
            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
