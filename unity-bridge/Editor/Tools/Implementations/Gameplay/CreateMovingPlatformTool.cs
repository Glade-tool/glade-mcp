using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Adds a MOVING PLATFORM (elevator / patrolling ledge / gap-crosser) in ONE
    /// call: a flat kinematic-Rigidbody box that travels a waypoint route at constant
    /// speed and CARRIES the player standing on it. The core verticality verb of a
    /// platformer.
    ///
    /// Why a template tool: moving platforms are reliably buggy by hand — a player
    /// that slides off, a transform-driven platform the physics step never sees, or a
    /// platform that doesn't carry a CharacterController at all (Unity transfers no
    /// platform friction). The vetted MovingPlatform.cs drives a kinematic Rigidbody
    /// via MovePosition and carries the rider by parenting it while it stands on top —
    /// detected with a trigger zone the script builds for itself.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the script and
    /// builds the box + kinematic Rigidbody now, QUEUES the MovingPlatform component
    /// (with its route/speed/loopMode/waitTime) to attach on the next compile. Call
    /// repeatedly for many platforms. Currently 3D.
    /// </summary>
    public class CreateMovingPlatformTool : ITool
    {
        public string Name => "create_moving_platform";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string baseName = ToolUtils.GetStringArg(args, "name", "MovingPlatform");
            if (string.IsNullOrEmpty(baseName)) baseName = "MovingPlatform";

            float x = ToolUtils.GetFloatArg(args, "x", 0f);
            float y = ToolUtils.GetFloatArg(args, "y", 1f);
            float z = ToolUtils.GetFloatArg(args, "z", 0f);
            float width = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "width", 3f));
            float depth = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "depth", 3f));
            float thickness = Mathf.Max(0.05f, ToolUtils.GetFloatArg(args, "thickness", 0.4f));
            float speed = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "speed", 2f));
            float waitTime = Mathf.Max(0f, ToolUtils.GetFloatArg(args, "waitTime", 0f));

            string loopMode = ToolUtils.GetStringArg(args, "loopMode", "loop").ToLowerInvariant();
            if (loopMode != "loop" && loopMode != "pingpong" && loopMode != "once")
                return ToolUtils.CreateErrorResponse(
                    $"Invalid loopMode '{loopMode}'. Use one of: loop (run the route start→end→start), " +
                    "pingpong (bounce end to end), once (travel then stop).");

            string route = NormalizeRoute(ToolUtils.GetStringArg(args, "route", ""), out string routeErr);
            if (!string.IsNullOrEmpty(routeErr)) return ToolUtils.CreateErrorResponse(routeErr);

            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "MovingPlatform.cs.txt", "MovingPlatform.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // Build a flat box (placeholder art) with a kinematic Rigidbody. The
            // MovingPlatform script adds its own rider-detection trigger at runtime.
            string objName = GameplayScaffold.UniqueName(baseName);
            var go = GameObject.CreatePrimitive(PrimitiveType.Cube);
            go.name = objName;
            go.transform.position = new Vector3(x, y, z);
            go.transform.localScale = new Vector3(width, thickness, depth);

            var rb = go.GetComponent<Rigidbody>();
            if (rb == null) rb = go.AddComponent<Rigidbody>();
            rb.isKinematic = true;
            rb.useGravity = false;
            rb.interpolation = RigidbodyInterpolation.Interpolate; // smooth carry
            rb.collisionDetectionMode = CollisionDetectionMode.ContinuousSpeculative;

            Undo.RegisterCreatedObjectUndo(go, "Create Moving Platform");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    objName, null, "MovingPlatform",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("route", "string", route),
                        new PendingControllerWiring.FieldValue("speed", "float", speed.ToString(CultureInfo.InvariantCulture)),
                        new PendingControllerWiring.FieldValue("loopMode", "string", loopMode),
                        new PendingControllerWiring.FieldValue("waitTime", "float", waitTime.ToString(CultureInfo.InvariantCulture)),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(go.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            int pointCount = route.Split(';').Length;
            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "platformObject", objName },
                { "loopMode", loopMode },
                { "speed", speed },
                { "route", route },
                { "pointCount", pointCount },
                { "queuedComponents", new List<string> { $"MovingPlatform → {objName}" } },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Built a moving platform '{objName}' ({loopMode}, {pointCount} waypoints, {speed}/s). This tool is " +
                "ATOMIC: it wrote a VETTED MovingPlatform script, built a flat box with a kinematic Rigidbody, and " +
                "QUEUED the MovingPlatform component (route/speed/loopMode/waitTime) to attach as soon as scripts " +
                "compile. DO NOT call add_component. The platform CARRIES the player by parenting it while it stands " +
                "on top (a StaticBody would not), so a CharacterController or Rigidbody player rides it cleanly. " +
                "Waypoints are LOCAL offsets from where the platform is placed. Add more by calling this again (the " +
                "script is reused; each gets a unique name). Your remaining step is to call compile_scripts and wait " +
                "until status='idle'.",
                extras);
        }

        // Validate and canonicalize the route into "x,y,z;x,y,z;..." with invariant
        // decimal points. Accepts the same string back, tolerates extra whitespace,
        // and defaults to a short horizontal sweep so a bare call still moves.
        private static string NormalizeRoute(string raw, out string error)
        {
            error = "";
            if (string.IsNullOrWhiteSpace(raw)) return "0,0,0;4,0,0";

            var pts = new List<string>();
            foreach (var chunk in raw.Split(';'))
            {
                if (string.IsNullOrWhiteSpace(chunk)) continue;
                var parts = chunk.Split(',');
                if (parts.Length < 3)
                {
                    error = $"Bad route waypoint '{chunk.Trim()}' — each point needs three numbers \"x,y,z\".";
                    return null;
                }
                if (!float.TryParse(parts[0].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float px) ||
                    !float.TryParse(parts[1].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float py) ||
                    !float.TryParse(parts[2].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out float pz))
                {
                    error = $"Bad route waypoint '{chunk.Trim()}' — x,y,z must be numbers.";
                    return null;
                }
                pts.Add($"{px.ToString(CultureInfo.InvariantCulture)}," +
                        $"{py.ToString(CultureInfo.InvariantCulture)}," +
                        $"{pz.ToString(CultureInfo.InvariantCulture)}");
            }

            if (pts.Count < 2)
            {
                error = "A moving platform needs at least 2 waypoints (e.g. \"0,0,0;4,0,0\").";
                return null;
            }
            return string.Join(";", pts);
        }
    }
}
