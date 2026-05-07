using System;
using System.Collections.Generic;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Enforces the "Reference demo assets" setting: when disabled, no asset under any
    /// known DemoAssets folder may be used or listed. The setting lives in EditorPrefs
    /// under `GladeAI.ReferenceDemoAssets` and defaults to true when unset.
    ///
    /// Recognized roots (kept in sync with deploy-plugin.ps1 destinations):
    ///   - "Assets/DemoAssets"                              — dev project (this repo)
    ///   - "Packages/com.gladekit.agenticai/DemoAssets"     — DLL bridge install (UPM package)
    /// The MCP bridge (com.gladekit.mcp-bridge) does not ship demo assets.
    /// </summary>
    public static class DemoAssetsGuard
    {
        private static readonly string[] DemoAssetsRoots = new[]
        {
            "Assets/DemoAssets",
            "Packages/com.gladekit.agenticai/DemoAssets",
        };

        /// <summary>
        /// Returns true if the given asset path is under any known DemoAssets root
        /// (case-insensitive, normalizes backslashes, accepts Asset-relative inputs).
        /// </summary>
        public static bool IsPathUnderDemoAssets(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;
            string normalized = path.Replace('\\', '/').Trim();

            // Accept Asset-relative inputs like "DemoAssets/X.prefab" by prepending "Assets/".
            // Do NOT prepend for "Packages/..." paths (UPM AssetDatabase paths) or
            // already-rooted "Assets/..." paths.
            bool isAssetsRooted = normalized.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase);
            bool isPackagesRooted = normalized.StartsWith("Packages/", StringComparison.OrdinalIgnoreCase);
            if (!isAssetsRooted && !isPackagesRooted)
                normalized = "Assets/" + normalized;

            foreach (string root in DemoAssetsRoots)
            {
                string rootForward = root + "/";
                if (normalized.StartsWith(rootForward, StringComparison.OrdinalIgnoreCase)) return true;
                if (normalized.Equals(root, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        /// <summary>
        /// Returns true if the path is allowed to be used (load, save, open, delete, etc.).
        /// Reads `GladeAI.ReferenceDemoAssets` from EditorPrefs.
        /// </summary>
        public static bool AllowUseOfDemoAssetPath(string path)
        {
            if (!IsPathUnderDemoAssets(path)) return true;
            return UnityEditor.EditorPrefs.GetBool("GladeAI.ReferenceDemoAssets", true);
        }

        /// <summary>
        /// When "Reference demo assets" is false, removes any path under any DemoAssets
        /// root from the list. Otherwise returns the list unchanged.
        /// </summary>
        public static List<string> FilterPathsExcludingDemoAssets(List<string> paths)
        {
            if (paths == null || paths.Count == 0) return paths;
            if (UnityEditor.EditorPrefs.GetBool("GladeAI.ReferenceDemoAssets", true)) return paths;
            var filtered = new List<string>(paths.Count);
            foreach (string p in paths)
            {
                if (!IsPathUnderDemoAssets(p))
                    filtered.Add(p);
            }
            return filtered;
        }
    }
}
