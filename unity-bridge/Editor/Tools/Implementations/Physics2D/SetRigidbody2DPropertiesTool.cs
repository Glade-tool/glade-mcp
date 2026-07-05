using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Updates an existing Rigidbody2D. Same knobs as add_rigidbody_2d; the pair
    /// mirrors the 3D add/set split so the agent never has to remove-and-re-add a
    /// body just to change its gravity scale.
    /// </summary>
    public class SetRigidbody2DPropertiesTool : ITool
    {
        public string Name => "set_rigidbody_2d_properties";

        public string Execute(Dictionary<string, object> args)
        {
            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            if (string.IsNullOrEmpty(gameObjectPath))
                return ToolUtils.CreateErrorResponse("gameObjectPath is required");

            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            Rigidbody2D rb = obj.GetComponent<Rigidbody2D>();
            if (rb == null)
                return ToolUtils.CreateErrorResponse($"No Rigidbody2D found on '{gameObjectPath}'. Use add_rigidbody_2d to add one first.");

            Undo.RecordObject(rb, "Set Rigidbody2D Properties");
            Physics2DUtils.ApplyRigidbody2DProperties(rb, args);

            var extras = Physics2DUtils.DescribeRigidbody2D(rb);
            extras["hasColliders2D"] = obj.GetComponents<Collider2D>().Length > 0;

            return ToolUtils.CreateSuccessResponse(
                $"Updated Rigidbody2D on '{gameObjectPath}' (bodyType={rb.bodyType}, gravityScale={rb.gravityScale})", extras);
        }
    }
}
