using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Tilemaps;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Tilemap2D
{
    /// <summary>
    /// Makes a painted Tilemap SOLID. A tilemap is purely visual until this runs —
    /// a Rigidbody2D player falls straight through the floor, which is the single
    /// most common "my platformer is broken" report. composite=true merges
    /// per-tile boxes into clean outlines (fewer ghost-collision seams, better
    /// performance); oneWay=true makes platforms a player can jump up through and
    /// land on.
    /// </summary>
    public class AddTilemapCollider2DTool : ITool
    {
        public string Name => "add_tilemap_collider_2d";

        public string Execute(Dictionary<string, object> args)
        {
            string tilemapPath = ToolUtils.GetStringArg(args, "tilemapPath");
            if (string.IsNullOrEmpty(tilemapPath))
                return ToolUtils.CreateErrorResponse("tilemapPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(tilemapPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{tilemapPath}' not found");

            if (obj.GetComponent<Tilemap>() == null)
                return ToolUtils.CreateErrorResponse($"'{tilemapPath}' has no Tilemap component. Pass the tilemapPath returned by create_tilemap.");
            if (obj.GetComponent<TilemapCollider2D>() != null)
                return ToolUtils.CreateErrorResponse($"'{tilemapPath}' already has a TilemapCollider2D. Use set_collider_2d_properties to modify it.");

            bool composite = ToolUtils.GetBoolArg(args, "composite", false);
            bool isTrigger = ToolUtils.GetBoolArg(args, "isTrigger", false);
            bool oneWay = ToolUtils.GetBoolArg(args, "oneWay", false);

            var warnings = new List<string>();
            var addedComponents = new List<string> { "TilemapCollider2D" };

            TilemapCollider2D tmCollider = Undo.AddComponent<TilemapCollider2D>(obj);
            Collider2D effectiveCollider = tmCollider;

            if (composite)
            {
                // A CompositeCollider2D requires a Rigidbody2D on the same object;
                // Static keeps the merged level geometry immovable.
                Rigidbody2D rb = obj.GetComponent<Rigidbody2D>();
                if (rb == null)
                {
                    rb = Undo.AddComponent<Rigidbody2D>(obj);
                    addedComponents.Add("Rigidbody2D (Static)");
                }
                else
                {
                    Undo.RecordObject(rb, "Configure Tilemap Rigidbody2D");
                }
                rb.bodyType = RigidbodyType2D.Static;

                CompositeCollider2D compositeCollider = Undo.AddComponent<CompositeCollider2D>(obj);
                addedComponents.Add("CompositeCollider2D");
                tmCollider.compositeOperation = Collider2D.CompositeOperation.Merge;
                effectiveCollider = compositeCollider;
            }

            effectiveCollider.isTrigger = isTrigger;

            if (oneWay)
            {
                if (isTrigger)
                {
                    warnings.Add("WARNING: oneWay has no effect on a trigger — triggers never block movement. Dropping isTrigger or oneWay is needed for one to apply.");
                }
                var effector = Undo.AddComponent<PlatformEffector2D>(obj);
                effector.useOneWay = true;
                effectiveCollider.usedByEffector = true;
                addedComponents.Add("PlatformEffector2D (one-way)");
            }

            try { EditorSceneManager.MarkSceneDirty(obj.scene); } catch { /* no open scene */ }

            var extras = new Dictionary<string, object>
            {
                { "tilemapPath", tilemapPath },
                { "composite", composite },
                { "isTrigger", isTrigger },
                { "oneWay", oneWay },
                { "addedComponents", addedComponents },
            };
            if (warnings.Count > 0)
                extras["warnings"] = warnings;

            string message = isTrigger
                ? $"Added trigger TilemapCollider2D to '{tilemapPath}' — tiles report overlaps but do not block movement"
                : $"Tiles on '{tilemapPath}' are now solid — 2D physics bodies collide with every painted cell";
            if (oneWay && !isTrigger)
                message += " (one-way: players can jump up through and land on top)";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
