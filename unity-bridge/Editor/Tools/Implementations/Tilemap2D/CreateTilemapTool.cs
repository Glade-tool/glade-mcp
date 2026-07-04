using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Tilemaps;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Gameplay;

namespace GladeAgenticAI.Core.Tools.Implementations.Tilemap2D
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Creates a Grid + Tilemap + TilemapRenderer — the foundation for tile-based
    /// 2D levels. Unity's tilemap always lives as a child of a Grid, so this tool
    /// builds (or reuses via gridPath) the Grid and hangs a paintable layer under
    /// it. Multiple calls with the same gridPath stack layers (background /
    /// foreground / hazards) on one grid.
    /// </summary>
    public class CreateTilemapTool : ITool
    {
        public string Name => "create_tilemap";

        public string Execute(Dictionary<string, object> args)
        {
            string layerName = ToolUtils.GetStringArg(args, "name", "Tilemap");
            if (string.IsNullOrEmpty(layerName)) layerName = "Tilemap";
            string gridPath = ToolUtils.GetStringArg(args, "gridPath");
            string layout = ToolUtils.GetStringArg(args, "layout", "rectangular").Trim().ToLowerInvariant();
            int sortingOrder = ToolUtils.GetIntArg(args, "sortingOrder", 0);

            GameObject gridGO;
            bool createdGrid = false;

            if (!string.IsNullOrEmpty(gridPath))
            {
                gridGO = ToolUtils.FindGameObjectByPath(gridPath);
                if (gridGO == null)
                    return ToolUtils.CreateErrorResponse($"GameObject '{gridPath}' not found");
                if (gridGO.GetComponent<Grid>() == null)
                    return ToolUtils.CreateErrorResponse($"'{gridPath}' has no Grid component. Pass the Grid created by a previous create_tilemap call, or omit gridPath to create a new one.");
            }
            else
            {
                gridGO = new GameObject(GameplayScaffold.UniqueName("Grid"));
                var grid = gridGO.AddComponent<Grid>();
                createdGrid = true;

                switch (layout)
                {
                    case "isometric": grid.cellLayout = GridLayout.CellLayout.Isometric; break;
                    case "hexagonal": grid.cellLayout = GridLayout.CellLayout.Hexagon; break;
                    case "rectangular": grid.cellLayout = GridLayout.CellLayout.Rectangle; break;
                    default:
                        Object.DestroyImmediate(gridGO);
                        return ToolUtils.CreateErrorResponse($"Unknown layout '{layout}'. Use one of: rectangular, isometric, hexagonal.");
                }

                if (Physics2D.Physics2DUtils.TryGetVector2Arg(args, "cellSize", out Vector2 cellSize))
                    grid.cellSize = new Vector3(cellSize.x, cellSize.y, 0f);

                if (Physics2D.Physics2DUtils.TryGetVector2Arg(args, "position", out Vector2 position))
                    gridGO.transform.position = new Vector3(position.x, position.y, 0f);

                Undo.RegisterCreatedObjectUndo(gridGO, "Create Grid");
            }

            var layerGO = new GameObject(GameplayScaffold.UniqueName(layerName));
            layerGO.transform.SetParent(gridGO.transform, false);
            layerGO.AddComponent<Tilemap>();
            var renderer = layerGO.AddComponent<TilemapRenderer>();
            renderer.sortingOrder = sortingOrder;
            Undo.RegisterCreatedObjectUndo(layerGO, "Create Tilemap");

            try { EditorSceneManager.MarkSceneDirty(gridGO.scene); } catch { /* no open scene */ }

            var gridComponent = gridGO.GetComponent<Grid>();
            var extras = new Dictionary<string, object>
            {
                { "gridPath", ToolUtils.GetGameObjectPath(gridGO) },
                { "tilemapPath", ToolUtils.GetGameObjectPath(layerGO) },
                { "createdGrid", createdGrid },
                { "layout", gridComponent.cellLayout.ToString() },
                { "cellSize", $"{gridComponent.cellSize.x},{gridComponent.cellSize.y}" },
                { "sortingOrder", sortingOrder },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created Tilemap '{extras["tilemapPath"]}' under {(createdGrid ? "new" : "existing")} Grid '{extras["gridPath"]}'. " +
                "Paint it with set_tilemap_tiles, then make it solid with add_tilemap_collider_2d so 2D physics bodies can stand on it.",
                extras);
        }
    }
}
