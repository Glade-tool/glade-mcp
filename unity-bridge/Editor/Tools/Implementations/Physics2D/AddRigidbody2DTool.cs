using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Adds a Rigidbody2D — the 2D physics body (platformer characters, falling
    /// crates, projectiles). Mirrors AddRigidbodyTool for the 2D simulation, with
    /// the 2D-specific knobs (bodyType, gravityScale, freezeRotation) surfaced
    /// directly because they are what every 2D game touches first.
    /// </summary>
    public class AddRigidbody2DTool : ITool
    {
        public string Name => "add_rigidbody_2d";

        public string Execute(Dictionary<string, object> args)
        {
            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            if (string.IsNullOrEmpty(gameObjectPath))
                return ToolUtils.CreateErrorResponse("gameObjectPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            if (obj.GetComponent<Rigidbody2D>() != null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' already has a Rigidbody2D. Use set_rigidbody_2d_properties to modify it instead.");

            var warnings = Physics2DUtils.CollectMixedPhysicsWarnings(obj);
            bool hasColliders2D = obj.GetComponents<Collider2D>().Length > 0;
            if (!hasColliders2D)
                warnings.Add("INFO: GameObject has no Collider2D. Add one with create_collider_2d or the body will fall without colliding.");

            Rigidbody2D rb = Undo.AddComponent<Rigidbody2D>(obj);
            Physics2DUtils.ApplyRigidbody2DProperties(rb, args);

            var extras = Physics2DUtils.DescribeRigidbody2D(rb);
            extras["hasColliders2D"] = hasColliders2D;
            if (warnings.Count > 0)
                extras["warnings"] = warnings;

            string message = $"Added Rigidbody2D to '{gameObjectPath}' (bodyType={rb.bodyType}, gravityScale={rb.gravityScale})";
            if (warnings.Count > 0)
                message += ". See warnings in response.";

            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
