using System.Collections.Generic;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    /// <summary>
    /// Finds every prefab asset and open-scene GameObject that has a component of a
    /// given type — the Inspector-wiring counterpart to find_references. find_references
    /// covers code (which scripts reference a symbol); this covers wiring (what a script
    /// or component is actually attached to), which lives in scene/prefab data and is
    /// invisible in the source. Use it to see the blast radius before changing or removing
    /// a component, or before renaming a MonoBehaviour whose attachments would be lost.
    /// </summary>
    public class FindComponentUsagesTool : ITool
    {
        public string Name => "find_component_usages";

        public string Execute(Dictionary<string, object> args)
        {
            if (!args.ContainsKey("componentType"))
                return ToolUtils.CreateErrorResponse("componentType is required");

            string componentType = args["componentType"]?.ToString() ?? "";
            if (string.IsNullOrEmpty(componentType))
                return ToolUtils.CreateErrorResponse("componentType is required");

            int maxResults = 60;
            if (args.ContainsKey("maxResults") && int.TryParse(args["maxResults"]?.ToString(), out var parsed))
                maxResults = Mathf.Clamp(parsed, 1, 200);

            var found = UnityContextGatherer.FindComponentUsages(componentType, maxResults);
            var usages = found["usages"] as List<Dictionary<string, object>>;
            bool truncated = found.ContainsKey("truncated") && (bool)found["truncated"];
            int count = usages?.Count ?? 0;

            int prefabCount = 0;
            int sceneCount = 0;
            if (usages != null)
            {
                foreach (var u in usages)
                {
                    if (u.TryGetValue("location", out var loc) && loc?.ToString() == "prefab")
                        prefabCount++;
                    else
                        sceneCount++;
                }
            }

            var extras = new Dictionary<string, object>
            {
                { "componentType", componentType },
                { "count", count },
                { "prefabCount", prefabCount },
                { "sceneCount", sceneCount },
                { "truncated", truncated },
                { "usages", usages ?? new List<Dictionary<string, object>>() },
            };

            string message = count == 0
                ? $"No prefab or open-scene object uses '{componentType}'."
                : $"Found '{componentType}' on {count} object(s): {prefabCount} in prefabs, {sceneCount} in open scene(s).";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
