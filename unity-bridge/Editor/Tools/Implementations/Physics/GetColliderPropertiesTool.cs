using System.Collections.Generic;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics
{
    /// <summary>
    /// Gets detailed information about a Collider component including type-specific properties.
    /// Delegates type-specific property reading to the ColliderHandlerRegistry.
    /// </summary>
    public class GetColliderPropertiesTool : ITool
    {
        public string Name => "get_collider_properties";

        public string Execute(Dictionary<string, object> args)
        {
            string gameObjectPath = args.ContainsKey("gameObjectPath") ? args["gameObjectPath"].ToString() : "";

            if (string.IsNullOrEmpty(gameObjectPath))
                return ToolUtils.CreateErrorResponse("gameObjectPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            Collider collider = obj.GetComponent<Collider>();
            if (collider == null)
            {
                // 2D fallback — same tool name serves both simulations for reads.
                Collider2D[] colliders2D = obj.GetComponents<Collider2D>();
                if (colliders2D.Length > 0)
                    return Describe2D(gameObjectPath, colliders2D);
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' has neither a Collider nor a Collider2D component");
            }

            // Base properties common to all colliders
            var properties = new Dictionary<string, object>
            {
                ["gameObjectPath"] = gameObjectPath,
                ["colliderType"]   = collider.GetType().Name,
                ["isTrigger"]      = collider.isTrigger,
                ["enabled"]        = collider.enabled
            };

            // Delegate type-specific properties to the handler
            string typeKey = collider.GetType().Name.Replace("Collider", "");
            if (ColliderHandlerRegistry.TryGet(typeKey, out var handler))
            {
                var typeProps = handler.ReadProperties(collider);
                foreach (var kv in typeProps)
                    properties[kv.Key] = kv.Value;
            }

            // Conflict info
            var conflictInfo = ToolUtils.CheckColliderConflicts(obj);
            bool hasCharacterController = conflictInfo.ContainsKey("hasCharacterController") && conflictInfo["hasCharacterController"] is bool hasCC && hasCC;
            var existingColliders = conflictInfo.ContainsKey("existingColliders") ? conflictInfo["existingColliders"] as List<string> : new List<string>();
            bool hasConflicts = conflictInfo.ContainsKey("isConflicted") && conflictInfo["isConflicted"] is bool c && c;

            if (hasConflicts)
            {
                if (hasCharacterController) properties["hasCharacterController"] = true;
                if (existingColliders.Count > 1)
                {
                    properties["otherColliders"] = existingColliders;
                    properties["warning"] = "GameObject has multiple colliders or conflicts with CharacterController.";
                }
            }

            return ToolUtils.CreateSuccessResponse(
                $"Retrieved collider properties for '{gameObjectPath}': Type={collider.GetType().Name}, IsTrigger={collider.isTrigger}",
                properties);
        }

        private static string Describe2D(string gameObjectPath, Collider2D[] colliders2D)
        {
            var described = new List<object>();
            foreach (var col in colliders2D)
                described.Add(Physics2D.Physics2DUtils.DescribeCollider2D(col));

            var properties = new Dictionary<string, object>
            {
                ["gameObjectPath"] = gameObjectPath,
                ["is2D"] = true,
                ["count"] = colliders2D.Length,
                ["colliders2D"] = described,
            };

            return ToolUtils.CreateSuccessResponse(
                $"Retrieved {colliders2D.Length} Collider2D component(s) for '{gameObjectPath}': " +
                $"{string.Join(", ", System.Array.ConvertAll(colliders2D, c => c.GetType().Name))}",
                properties);
        }
    }
}
