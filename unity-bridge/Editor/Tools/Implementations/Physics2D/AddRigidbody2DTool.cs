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

            // Unity hard-blocks 2D physics components on objects with 3D
            // physics — refuse up front with the reason instead of letting
            // AddComponent return null.
            string blocker = Physics2DUtils.Describe3DPhysicsBlocker(obj);
            if (blocker != null)
                return ToolUtils.CreateErrorResponse(
                    $"Could not add a Rigidbody2D to '{gameObjectPath}' — it has {blocker}, and Unity blocks mixing 2D and 3D physics on one GameObject. " +
                    "Remove the 3D component with remove_component, or put the 2D body on a separate GameObject (the two simulations never interact).");

            var warnings = new List<string>();
            bool hasColliders2D = obj.GetComponents<Collider2D>().Length > 0;
            if (!hasColliders2D)
                warnings.Add("INFO: GameObject has no Collider2D. Add one with create_collider_2d or the body will fall without colliding.");

            Rigidbody2D rb = Undo.AddComponent<Rigidbody2D>(obj);
            if (rb == null)
                return ToolUtils.CreateErrorResponse($"Could not add a Rigidbody2D to '{gameObjectPath}' — Unity rejected the component (check the Console for details).");
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
