using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Updates an existing Collider2D. When a GameObject carries several 2D
    /// colliders (body box + attack trigger is a common pair), the optional
    /// colliderType arg picks which one; otherwise the first collider is edited
    /// and the response says so.
    /// </summary>
    public class SetCollider2DPropertiesTool : ITool
    {
        public string Name => "set_collider_2d_properties";

        public string Execute(Dictionary<string, object> args)
        {
            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            if (string.IsNullOrEmpty(gameObjectPath))
                return ToolUtils.CreateErrorResponse("gameObjectPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            Collider2D[] colliders = obj.GetComponents<Collider2D>();
            if (colliders.Length == 0)
                return ToolUtils.CreateErrorResponse($"No Collider2D found on '{gameObjectPath}'. Use create_collider_2d to add one first.");

            Collider2D target;
            string typeFilter = ToolUtils.GetStringArg(args, "colliderType", "").Trim().ToLowerInvariant();
            if (!string.IsNullOrEmpty(typeFilter))
            {
                target = colliders.FirstOrDefault(c =>
                    c.GetType().Name.ToLowerInvariant().StartsWith(typeFilter));
                if (target == null)
                {
                    var available = string.Join(", ", colliders.Select(c => c.GetType().Name));
                    return ToolUtils.CreateErrorResponse($"No {typeFilter} Collider2D on '{gameObjectPath}'. Present: {available}.");
                }
            }
            else
            {
                target = colliders[0];
            }

            Undo.RecordObject(target, "Set Collider2D Properties");
            CreateCollider2DTool.ApplyCollider2DArgs(target, args, out string applyError);
            if (!string.IsNullOrEmpty(applyError))
                return ToolUtils.CreateErrorResponse(applyError);

            var extras = Physics2DUtils.DescribeCollider2D(target);
            if (colliders.Length > 1)
            {
                extras["otherColliders2D"] = colliders.Where(c => c != target).Select(c => c.GetType().Name).ToList();
                if (string.IsNullOrEmpty(typeFilter))
                    extras["note"] = $"GameObject has {colliders.Length} Collider2D components; edited the first ({target.GetType().Name}). Pass colliderType to pick a specific one.";
            }

            return ToolUtils.CreateSuccessResponse(
                $"Updated {target.GetType().Name} on '{gameObjectPath}' (isTrigger={target.isTrigger})", extras);
        }
    }
}
