using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Tilemaps;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Tilemap2D
{
    /// <summary>
    /// Read-only snapshot of a tile level: grid layout/cell size plus, per layer,
    /// the painted bounds, tile count, sorting order, and whether it has a
    /// collider yet. Accepts either a Grid path (describes every layer under it)
    /// or a single Tilemap path.
    /// </summary>
    public class GetTilemapInfoTool : ITool
    {
        public string Name => "get_tilemap_info";

        public string Execute(Dictionary<string, object> args)
        {
            string tilemapPath = ToolUtils.GetStringArg(args, "tilemapPath");
            if (string.IsNullOrEmpty(tilemapPath))
                return ToolUtils.CreateErrorResponse("tilemapPath is required (a Grid or Tilemap path)");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(tilemapPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{tilemapPath}' not found");

            Grid grid = obj.GetComponent<Grid>();
            Tilemap[] tilemaps;
            if (grid != null)
            {
                tilemaps = obj.GetComponentsInChildren<Tilemap>();
            }
            else
            {
                Tilemap single = obj.GetComponent<Tilemap>();
                if (single == null)
                    return ToolUtils.CreateErrorResponse($"'{tilemapPath}' has neither a Grid nor a Tilemap component");
                tilemaps = new[] { single };
                grid = obj.GetComponentInParent<Grid>();
            }

            var layers = new List<object>();
            foreach (var tm in tilemaps)
            {
                var bounds = tm.cellBounds;
                var renderer = tm.GetComponent<TilemapRenderer>();
                layers.Add(new Dictionary<string, object>
                {
                    ["path"] = ToolUtils.GetGameObjectPath(tm.gameObject),
                    ["usedTiles"] = tm.GetUsedTilesCount(),
                    ["bounds"] = $"{bounds.xMin},{bounds.yMin},{bounds.size.x},{bounds.size.y}",
                    ["sortingOrder"] = renderer != null ? renderer.sortingOrder : 0,
                    ["hasCollider"] = tm.GetComponent<TilemapCollider2D>() != null,
                    ["hasCompositeCollider"] = tm.GetComponent<CompositeCollider2D>() != null,
                });
            }

            var extras = new Dictionary<string, object>
            {
                ["count"] = layers.Count,
                ["tilemaps"] = layers,
            };
            if (grid != null)
            {
                extras["gridPath"] = ToolUtils.GetGameObjectPath(grid.gameObject);
                extras["layout"] = grid.cellLayout.ToString();
                extras["cellSize"] = $"{grid.cellSize.x},{grid.cellSize.y}";
            }

            return ToolUtils.CreateSuccessResponse(
                $"Found {layers.Count} tilemap layer(s){(grid != null ? $" on grid '{extras["gridPath"]}'" : "")}",
                extras);
        }
    }
}
