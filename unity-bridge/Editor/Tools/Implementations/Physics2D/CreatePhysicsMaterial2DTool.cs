using System;
using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Creates a PhysicsMaterial2D asset (friction + bounciness — 2D has no combine
    /// modes) and optionally assigns it to every Collider2D on a GameObject in the
    /// same call, since create-then-assign is the only reason the asset exists.
    /// </summary>
    public class CreatePhysicsMaterial2DTool : ITool
    {
        public string Name => "create_physics_material_2d";

        public string Execute(Dictionary<string, object> args)
        {
            string materialPath = ToolUtils.GetStringArg(args, "materialPath");
            if (string.IsNullOrEmpty(materialPath))
                return ToolUtils.CreateErrorResponse("materialPath is required");

            if (!materialPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                materialPath = "Assets/" + materialPath;
            if (!materialPath.EndsWith(".physicsMaterial2D", StringComparison.OrdinalIgnoreCase))
                materialPath += ".physicsMaterial2D";

            var existing = AssetDatabase.LoadAssetAtPath<PhysicsMaterial2D>(materialPath);
            if (existing != null)
                return ToolUtils.CreateErrorResponse($"PhysicsMaterial2D already exists at '{materialPath}'. Use a different path or delete the existing asset first.");

            string dir = System.IO.Path.GetDirectoryName(materialPath);
            if (!AssetDatabase.IsValidFolder(dir))
                ToolUtils.EnsureAssetFolder(dir);

            var mat = new PhysicsMaterial2D(System.IO.Path.GetFileNameWithoutExtension(materialPath));
            if (args.ContainsKey("friction") && float.TryParse(args["friction"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float friction))
                mat.friction = friction;
            if (args.ContainsKey("bounciness") && float.TryParse(args["bounciness"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float bounciness))
                mat.bounciness = bounciness;

            AssetDatabase.CreateAsset(mat, materialPath);
            AssetDatabase.SaveAssets();

            var extras = new Dictionary<string, object>
            {
                { "materialPath", materialPath },
                { "friction", mat.friction },
                { "bounciness", mat.bounciness },
            };

            string message = $"Created PhysicsMaterial2D at '{materialPath}' (friction={mat.friction}, bounciness={mat.bounciness})";

            // Optional immediate assignment — the common follow-up folded in.
            string assignTo = ToolUtils.GetStringArg(args, "assignTo");
            if (!string.IsNullOrEmpty(assignTo))
            {
                UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(assignTo);
                if (obj == null)
                {
                    extras["assignWarning"] = $"GameObject '{assignTo}' not found — material created but not assigned.";
                }
                else
                {
                    Collider2D[] colliders = obj.GetComponents<Collider2D>();
                    if (colliders.Length == 0)
                    {
                        extras["assignWarning"] = $"'{assignTo}' has no Collider2D — material created but not assigned. Add one with create_collider_2d.";
                    }
                    else
                    {
                        foreach (var col in colliders)
                        {
                            Undo.RecordObject(col, "Assign PhysicsMaterial2D");
                            col.sharedMaterial = mat;
                        }
                        extras["assignedTo"] = assignTo;
                        extras["assignedColliderCount"] = colliders.Length;
                        message += $", assigned to {colliders.Length} collider(s) on '{assignTo}'";
                    }
                }
            }

            return ToolUtils.CreateSuccessResponse(message, extras);
        }
    }
}
