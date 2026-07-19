using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    /// <summary>
    /// Project-wide rename of a C# identifier (class, method, field, property, local, …)
    /// across all non-Editor project scripts. Uses the lexical scanner so it rewrites
    /// ONLY code-region whole-identifier occurrences — never text inside a string literal
    /// or comment, and never a substring (renaming <c>Player</c> leaves
    /// <c>PlayerController</c> alone) — which a plain find-and-replace cannot guarantee.
    ///
    /// Preview-first: pass <c>dryRun=true</c> to see the blast radius (files + counts)
    /// without writing. This is a LEXICAL rename — it does not tell two distinct symbols
    /// that share a name apart (that needs full semantic analysis), so on an ambiguous
    /// name preview first or scope with <c>directory</c>. Revert a cross-file rename via
    /// version control if needed.
    /// </summary>
    public class RenameSymbolTool : ITool
    {
        public string Name => "rename_symbol";

        // Reserved C# keywords cannot be used as an identifier — renaming TO one would
        // break compilation project-wide. Contextual keywords (var, async, …) are legal
        // identifiers and intentionally omitted.
        private static readonly HashSet<string> ReservedKeywords = new HashSet<string>
        {
            "abstract","as","base","bool","break","byte","case","catch","char","checked",
            "class","const","continue","decimal","default","delegate","do","double","else",
            "enum","event","explicit","extern","false","finally","fixed","float","for",
            "foreach","goto","if","implicit","in","int","interface","internal","is","lock",
            "long","namespace","new","null","object","operator","out","override","params",
            "private","protected","public","readonly","ref","return","sbyte","sealed","short",
            "sizeof","stackalloc","static","string","struct","switch","this","throw","true",
            "try","typeof","uint","ulong","unchecked","unsafe","ushort","using","virtual",
            "void","volatile","while"
        };

        public string Execute(Dictionary<string, object> args)
        {
            string oldName = ToolUtils.GetStringArg(args, "oldName", "");
            string newName = ToolUtils.GetStringArg(args, "newName", "");
            bool dryRun = ToolUtils.GetBoolArg(args, "dryRun", false);
            string directory = ToolUtils.GetStringArg(args, "directory", "");
            int maxFiles = ToolUtils.GetIntArg(args, "maxFiles", 200);
            if (maxFiles < 1) maxFiles = 1;

            if (string.IsNullOrEmpty(oldName))
                return ToolUtils.CreateErrorResponse("oldName is required");
            if (string.IsNullOrEmpty(newName))
                return ToolUtils.CreateErrorResponse("newName is required");
            if (oldName == newName)
                return ToolUtils.CreateErrorResponse("oldName and newName are identical — nothing to rename.");
            if (!CSharpLexicalScanner.IsValidIdentifier(oldName))
                return ToolUtils.CreateErrorResponse($"oldName '{oldName}' is not a valid C# identifier.");
            if (!CSharpLexicalScanner.IsValidIdentifier(newName))
                return ToolUtils.CreateErrorResponse(
                    $"newName '{newName}' is not a valid C# identifier (letters, digits, underscore; must not start with a digit).");
            if (ReservedKeywords.Contains(newName))
                return ToolUtils.CreateErrorResponse(
                    $"newName '{newName}' is a reserved C# keyword — renaming to it would break compilation.");

            // Normalize the optional directory scope to an Assets-relative prefix.
            string scope = (directory ?? "").Replace("\\", "/").Trim();
            if (!string.IsNullOrEmpty(scope))
            {
                if (!scope.StartsWith("Assets", StringComparison.OrdinalIgnoreCase))
                    scope = "Assets/" + scope;
                scope = scope.TrimEnd('/');
            }

            var changedFiles = new List<Dictionary<string, object>>();
            var pendingWrites = new List<KeyValuePair<string, string>>(); // fullPath → new content
            int totalOccurrences = 0;
            int skippedDemo = 0;

            try
            {
                var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
                foreach (var guid in scriptGuids)
                {
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(path) || !path.EndsWith(".cs"))
                        continue;
                    if (path.Contains("/Editor/") || path.StartsWith("Packages/"))
                        continue;
                    if (!string.IsNullOrEmpty(scope)
                        && !path.StartsWith(scope + "/", StringComparison.OrdinalIgnoreCase)
                        && !path.Equals(scope, StringComparison.OrdinalIgnoreCase))
                        continue;

                    string fullPath = Path.Combine(Application.dataPath, path.Replace("Assets/", ""));
                    if (!File.Exists(fullPath))
                        continue;

                    string content;
                    try { content = File.ReadAllText(fullPath); }
                    catch { continue; }

                    // Never rewrite protected demo content — but surface that we skipped a
                    // file that references the symbol, since it will not compile afterward.
                    if (DemoAssetsGuard.IsPathUnderDemoAssets(path))
                    {
                        if (CSharpLexicalScanner.CountOccurrences(content, oldName) > 0)
                            skippedDemo++;
                        continue;
                    }

                    string rewritten = CSharpLexicalScanner.Rewrite(content, oldName, newName, out int applied);
                    if (applied == 0)
                        continue;

                    totalOccurrences += applied;
                    changedFiles.Add(new Dictionary<string, object>
                    {
                        { "path", path },
                        { "count", applied }
                    });
                    pendingWrites.Add(new KeyValuePair<string, string>(fullPath, rewritten));
                }
            }
            catch (Exception ex)
            {
                return ToolUtils.CreateErrorResponse($"rename_symbol failed while scanning project scripts: {ex.Message}");
            }

            // Highest-impact files first for a readable report.
            changedFiles.Sort((a, b) => Convert.ToInt32(b["count"]).CompareTo(Convert.ToInt32(a["count"])));

            var extras = new Dictionary<string, object>
            {
                { "oldName", oldName },
                { "newName", newName },
                { "fileCount", changedFiles.Count },
                { "totalOccurrences", totalOccurrences },
                { "changedFiles", changedFiles },
                { "dryRun", dryRun },
            };
            if (skippedDemo > 0) extras.Add("skippedDemoAssetFiles", skippedDemo);

            if (changedFiles.Count == 0)
            {
                return ToolUtils.CreateSuccessResponse(
                    $"No code references to '{oldName}' found{(string.IsNullOrEmpty(scope) ? "" : $" under '{scope}'")}; nothing to rename.",
                    extras);
            }

            if (dryRun)
            {
                return ToolUtils.CreateSuccessResponse(
                    $"[dry run] Renaming '{oldName}' → '{newName}' would change {totalOccurrences} occurrence(s) " +
                    $"across {changedFiles.Count} file(s). No files were modified.",
                    extras);
            }

            // A partial cross-file rename leaves dangling references that fail to compile,
            // so refuse to APPLY beyond the safety cap — but still report the full blast
            // radius so the caller can narrow scope, raise the cap, or preview.
            if (changedFiles.Count > maxFiles)
            {
                extras.Add("blocked", "exceedsMaxFiles");
                return ToolUtils.CreateErrorResponse(
                    $"Rename would touch {changedFiles.Count} files, above maxFiles={maxFiles}. A partial rename would break " +
                    "compilation. Narrow with `directory`, raise `maxFiles`, or run with dryRun=true to review the full blast radius first.",
                    extras);
            }

            int written = 0;
            foreach (var kv in pendingWrites)
            {
                try { File.WriteAllText(kv.Key, kv.Value); written++; }
                catch (Exception ex)
                {
                    return ToolUtils.CreateErrorResponse(
                        $"Renamed {written}/{pendingWrites.Count} files, then failed writing '{kv.Key}': {ex.Message}. " +
                        "The project may be in a partially-renamed state — revert via version control.",
                        extras);
                }
            }

            AssetDatabase.Refresh(ImportAssetOptions.Default);

            extras.Add("requiresCompilation", true);
            return ToolUtils.CreateSuccessResponse(
                $"Renamed '{oldName}' → '{newName}': {totalOccurrences} occurrence(s) across {written} file(s). Unity will auto-compile.",
                extras);
        }
    }
}
