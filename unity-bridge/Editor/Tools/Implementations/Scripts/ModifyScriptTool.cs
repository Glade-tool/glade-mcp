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

            // Anchor-edit mode: instead of rewriting the whole file, replace an exact snippet
            // (oldString → newString). This is the surgical path for large existing files — the
            // caller sends only the fragment that changes, not thousands of lines. When oldString
            // is present we edit; otherwise we fall back to the full-content rewrite above.
            string oldString = ToolUtils.GetStringArg(args, "oldString", null);
            string newString = ToolUtils.GetStringArg(args, "newString", null);
            bool replaceAll = ToolUtils.GetBoolArg(args, "replaceAll", false);
            bool anchorMode = !string.IsNullOrEmpty(oldString);

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

            if (!anchorMode && string.IsNullOrEmpty(scriptContent))
            {
                return ToolUtils.CreateErrorResponse(
                    "Provide either scriptContent (full file rewrite) or oldString (surgical edit). " +
                    "For a small change to a large file, prefer oldString/newString.");
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

            int replacements = 0;
            if (anchorMode)
            {
                // Resolve the surgical edit against the current file. Exact, literal matching
                // (ordinal) — no regex — so the snippet the model sends is what gets replaced.
                string current;
                try { current = System.IO.File.ReadAllText(scriptPath); }
                catch (Exception ex) { return ToolUtils.CreateErrorResponse($"Failed to read '{scriptPath}': {ex.Message}"); }

                newString = newString ?? "";
                if (oldString == newString)
                {
                    return ToolUtils.CreateErrorResponse("oldString and newString are identical — no change to make.");
                }

                int occurrences = CountOccurrences(current, oldString);
                if (occurrences == 0)
                {
                    return ToolUtils.CreateErrorResponse(
                        $"oldString was not found in '{scriptPath}'. It must match the file's current text exactly " +
                        "(whitespace and indentation included). Read the script first to copy the exact snippet.");
                }
                if (occurrences > 1 && !replaceAll)
                {
                    return ToolUtils.CreateErrorResponse(
                        $"oldString matched {occurrences} times in '{scriptPath}'. Include more surrounding context to " +
                        "make it unique, or set replaceAll=true to replace every occurrence.");
                }

                scriptContent = replaceAll
                    ? current.Replace(oldString, newString)
                    : ReplaceFirst(current, oldString, newString);
                replacements = replaceAll ? occurrences : 1;
            }

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
            if (anchorMode)
            {
                extras.Add("mode", "anchor");
                extras.Add("replacements", replacements);
            }

            string editNote = anchorMode
                ? $" ({replacements} replacement{(replacements == 1 ? "" : "s")})"
                : "";
            string message = requiresCompilation
                ? $"Modified {fileType} at '{scriptPath}'{editNote}. Unity will auto-compile the script."
                : $"Modified {fileType} at '{scriptPath}'{editNote}. Unity will import the {fileType}.";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }

        private static int CountOccurrences(string haystack, string needle)
        {
            if (string.IsNullOrEmpty(needle))
                return 0;
            int count = 0;
            int idx = 0;
            while ((idx = haystack.IndexOf(needle, idx, StringComparison.Ordinal)) >= 0)
            {
                count++;
                idx += needle.Length;
            }
            return count;
        }

        private static string ReplaceFirst(string haystack, string needle, string replacement)
        {
            int idx = haystack.IndexOf(needle, StringComparison.Ordinal);
            if (idx < 0)
                return haystack;
            return haystack.Substring(0, idx) + replacement + haystack.Substring(idx + needle.Length);
        }
    }
}
