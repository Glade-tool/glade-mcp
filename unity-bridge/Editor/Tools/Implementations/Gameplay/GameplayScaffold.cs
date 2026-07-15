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

        /// <summary>True when the caller asked for a 2D object (dimension="2d"),
        /// false for 3D (the default). Accepts "2d"/"2" and "3d"/"3", case-insensitive;
        /// anything else falls back to <paramref name="fallback"/>.</summary>
        public static bool WantsTwoD(Dictionary<string, object> args, bool fallback = false)
        {
            string d = ToolUtils.GetStringArg(args, "dimension", "").Trim().ToLowerInvariant();
            if (d == "2d" || d == "2") return true;
            if (d == "3d" || d == "3") return false;
            return fallback;
        }

        /// <summary>
        /// Build a visible TRIGGER VOLUME in the requested dimension — the shared
        /// geometry step for create_collectible / create_hazard. 3D builds a
        /// primitive (sphere/cube) with its trigger Collider; 2D builds a sprite
        /// object (placeholder art, tinted) with a trigger Collider2D
        /// (circle or box). The caller registers Undo and queues the behavior
        /// component; this only produces the addressable, correctly-collided object.
        /// </summary>
        public static GameObject BuildTriggerObject(string name, bool is2D, PrimitiveType prim3D,
            bool circleCollider2D, Vector3 position, float scale, Color tint2D, List<string> notes)
        {
            GameObject go;
            if (is2D)
            {
                go = new GameObject(name);
                var sr = go.AddComponent<SpriteRenderer>();
                var sprite = LoadOrCreatePlaceholderSprite(out string spriteErr);
                if (sprite != null) { sr.sprite = sprite; sr.color = tint2D; }
                else if (!string.IsNullOrEmpty(spriteErr)) notes.Add(spriteErr);
                go.transform.position = position;
                go.transform.localScale = new Vector3(scale, scale, 1f);
                Collider2D col2D = circleCollider2D
                    ? (Collider2D)go.AddComponent<CircleCollider2D>()
                    : go.AddComponent<BoxCollider2D>();
                col2D.isTrigger = true;
            }
            else
            {
                go = GameObject.CreatePrimitive(prim3D);
                go.name = name;
                go.transform.position = position;
                go.transform.localScale = Vector3.one * scale;
                var col = go.GetComponent<Collider>();
                if (col != null) col.isTrigger = true;
            }
            return go;
        }

        /// <summary>Shared Assets path for the generated placeholder sprite used by
        /// the 2D scaffolders (matches create_parallax_layer so all 2D placeholders
        /// share one asset).</summary>
        public const string PlaceholderSpritePath = "Assets/GladeKit/Placeholders/WhiteSquare.png";

        /// <summary>
        /// Load the shared 64x64 white placeholder sprite, generating it on first
        /// use so a 2D scaffolder's object is visible (tint it) instead of an
        /// invisible collider. Self-healing: if the PNG exists but a project-wide
        /// importer preset left it unloadable as a Sprite (e.g. spriteMode=Multiple),
        /// the importer is corrected and the asset reimported. Returns null with an
        /// error set only if generation genuinely fails.
        /// </summary>
        public static Sprite LoadOrCreatePlaceholderSprite(out string error)
        {
            error = "";

            var existing = AssetDatabase.LoadAssetAtPath<Sprite>(PlaceholderSpritePath);
            if (existing != null) return existing;

            if (!File.Exists(PlaceholderSpritePath))
            {
                string dir = Path.GetDirectoryName(PlaceholderSpritePath).Replace('\\', '/');
                ToolUtils.EnsureAssetFolder(dir);

                var tex = new Texture2D(64, 64, TextureFormat.RGBA32, false);
                var pixels = new Color32[64 * 64];
                for (int i = 0; i < pixels.Length; i++) pixels[i] = new Color32(255, 255, 255, 255);
                tex.SetPixels32(pixels);
                tex.Apply();
                byte[] png = tex.EncodeToPNG();
                UnityEngine.Object.DestroyImmediate(tex);
                File.WriteAllBytes(PlaceholderSpritePath, png);
                AssetDatabase.ImportAsset(PlaceholderSpritePath, ImportAssetOptions.ForceSynchronousImport);
            }

            // Force the exact import shape we need — a project-wide importer preset
            // can otherwise leave the texture unloadable as a Sprite.
            if (AssetImporter.GetAtPath(PlaceholderSpritePath) is TextureImporter importer)
            {
                importer.textureType = TextureImporterType.Sprite;
                importer.spriteImportMode = SpriteImportMode.Single;
                importer.spritePixelsPerUnit = 64f; // 64px square = 1 world unit — a unit-sized pickup/character
                importer.SaveAndReimport();
            }

            var sprite = AssetDatabase.LoadAssetAtPath<Sprite>(PlaceholderSpritePath);
            if (sprite == null)
                error = $"Failed to generate placeholder sprite at '{PlaceholderSpritePath}'.";
            return sprite;
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
