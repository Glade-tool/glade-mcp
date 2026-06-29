using System.Collections.Generic;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    /// <summary>
    /// Finds every script that references a symbol (class, method, or field name) so the
    /// agent can see the dependents of the code it is about to change — the scripts a
    /// refactor would otherwise silently break. Complements get_script_content (read one
    /// file) and search_scripts (raw substring): this matches whole identifiers and returns
    /// line-level context per file, ordered by reference count.
    /// </summary>
    public class FindReferencesTool : ITool
    {
        public string Name => "find_references";

        public string Execute(Dictionary<string, object> args)
        {
            if (!args.ContainsKey("symbol"))
                return ToolUtils.CreateErrorResponse("symbol is required");

            string symbol = args["symbol"]?.ToString() ?? "";
            if (string.IsNullOrEmpty(symbol))
                return ToolUtils.CreateErrorResponse("symbol is required");

            int maxFiles = 40;
            if (args.ContainsKey("maxFiles") && int.TryParse(args["maxFiles"]?.ToString(), out var parsedFiles))
                maxFiles = Mathf.Clamp(parsedFiles, 1, 100);

            int maxMatchesPerFile = 5;
            if (args.ContainsKey("maxMatchesPerFile") && int.TryParse(args["maxMatchesPerFile"]?.ToString(), out var parsedMatches))
                maxMatchesPerFile = Mathf.Clamp(parsedMatches, 1, 50);

            var references = UnityContextGatherer.FindReferences(symbol, maxFiles, maxMatchesPerFile);

            int totalMatches = 0;
            foreach (var r in references)
                totalMatches += System.Convert.ToInt32(r["count"]);

            var extras = new Dictionary<string, object>
            {
                { "symbol", symbol },
                { "fileCount", references.Count },
                { "totalMatches", totalMatches },
                { "truncated", references.Count >= maxFiles },
                { "references", references }
            };

            string message = references.Count == 0
                ? $"No references to '{symbol}' found in project scripts."
                : $"Found {totalMatches} reference(s) to '{symbol}' across {references.Count} script(s).";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
