using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Physics2D;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Adds one PARALLAX LAYER (distant mountains, drifting clouds, foreground
    /// bushes) in one call: a sprite under a shared "ParallaxBackground" root
    /// driven by the vetted ParallaxLayer2D script. Call once per depth band —
    /// e.g. sky 0.1, mountains 0.3, trees 0.6 — mirroring how the Godot bridge's
    /// create_parallax_2d builds one layer per call.
    ///
    /// Why a template tool: Unity has no built-in 2D parallax component, and
    /// hand-written ones either assume a fixed camera speed or tear at the seam
    /// when tiling. The vetted script follows the camera's real frame delta in
    /// LateUpdate and self-clones for seamless horizontal wrapping.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the script
    /// and builds the sprite layer now, QUEUES the ParallaxLayer2D component
    /// (with scrollFactor/autoScrollSpeed/repeatX) to attach on the next compile.
    /// Without a sprite a placeholder white square is generated so the layer is
    /// visible (tint it via `color`) until real art replaces it.
    /// </summary>
    public class CreateParallaxLayerTool : ITool
    {
        public string Name => "create_parallax_layer";

        private const string RootName = "ParallaxBackground";
        private const string PlaceholderPath = "Assets/GladeKit/Placeholders/WhiteSquare.png";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string baseName = ToolUtils.GetStringArg(args, "name", "ParallaxLayer");
            if (string.IsNullOrEmpty(baseName)) baseName = "ParallaxLayer";

            float scrollFactor = ToolUtils.GetFloatArg(args, "scrollFactor", 0.5f);
            float autoScrollSpeed = ToolUtils.GetFloatArg(args, "autoScrollSpeed", 0f);
            bool repeatX = ToolUtils.GetBoolArg(args, "repeatX", true);
            int sortingOrder = ToolUtils.GetIntArg(args, "sortingOrder", -10);
            float scale = ToolUtils.GetFloatArg(args, "scale", 1f);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Resolve the layer's sprite: explicit art, or a generated placeholder.
            bool usedPlaceholder;
            Sprite sprite = ResolveSprite(args, out string spriteError, out usedPlaceholder);
            if (!string.IsNullOrEmpty(spriteError))
                return ToolUtils.CreateErrorResponse(spriteError);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "ParallaxLayer2D.cs.txt", "ParallaxLayer2D.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // Shared root — every layer parents here so the background reads as
            // one unit in the hierarchy.
            GameObject root = GameObject.Find(RootName);
            bool createdRoot = root == null;
            if (createdRoot)
            {
                root = new GameObject(RootName);
                Undo.RegisterCreatedObjectUndo(root, "Create Parallax Root");
            }

            string objName = GameplayScaffold.UniqueName(baseName);
            var layer = new GameObject(objName);
            layer.transform.SetParent(root.transform, false);
            if (Physics2DUtils.TryGetVector2Arg(args, "position", out Vector2 position))
                layer.transform.localPosition = new Vector3(position.x, position.y, 0f);
            layer.transform.localScale = new Vector3(scale, scale, 1f);

            var renderer = layer.AddComponent<SpriteRenderer>();
            renderer.sprite = sprite;
            renderer.sortingOrder = sortingOrder;
            if (args.ContainsKey("color") && args["color"] != null)
                renderer.color = ToolUtils.ParseColor(args["color"].ToString());
            else if (usedPlaceholder)
                renderer.color = new Color(0.75f, 0.78f, 0.85f); // visible, obviously-placeholder tint

            Undo.RegisterCreatedObjectUndo(layer, "Create Parallax Layer");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    objName, null, "ParallaxLayer2D",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("scrollFactor", "float", scrollFactor.ToString(CultureInfo.InvariantCulture)),
                        new PendingControllerWiring.FieldValue("autoScrollSpeed", "float", autoScrollSpeed.ToString(CultureInfo.InvariantCulture)),
                        new PendingControllerWiring.FieldValue("repeatX", "bool", repeatX ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(layer.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "layerObject", objName },
                { "rootObject", RootName },
                { "scrollFactor", scrollFactor },
                { "repeatX", repeatX },
                { "sortingOrder", sortingOrder },
                { "usedPlaceholderSprite", usedPlaceholder },
                { "queuedComponents", new List<string> { $"ParallaxLayer2D → {objName}" } },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Built parallax layer '{objName}' (scrollFactor={scrollFactor.ToString(CultureInfo.InvariantCulture)}, " +
                $"sortingOrder={sortingOrder}). This tool is ATOMIC: it wrote a VETTED ParallaxLayer2D script, built the " +
                $"sprite layer under '{RootName}', and QUEUED the ParallaxLayer2D component to attach as soon as scripts " +
                "compile. DO NOT call add_component. scrollFactor is depth: 1 = foreground (moves with the world), " +
                "0 = infinitely far (moves with the camera). Add more layers by calling this again with different " +
                "scrollFactor/sortingOrder values. " +
                (usedPlaceholder ? "A placeholder sprite was used — swap in real art via set_object_reference or spritePath next time. " : "") +
                "Your remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        private static Sprite ResolveSprite(Dictionary<string, object> args, out string error, out bool usedPlaceholder)
        {
            error = "";
            usedPlaceholder = false;

            string spritePath = ToolUtils.GetStringArg(args, "spritePath");
            if (!string.IsNullOrEmpty(spritePath))
            {
                spritePath = ToolUtils.NormalizeAssetPath(spritePath);
                string spriteName = ToolUtils.GetStringArg(args, "spriteName");
                if (!string.IsNullOrEmpty(spriteName))
                {
                    foreach (var rep in AssetDatabase.LoadAllAssetRepresentationsAtPath(spritePath))
                        if (rep is Sprite s && s.name == spriteName)
                            return s;
                    error = $"No sprite named '{spriteName}' in '{spritePath}'.";
                    return null;
                }

                var sprite = AssetDatabase.LoadAssetAtPath<Sprite>(spritePath);
                if (sprite == null)
                {
                    error = $"No sprite at '{spritePath}'. If it's a texture, import it as a Sprite first (set_sprite_import_settings).";
                    return null;
                }
                return sprite;
            }

            return GetOrCreatePlaceholderSprite(out error, out usedPlaceholder);
        }

        /// <summary>A shared 64x64 white sprite asset so spriteless layers are
        /// still visible (tinted) instead of silently invisible. Self-healing:
        /// if the PNG exists but is mis-imported (e.g. a project preset forced
        /// spriteMode=Multiple, which yields zero sprite sub-assets), the
        /// importer is corrected and the asset reimported.</summary>
        private static Sprite GetOrCreatePlaceholderSprite(out string error, out bool created)
        {
            error = "";
            created = true; // always a placeholder from the caller's perspective

            var existing = AssetDatabase.LoadAssetAtPath<Sprite>(PlaceholderPath);
            if (existing != null)
                return existing;

            if (!System.IO.File.Exists(PlaceholderPath))
            {
                string dir = System.IO.Path.GetDirectoryName(PlaceholderPath).Replace('\\', '/');
                ToolUtils.EnsureAssetFolder(dir);

                var tex = new Texture2D(64, 64, TextureFormat.RGBA32, false);
                var pixels = new Color32[64 * 64];
                for (int i = 0; i < pixels.Length; i++) pixels[i] = new Color32(255, 255, 255, 255);
                tex.SetPixels32(pixels);
                tex.Apply();
                byte[] png = tex.EncodeToPNG();
                Object.DestroyImmediate(tex);
                System.IO.File.WriteAllBytes(PlaceholderPath, png);
                AssetDatabase.ImportAsset(PlaceholderPath, ImportAssetOptions.ForceSynchronousImport);
            }

            // Force the exact import shape we need — a project-wide importer
            // preset can otherwise leave the texture unloadable as a Sprite.
            if (AssetImporter.GetAtPath(PlaceholderPath) is TextureImporter importer)
            {
                importer.textureType = TextureImporterType.Sprite;
                importer.spriteImportMode = SpriteImportMode.Single;
                importer.spritePixelsPerUnit = 16f; // 64px square = 4 world units — a usable backdrop slab
                importer.SaveAndReimport();
            }

            var sprite = AssetDatabase.LoadAssetAtPath<Sprite>(PlaceholderPath);
            if (sprite == null)
            {
                error = $"Failed to generate placeholder sprite at '{PlaceholderPath}'.";
                created = false;
                return null;
            }
            return sprite;
        }
    }
}
