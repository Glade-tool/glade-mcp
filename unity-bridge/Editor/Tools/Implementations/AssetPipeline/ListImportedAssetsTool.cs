using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using UnityEngine;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.AssetPipeline
{
    /// <summary>
    /// Walks Assets/ for <c>.gladekit-asset.json</c> sidecars and returns the
    /// license + attribution metadata. Read-only — useful before commercial
    /// release to verify what's been imported and what attribution is required.
    ///
    /// Args:
    ///   licenseFilter (string, optional) — filter to a specific license code
    ///     ("CC0-1.0", "CC-BY-4.0", etc.). "any" or omitted returns all.
    /// </summary>
    public class ListImportedAssetsTool : ITool
    {
        public string Name => "list_imported_assets";

        // Bound the response so a project with hundreds of imports doesn't blow context.
        private const int MaxEntries = 200;

        public string Execute(Dictionary<string, object> args)
        {
            string disabled = AssetPipelineGuard.RejectIfDisabled();
            if (disabled != null) return disabled;

            string licenseFilter = null;
            if (args != null && args.TryGetValue("licenseFilter", out var lfObj) && lfObj != null)
            {
                string lf = lfObj.ToString();
                if (!string.IsNullOrEmpty(lf) && !string.Equals(lf, "any", StringComparison.OrdinalIgnoreCase))
                    licenseFilter = lf;
            }

            string assetsRoot = Application.dataPath; // absolute Assets/ path
            var entries = new List<Dictionary<string, object>>();
            int truncated = 0;

            try
            {
                foreach (var sidecar in EnumerateSidecars(assetsRoot))
                {
                    if (entries.Count >= MaxEntries)
                    {
                        truncated++;
                        continue;
                    }

                    string raw;
                    try { raw = File.ReadAllText(sidecar); }
                    catch { continue; }

                    var meta = ParseSidecar(raw);
                    if (meta == null) continue;

                    if (licenseFilter != null)
                    {
                        string lic = meta.TryGetValue("license", out var lv) ? lv?.ToString() : "";
                        if (!string.Equals(lic, licenseFilter, StringComparison.OrdinalIgnoreCase))
                            continue;
                    }

                    // Add the project-relative sidecar path so consumers can re-open it.
                    // Avoid Path.GetRelativePath (not in older Unity .NET profiles).
                    string relRaw = sidecar
                        .Substring(assetsRoot.Length)
                        .TrimStart(Path.DirectorySeparatorChar, '/')
                        .Replace('\\', '/');
                    meta["sidecar_path"] = "Assets/" + relRaw;
                    entries.Add(meta);
                }
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse($"Failed to enumerate imported assets: {e.Message}");
            }

            // Aggregate license counts so the audit summary is one glance.
            // Use Dictionary<string, object> so ToolUtils.AppendJsonValue
            // recognizes it as a dict (the int-typed variant falls through to
            // the IEnumerable branch and serializes as a stringified list).
            var licenseCounts = new Dictionary<string, object>();
            int attributionRequiredCount = 0;
            foreach (var entry in entries)
            {
                string lic = entry.TryGetValue("license", out var lv) ? lv?.ToString() ?? "UNKNOWN" : "UNKNOWN";
                int prior = licenseCounts.TryGetValue(lic, out var pv) && pv is int p ? p : 0;
                licenseCounts[lic] = prior + 1;
                if (LicenseRequiresAttribution(lic)) attributionRequiredCount++;
            }

            var extras = new Dictionary<string, object>
            {
                { "count", entries.Count },
                { "truncated", truncated > 0 },
                { "additionalNotShown", truncated },
                { "licenseCounts", licenseCounts },
                { "attributionRequiredCount", attributionRequiredCount },
                { "entries", entries },
            };

            string msg = entries.Count == 0
                ? "No assets imported via the pipeline yet."
                : $"Found {entries.Count} imported asset bundle(s){(truncated > 0 ? $" (+{truncated} not shown)" : "")}.";

            return ToolUtils.CreateSuccessResponse(msg, extras);
        }

        private static IEnumerable<string> EnumerateSidecars(string root)
        {
            // Hidden dot-files don't show in Unity Project window but exist on disk.
            // We use SearchOption.AllDirectories to find every sidecar.
            return Directory.EnumerateFiles(root, ".gladekit-asset.json", SearchOption.AllDirectories);
        }

        /// <summary>
        /// Lightweight JSON parser tailored to the sidecar schema. We avoid
        /// pulling in Newtonsoft.Json or System.Text.Json (the bridge minimizes
        /// deps). Schema is fixed, written by us — regex extraction is safe.
        /// </summary>
        private static Dictionary<string, object> ParseSidecar(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            var meta = new Dictionary<string, object>();
            foreach (string field in new[] {
                "candidate_id", "provider", "license", "attribution_text",
                "source_url", "imported_at", "asset_type", "target_path"
            })
            {
                string val = ExtractStringField(json, field);
                if (val != null) meta[field] = val;
            }

            // imported_files is a string array — surface its count rather than the full list
            // (the sidecar already knows them; the audit consumer typically doesn't need them inline).
            int? fileCount = CountStringArrayField(json, "imported_files");
            if (fileCount.HasValue) meta["imported_file_count"] = fileCount.Value;

            return meta.Count > 0 ? meta : null;
        }

        private static string ExtractStringField(string json, string field)
        {
            string pattern = "\"" + Regex.Escape(field) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"";
            var m = Regex.Match(json, pattern);
            if (!m.Success) return null;
            // Unescape \" and \\ minimally.
            return m.Groups[1].Value.Replace("\\\"", "\"").Replace("\\\\", "\\");
        }

        private static int? CountStringArrayField(string json, string field)
        {
            string pattern = "\"" + Regex.Escape(field) + "\"\\s*:\\s*\\[(.*?)\\]";
            var m = Regex.Match(json, pattern, RegexOptions.Singleline);
            if (!m.Success) return null;
            string body = m.Groups[1].Value;
            if (string.IsNullOrWhiteSpace(body)) return 0;
            // Count quoted strings, robust to embedded escapes.
            int count = Regex.Matches(body, "\"(?:[^\"\\\\]|\\\\.)*\"").Count;
            return count;
        }

        private static bool LicenseRequiresAttribution(string license)
        {
            if (string.IsNullOrEmpty(license)) return false;
            return license.IndexOf("CC-BY", StringComparison.OrdinalIgnoreCase) >= 0
                || license.Equals("MIT", StringComparison.OrdinalIgnoreCase);
        }
    }
}
