using System.Collections.Generic;
using System.Globalization;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Physics2D
{
    /// <summary>
    /// Shared parsing/formatting helpers for the 2D physics tools. 2D physics is a
    /// separate simulation from 3D (Rigidbody2D/Collider2D never interact with
    /// Rigidbody/Collider), so these tools warn whenever the two worlds are mixed
    /// on one GameObject — the classic silent failure for 2D beginners.
    /// </summary>
    internal static class Physics2DUtils
    {
        /// <summary>Apply shared Rigidbody2D args (used by add + set tools).</summary>
        public static void ApplyRigidbody2DProperties(Rigidbody2D rb, Dictionary<string, object> args)
        {
            if (args.ContainsKey("bodyType"))
            {
                string bt = args["bodyType"].ToString().Trim().ToLowerInvariant();
                switch (bt)
                {
                    case "dynamic":   rb.bodyType = RigidbodyType2D.Dynamic;   break;
                    case "kinematic": rb.bodyType = RigidbodyType2D.Kinematic; break;
                    case "static":    rb.bodyType = RigidbodyType2D.Static;    break;
                }
            }

            if (args.ContainsKey("mass") && float.TryParse(args["mass"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float mass))
                rb.mass = mass;
            if (args.ContainsKey("gravityScale") && float.TryParse(args["gravityScale"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float gravityScale))
                rb.gravityScale = gravityScale;
            if (args.ContainsKey("linearDrag") && float.TryParse(args["linearDrag"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float linearDrag))
                rb.linearDamping = linearDrag;
            if (args.ContainsKey("angularDrag") && float.TryParse(args["angularDrag"].ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out float angularDrag))
                rb.angularDamping = angularDrag;

            // Constraints are additive flags; freezeRotation is the one nearly every
            // 2D character needs (sprites tipping over is the #1 beginner surprise).
            if (args.ContainsKey("freezeRotation"))
            {
                bool freeze = ToolUtils.ParseBool(args["freezeRotation"]);
                if (freeze) rb.constraints |= RigidbodyConstraints2D.FreezeRotation;
                else        rb.constraints &= ~RigidbodyConstraints2D.FreezeRotation;
            }
            if (args.ContainsKey("freezePositionX"))
            {
                bool freeze = ToolUtils.ParseBool(args["freezePositionX"]);
                if (freeze) rb.constraints |= RigidbodyConstraints2D.FreezePositionX;
                else        rb.constraints &= ~RigidbodyConstraints2D.FreezePositionX;
            }
            if (args.ContainsKey("freezePositionY"))
            {
                bool freeze = ToolUtils.ParseBool(args["freezePositionY"]);
                if (freeze) rb.constraints |= RigidbodyConstraints2D.FreezePositionY;
                else        rb.constraints &= ~RigidbodyConstraints2D.FreezePositionY;
            }

            if (args.ContainsKey("collisionDetection"))
            {
                string cd = args["collisionDetection"].ToString().Trim().ToLowerInvariant();
                if (cd == "continuous") rb.collisionDetectionMode = CollisionDetectionMode2D.Continuous;
                else if (cd == "discrete") rb.collisionDetectionMode = CollisionDetectionMode2D.Discrete;
            }
            if (args.ContainsKey("interpolation"))
            {
                string interp = args["interpolation"].ToString().Trim().ToLowerInvariant();
                if (interp == "interpolate") rb.interpolation = RigidbodyInterpolation2D.Interpolate;
                else if (interp == "extrapolate") rb.interpolation = RigidbodyInterpolation2D.Extrapolate;
                else if (interp == "none") rb.interpolation = RigidbodyInterpolation2D.None;
            }
        }

        /// <summary>Response extras describing a Rigidbody2D's current state.</summary>
        public static Dictionary<string, object> DescribeRigidbody2D(Rigidbody2D rb)
        {
            return new Dictionary<string, object>
            {
                ["bodyType"] = rb.bodyType.ToString(),
                ["mass"] = rb.mass,
                ["gravityScale"] = rb.gravityScale,
                ["linearDrag"] = rb.linearDamping,
                ["angularDrag"] = rb.angularDamping,
                ["freezeRotation"] = (rb.constraints & RigidbodyConstraints2D.FreezeRotation) != 0,
                ["collisionDetection"] = rb.collisionDetectionMode.ToString(),
                ["interpolation"] = rb.interpolation.ToString(),
            };
        }

        /// <summary>Type-specific property snapshot for any Collider2D.</summary>
        public static Dictionary<string, object> DescribeCollider2D(Collider2D col)
        {
            var props = new Dictionary<string, object>
            {
                ["colliderType"] = col.GetType().Name,
                ["isTrigger"] = col.isTrigger,
                ["enabled"] = col.enabled,
                ["offset"] = $"{col.offset.x},{col.offset.y}",
            };
            if (col.sharedMaterial != null)
                props["physicsMaterial"] = col.sharedMaterial.name;

            switch (col)
            {
                case BoxCollider2D box:
                    props["size"] = $"{box.size.x},{box.size.y}";
                    break;
                case CircleCollider2D circle:
                    props["radius"] = circle.radius;
                    break;
                case CapsuleCollider2D capsule:
                    props["size"] = $"{capsule.size.x},{capsule.size.y}";
                    props["direction"] = capsule.direction.ToString();
                    break;
                case PolygonCollider2D polygon:
                    props["pathCount"] = polygon.pathCount;
                    props["pointCount"] = polygon.GetTotalPointCount();
                    break;
                case EdgeCollider2D edge:
                    props["pointCount"] = edge.pointCount;
                    break;
            }
            return props;
        }

        /// <summary>
        /// Names the 3D physics component that makes Unity REFUSE a 2D physics
        /// add on this GameObject (AddComponent returns null), or null when the
        /// object is clean. Unity hard-blocks mixing 2D and 3D physics on one
        /// GameObject, so this feeds the blocked-add error message.
        /// </summary>
        public static string Describe3DPhysicsBlocker(UnityEngine.GameObject obj)
        {
            if (obj.GetComponent<Rigidbody>() != null) return "a 3D Rigidbody";
            var collider3D = obj.GetComponent<Collider>();
            if (collider3D != null) return $"a 3D {collider3D.GetType().Name}";
            return null;
        }

        /// <summary>
        /// Parse an "x,y" arg into a Vector2, returning false when the key is
        /// absent or malformed (malformed values are ignored, matching the
        /// defensive style of the 3D tools).
        /// </summary>
        public static bool TryGetVector2Arg(Dictionary<string, object> args, string key, out Vector2 value)
        {
            value = Vector2.zero;
            if (!args.ContainsKey(key) || args[key] == null) return false;
            string raw = args[key].ToString();
            if (string.IsNullOrWhiteSpace(raw)) return false;
            string[] parts = raw.Split(',');
            if (parts.Length < 2) return false;
            if (!float.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float x)) return false;
            if (!float.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float y)) return false;
            value = new Vector2(x, y);
            return true;
        }

        /// <summary>
        /// Parse a "x,y;x,y;..." point list (same delimiter convention as the
        /// scaffolders' waypoint routes). Returns null with an error set on
        /// malformed input.
        /// </summary>
        public static List<Vector2> ParsePointList(string raw, out string error)
        {
            error = "";
            var points = new List<Vector2>();
            if (string.IsNullOrWhiteSpace(raw)) return points;
            foreach (var chunk in raw.Split(';'))
            {
                if (string.IsNullOrWhiteSpace(chunk)) continue;
                string[] parts = chunk.Split(',');
                if (parts.Length < 2 ||
                    !float.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float x) ||
                    !float.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float y))
                {
                    error = $"Bad point '{chunk.Trim()}' — each point needs two numbers \"x,y\".";
                    return null;
                }
                points.Add(new Vector2(x, y));
            }
            return points;
        }
    }
}
