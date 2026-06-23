using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Shared plumbing for the gameplay scaffolders (create_collectible,
    /// create_hazard, …). Keeps the "ensure the GameManager contract script
    /// exists", "write a vetted shared script reuse-don't-refuse", and "give each
    /// scaffolded object a unique name" rules in one place so every gameplay tool
    /// behaves identically.
    /// </summary>
    internal static class GameplayScaffold
    {
        /// <summary>Normalize a caller directory to an Assets-relative path.</summary>
        public static string NormalizeDir(string directory, string fallback = "Assets/Scripts")
        {
            if (string.IsNullOrEmpty(directory)) directory = fallback;
            directory = directory.Replace('\\', '/').TrimEnd('/');
            if (!directory.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase)
                && !directory.Equals("Assets", StringComparison.OrdinalIgnoreCase))
            {
                directory = "Assets/" + directory;
            }
            return directory;
        }

        /// <summary>
        /// Ensure a CONTRACT script (one a vetted template references by type, e.g.
        /// GameManager or Health) exists in the project EXACTLY ONCE — two copies of
        /// the same class would break the whole assembly. If any file of that name is
        /// already in Assets, reuse it; otherwise copy the template into
        /// <paramref name="preferredDir"/>. Creating the contract does NOT build the
        /// thing it describes (no GameManager object/HUD, no Health-bearing object) —
        /// the gameplay code degrades gracefully when none is present. Returns "" on
        /// success, else an error.
        /// </summary>
        public static string EnsureContractScript(string templateFile, string scriptName,
            string preferredDir, List<string> notes, string friendlyNote)
        {
            string existing = FindExistingScript(scriptName);
            if (existing != null)
            {
                notes.Add($"reused existing {existing}");
                return "";
            }

            string templatePath = ToolUtils.ResolveTemplatePath(templateFile);
            if (string.IsNullOrEmpty(templatePath))
                return $"Template '{templateFile}' not found — reinstall com.gladekit.mcp-bridge.";

            if (!Directory.Exists(preferredDir)) Directory.CreateDirectory(preferredDir);
            string dest = $"{preferredDir}/{scriptName}";
            File.WriteAllText(dest, File.ReadAllText(templatePath));
            SessionTracker.MarkScriptCreated(dest);
            notes.Add($"wrote {dest} ({friendlyNote})");
            return "";
        }

        /// <summary>The Collectible/Hazard contract: GameManager.cs must exist for
        /// their <c>GameManager.Instance</c> calls to compile.</summary>
        public static string EnsureGameManagerScript(string preferredDir, List<string> notes) =>
            EnsureContractScript("GameManager.cs.txt", "GameManager.cs", preferredDir, notes,
                "the gameplay hub this talks to — call create_game_manager to add the HUD + win/lose");

        /// <summary>
        /// Write a vetted shared template script reuse-don't-refuse: reuse it as-is
        /// when present (don't clobber user edits — many pickups share one script),
        /// (re)write only when absent or explicitly confirmed. Returns "" on success
        /// (path via <paramref name="scriptPath"/>), else an error.
        /// </summary>
        public static string WriteVettedScript(string templateFile, string scriptName,
            string dir, bool confirmOverwrite, out string scriptPath)
        {
            scriptPath = $"{dir}/{scriptName}";
            string templatePath = ToolUtils.ResolveTemplatePath(templateFile);
            if (string.IsNullOrEmpty(templatePath))
                return $"Template '{templateFile}' not found — reinstall com.gladekit.mcp-bridge.";

            bool exists = File.Exists(scriptPath);
            if (!exists || confirmOverwrite)
            {
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                File.WriteAllText(scriptPath, File.ReadAllText(templatePath));
                if (!exists) SessionTracker.MarkScriptCreated(scriptPath);
            }
            return "";
        }

        /// <summary>
        /// Return a scene-unique name. The deferred wiring resolves its target by
        /// name, so two objects sharing a name (five "Collectible"s) would all wire
        /// to whichever GameObject.Find hits first. Suffixing keeps each addressable.
        /// </summary>
        public static string UniqueName(string baseName)
        {
            if (string.IsNullOrEmpty(baseName)) baseName = "GameObject";
            if (GameObject.Find(baseName) == null) return baseName;
            for (int i = 1; i < 10000; i++)
            {
                string candidate = $"{baseName} ({i})";
                if (GameObject.Find(candidate) == null) return candidate;
            }
            return baseName;
        }

        /// <summary>Find any existing file named <paramref name="fileName"/> under
        /// Assets, independent of import state (a freshly-written .cs may not be in
        /// the AssetDatabase index yet). Returns an Assets-relative path or null.</summary>
        private static string FindExistingScript(string fileName)
        {
            try
            {
                string root = Application.dataPath.Replace('\\', '/'); // <project>/Assets
                string[] hits = Directory.GetFiles(root, fileName, SearchOption.AllDirectories);
                if (hits.Length == 0) return null;
                string abs = hits[0].Replace('\\', '/');
                return "Assets" + abs.Substring(root.Length);
            }
            catch
            {
                return null;
            }
        }
    }
}
