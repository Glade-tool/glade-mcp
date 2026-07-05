using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Adds a Collider2D. Box/Circle/Capsule auto-fit the attached sprite's bounds
    /// (Unity's own Reset behavior, made explicit and overridable); Polygon traces
    /// the sprite's physics shape; Edge takes an explicit point list for ground
    /// lines. The 2D counterpart of CreateColliderTool.
    /// </summary>
    public class CreateCollider2DTool : ITool
    {
        public string Name => "create_collider_2d";

        public string Execute(Dictionary<string, object> args)
        {
            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            if (string.IsNullOrEmpty(gameObjectPath))
                return ToolUtils.CreateErrorResponse("gameObjectPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            string colliderType = ToolUtils.GetStringArg(args, "colliderType", "Box").Trim().ToLowerInvariant();

            // Unity hard-blocks 2D physics components on objects with 3D
            // physics — refuse up front with the reason instead of letting
            // AddComponent return null.
            string blocker = Physics2DUtils.Describe3DPhysicsBlocker(obj);
            if (blocker != null)
                return ToolUtils.CreateErrorResponse(
                    $"Could not add a {colliderType} Collider2D to '{gameObjectPath}' — it has {blocker}, and Unity blocks mixing 2D and 3D physics on one GameObject. " +
                    "Remove the 3D component with remove_component, or put the 2D collider on a separate GameObject (the two simulations never interact).");

            Collider2D collider;
            switch (colliderType)
            {
                case "box":
                    if (obj.GetComponent<BoxCollider2D>() != null)
                        return AlreadyExists(gameObjectPath, "BoxCollider2D");
                    collider = Undo.AddComponent<BoxCollider2D>(obj);
                    break;
                case "circle":
                    if (obj.GetComponent<CircleCollider2D>() != null)
                        return AlreadyExists(gameObjectPath, "CircleCollider2D");
                    collider = Undo.AddComponent<CircleCollider2D>(obj);
                    break;
                case "capsule":
                    if (obj.GetComponent<CapsuleCollider2D>() != null)
                        return AlreadyExists(gameObjectPath, "CapsuleCollider2D");
                    collider = Undo.AddComponent<CapsuleCollider2D>(obj);
                    break;
                case "polygon":
                    if (obj.GetComponent<PolygonCollider2D>() != null)
                        return AlreadyExists(gameObjectPath, "PolygonCollider2D");
                    collider = Undo.AddComponent<PolygonCollider2D>(obj);
                    break;
                case "edge":
                    if (obj.GetComponent<EdgeCollider2D>() != null)
                        return AlreadyExists(gameObjectPath, "EdgeCollider2D");
                    collider = Undo.AddComponent<EdgeCollider2D>(obj);
                    break;
                default:
                    return ToolUtils.CreateErrorResponse($"Unknown colliderType '{colliderType}'. Supported: Box, Circle, Capsule, Polygon, Edge.");
            }

            if (collider == null)
                return ToolUtils.CreateErrorResponse($"Could not add a {colliderType} Collider2D to '{gameObjectPath}' — Unity rejected the component (check the Console for details).");

            ApplyCollider2DArgs(collider, args, out string applyError);
            if (!string.IsNullOrEmpty(applyError))
                return ToolUtils.CreateErrorResponse(applyError);

            var extras = Physics2DUtils.DescribeCollider2D(collider);
            bool hasRigidbody2D = obj.GetComponent<Rigidbody2D>() != null;
            extras["hasRigidbody2D"] = hasRigidbody2D;

            string message = $"Added {collider.GetType().Name} to '{gameObjectPath}'";
            var sr = obj.GetComponent<SpriteRenderer>();
            if (sr != null && sr.sprite != null && !args.ContainsKey("size") && !args.ContainsKey("radius") && !args.ContainsKey("points"))
                message += " (auto-fitted to the sprite)";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }

        private static string AlreadyExists(string path, string type) =>
            ToolUtils.CreateErrorResponse($"GameObject '{path}' already has a {type}. Use set_collider_2d_properties to modify it instead.");

        internal static void ApplyCollider2DArgs(Collider2D collider, Dictionary<string, object> args, out string error)
        {
            error = "";

            if (args.ContainsKey("isTrigger"))
                collider.isTrigger = ToolUtils.ParseBool(args["isTrigger"]);
            if (Physics2DUtils.TryGetVector2Arg(args, "offset", out Vector2 offset))
                collider.offset = offset;

            switch (collider)
            {
                case BoxCollider2D box:
                    if (Physics2DUtils.TryGetVector2Arg(args, "size", out Vector2 boxSize))
                        box.size = boxSize;
                    break;
                case CircleCollider2D circle:
                    if (args.ContainsKey("radius") &&
                        float.TryParse(args["radius"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float radius))
                        circle.radius = radius;
                    break;
                case CapsuleCollider2D capsule:
                    if (Physics2DUtils.TryGetVector2Arg(args, "size", out Vector2 capsuleSize))
                        capsule.size = capsuleSize;
                    if (args.ContainsKey("direction"))
                    {
                        string dir = args["direction"].ToString().Trim().ToLowerInvariant();
                        if (dir == "horizontal") capsule.direction = CapsuleDirection2D.Horizontal;
                        else if (dir == "vertical") capsule.direction = CapsuleDirection2D.Vertical;
                    }
                    break;
                case PolygonCollider2D polygon:
                    if (args.ContainsKey("points"))
                    {
                        var points = Physics2DUtils.ParsePointList(args["points"].ToString(), out string polyErr);
                        if (points == null) { error = polyErr; return; }
                        if (points.Count >= 3) polygon.SetPath(0, points.ToArray());
                        else if (points.Count > 0) { error = "A polygon path needs at least 3 points."; return; }
                    }
                    break;
                case EdgeCollider2D edge:
                    if (args.ContainsKey("points"))
                    {
                        var points = Physics2DUtils.ParsePointList(args["points"].ToString(), out string edgeErr);
                        if (points == null) { error = edgeErr; return; }
                        if (points.Count >= 2) edge.points = points.ToArray();
                        else if (points.Count > 0) { error = "An edge needs at least 2 points."; return; }
                    }
                    break;
            }
        }
    }
}
