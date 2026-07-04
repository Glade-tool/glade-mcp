using System;
using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Tilemaps;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Tilemap2D
{
    /// <summary>
    /// Paints or erases tiles on a Tilemap (pairs with create_tilemap). Cells are
    /// listed as "x,y;x,y;..." and/or filled as a rectangle — tile units, not
    /// world units. Accepts a ready TileBase asset OR a plain sprite: painting
    /// needs a Tile asset wrapping the sprite, so given a sprite the tool
    /// find-or-creates that asset next to it and reuses it on later calls.
    /// </summary>
    public class SetTilemapTilesTool : ITool
    {
        public string Name => "set_tilemap_tiles";

        private const int MaxCellsPerCall = 65536;

        public string Execute(Dictionary<string, object> args)
        {
            string tilemapPath = ToolUtils.GetStringArg(args, "tilemapPath");
            if (string.IsNullOrEmpty(tilemapPath))
                return ToolUtils.CreateErrorResponse("tilemapPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(tilemapPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{tilemapPath}' not found");

            Tilemap tilemap = obj.GetComponent<Tilemap>();
            if (tilemap == null)
                return ToolUtils.CreateErrorResponse($"'{tilemapPath}' has no Tilemap component. Pass the tilemapPath returned by create_tilemap.");

            bool erase = ToolUtils.GetBoolArg(args, "erase", false);

            // Resolve the tile to stamp (skipped when erasing).
            TileBase tile = null;
            string tileAssetPath = null;
            bool createdTileAsset = false;
            if (!erase)
            {
                string resolveError = ResolveTile(args, out tile, out tileAssetPath, out createdTileAsset);
                if (!string.IsNullOrEmpty(resolveError))
                    return ToolUtils.CreateErrorResponse(resolveError);
            }

            // Collect target cells from `cells` and/or `fillRect`.
            var targets = new List<Vector3Int>();
            string cellsRaw = ToolUtils.GetStringArg(args, "cells");
            if (!string.IsNullOrEmpty(cellsRaw))
            {
                string cellsError = ParseCells(cellsRaw, targets);
                if (!string.IsNullOrEmpty(cellsError))
                    return ToolUtils.CreateErrorResponse(cellsError);
            }

            string fillRectRaw = ToolUtils.GetStringArg(args, "fillRect");
            if (!string.IsNullOrEmpty(fillRectRaw))
            {
                string rectError = ParseFillRect(fillRectRaw, targets);
                if (!string.IsNullOrEmpty(rectError))
                    return ToolUtils.CreateErrorResponse(rectError);
            }

            if (targets.Count == 0)
                return ToolUtils.CreateErrorResponse("Nothing to paint — provide cells (\"x,y;x,y;...\") and/or fillRect (\"x,y,w,h\") in tile units.");
            if (targets.Count > MaxCellsPerCall)
                return ToolUtils.CreateErrorResponse($"{targets.Count} cells exceeds the {MaxCellsPerCall}-cell cap per call. Split into multiple calls.");

            Undo.RegisterCompleteObjectUndo(tilemap, erase ? "Erase Tiles" : "Paint Tiles");
            foreach (var cell in targets)
                tilemap.SetTile(cell, erase ? null : tile);
            if (erase)
                tilemap.CompressBounds();

            EditorUtility.SetDirty(tilemap);
            try { EditorSceneManager.MarkSceneDirty(obj.scene); } catch { /* no open scene */ }

            var bounds = tilemap.cellBounds;
            var extras = new Dictionary<string, object>
            {
                { "cellCount", targets.Count },
                { "erase", erase },
                { "bounds", $"{bounds.xMin},{bounds.yMin},{bounds.size.x},{bounds.size.y}" },
                { "usedTiles", tilemap.GetUsedTilesCount() },
            };
            if (tileAssetPath != null)
            {
                extras["tileAsset"] = tileAssetPath;
                extras["createdTileAsset"] = createdTileAsset;
            }

            string verb = erase ? "Erased" : "Painted";
            string message = $"{verb} {targets.Count} cell(s) on '{tilemapPath}'";
            if (createdTileAsset)
                message += $" (created reusable Tile asset at '{tileAssetPath}')";
            if (!erase && obj.GetComponent<TilemapCollider2D>() == null)
                message += ". The tiles are visual-only until add_tilemap_collider_2d makes them solid.";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }

        /// <summary>Resolve tilePath (a TileBase asset) or spritePath (+optional
        /// spriteName for multi-sprite sheets) into a paintable TileBase,
        /// creating a Tile asset for raw sprites.</summary>
        private static string ResolveTile(Dictionary<string, object> args, out TileBase tile, out string tileAssetPath, out bool created)
        {
            tile = null;
            tileAssetPath = null;
            created = false;

            string tilePath = ToolUtils.GetStringArg(args, "tilePath");
            string spritePath = ToolUtils.GetStringArg(args, "spritePath");

            if (!string.IsNullOrEmpty(tilePath))
            {
                tilePath = ToolUtils.NormalizeAssetPath(tilePath);
                tile = AssetDatabase.LoadAssetAtPath<TileBase>(tilePath);
                if (tile == null)
                    return $"No Tile asset found at '{tilePath}'. Pass a .asset created from a Tile, or use spritePath to create one from a sprite.";
                tileAssetPath = tilePath;
                return "";
            }

            if (string.IsNullOrEmpty(spritePath))
                return "Provide tilePath (a Tile asset) or spritePath (a sprite to wrap in a Tile asset), or set erase=true.";

            spritePath = ToolUtils.NormalizeAssetPath(spritePath);
            string spriteName = ToolUtils.GetStringArg(args, "spriteName");

            Sprite sprite = null;
            if (!string.IsNullOrEmpty(spriteName))
            {
                var names = new List<string>();
                foreach (var rep in AssetDatabase.LoadAllAssetRepresentationsAtPath(spritePath))
                {
                    if (rep is Sprite s)
                    {
                        names.Add(s.name);
                        if (s.name == spriteName) sprite = s;
                    }
                }
                if (sprite == null)
                    return $"No sprite named '{spriteName}' in '{spritePath}'. Available: {(names.Count > 0 ? string.Join(", ", names) : "none — is the texture sliced?")}.";
            }
            else
            {
                sprite = AssetDatabase.LoadAssetAtPath<Sprite>(spritePath);
                if (sprite == null)
                    return $"No sprite at '{spritePath}'. If it's a texture, import it as a Sprite first (set_sprite_import_settings); for a sliced sheet also pass spriteName.";
            }

            // Find-or-create the Tile asset next to the sprite so repeat calls reuse it.
            string dir = System.IO.Path.GetDirectoryName(spritePath).Replace('\\', '/');
            string baseName = System.IO.Path.GetFileNameWithoutExtension(spritePath);
            string suffix = string.IsNullOrEmpty(spriteName) ? "" : "_" + spriteName;
            tileAssetPath = $"{dir}/{baseName}{suffix}_Tile.asset";

            var existing = AssetDatabase.LoadAssetAtPath<Tile>(tileAssetPath);
            if (existing != null)
            {
                tile = existing;
                return "";
            }

            var newTile = ScriptableObject.CreateInstance<Tile>();
            newTile.sprite = sprite;
            newTile.colliderType = Tile.ColliderType.Sprite;
            AssetDatabase.CreateAsset(newTile, tileAssetPath);
            AssetDatabase.SaveAssets();
            tile = newTile;
            created = true;
            return "";
        }

        private static string ParseCells(string raw, List<Vector3Int> targets)
        {
            foreach (var chunk in raw.Split(';'))
            {
                if (string.IsNullOrWhiteSpace(chunk)) continue;
                string[] parts = chunk.Split(',');
                if (parts.Length < 2 ||
                    !int.TryParse(parts[0].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int x) ||
                    !int.TryParse(parts[1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int y))
                {
                    return $"Bad cell '{chunk.Trim()}' — each cell needs two integers \"x,y\" (tile units).";
                }
                targets.Add(new Vector3Int(x, y, 0));
            }
            return "";
        }

        private static string ParseFillRect(string raw, List<Vector3Int> targets)
        {
            string[] parts = raw.Split(',');
            if (parts.Length != 4 ||
                !int.TryParse(parts[0].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int x) ||
                !int.TryParse(parts[1].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int y) ||
                !int.TryParse(parts[2].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int w) ||
                !int.TryParse(parts[3].Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int h))
            {
                return $"Bad fillRect '{raw}' — expected four integers \"x,y,w,h\" (tile units).";
            }
            if (w <= 0 || h <= 0)
                return $"fillRect width/height must be positive, got {w}x{h}.";
            if ((long)w * h > MaxCellsPerCall)
                return $"fillRect {w}x{h} = {(long)w * h} cells exceeds the {MaxCellsPerCall}-cell cap per call.";

            for (int dy = 0; dy < h; dy++)
                for (int dx = 0; dx < w; dx++)
                    targets.Add(new Vector3Int(x + dx, y + dy, 0));
            return "";
        }
    }
}
