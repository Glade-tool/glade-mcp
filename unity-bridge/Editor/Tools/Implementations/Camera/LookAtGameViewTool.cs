using System;
using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Camera
{
    /// <summary>
    /// Captures the rendered game view as a PNG and returns it base64-encoded so
    /// the assistant can *see* what it built (invisible sprites, pink/missing
    /// materials, off-screen UI, dark lighting — the whole class of visual bugs
    /// that structural inspection is blind to).
    ///
    /// Read-only and edit-mode safe: it renders the active game camera into a
    /// temporary RenderTexture rather than requiring Play mode. The image rides
    /// back to the model on the "image_base64" / "image_mime" response fields;
    /// the client surfaces it as a vision input.
    /// </summary>
    public class LookAtGameViewTool : ITool
    {
        public string Name => "look_at_game_view";

        // Cap the longest edge so a base64 PNG stays a reasonable size for the
        // model's vision input (and the transport). 1280 is plenty to judge
        // composition, color, and on-screen placement.
        private const int DefaultMaxWidth = 1280;
        private const int HardMaxWidth = 2048;

        public string Execute(Dictionary<string, object> args)
        {
            int maxWidth = DefaultMaxWidth;
            if (args != null && args.ContainsKey("maxWidth") && args["maxWidth"] != null &&
                int.TryParse(
                    args["maxWidth"].ToString(),
                    NumberStyles.Integer | NumberStyles.AllowDecimalPoint,
                    CultureInfo.InvariantCulture,
                    out int parsed) && parsed > 0)
            {
                maxWidth = Mathf.Clamp(parsed, 64, HardMaxWidth);
            }

            UnityEngine.Camera cam = ResolveCamera(out string source);
            if (cam == null)
            {
                return ToolUtils.CreateErrorResponse(
                    "No camera found to capture. Add a Camera to the scene (a tagged MainCamera is ideal), " +
                    "or open the Scene/Game view, then try again.");
            }

            // Source resolution from the camera, falling back to a sane 16:9 if
            // the camera hasn't been laid out yet (can read 0 in edit mode).
            int srcW = cam.pixelWidth > 0 ? cam.pixelWidth : 1280;
            int srcH = cam.pixelHeight > 0 ? cam.pixelHeight : 720;

            int w = srcW;
            int h = srcH;
            if (w > maxWidth)
            {
                float scale = maxWidth / (float)w;
                w = maxWidth;
                h = Mathf.Max(1, Mathf.RoundToInt(srcH * scale));
            }

            RenderTexture rt = null;
            Texture2D tex = null;
            RenderTexture prevActive = RenderTexture.active;
            RenderTexture prevTarget = cam.targetTexture;
            try
            {
                rt = RenderTexture.GetTemporary(w, h, 24, RenderTextureFormat.Default);
                cam.targetTexture = rt;
                cam.Render();

                RenderTexture.active = rt;
                tex = new Texture2D(w, h, TextureFormat.RGB24, false);
                tex.ReadPixels(new Rect(0, 0, w, h), 0, 0);
                tex.Apply();

                byte[] png = tex.EncodeToPNG();
                if (png == null || png.Length == 0)
                {
                    return ToolUtils.CreateErrorResponse("Failed to encode the captured frame to PNG.");
                }

                string b64 = Convert.ToBase64String(png);
                var extras = new Dictionary<string, object>
                {
                    { "image_base64", b64 },
                    { "image_mime", "image/png" },
                    { "width", w },
                    { "height", h },
                    { "source", source },
                    { "cameraName", cam.name },
                };
                return ToolUtils.CreateSuccessResponse(
                    $"Captured the game view ({w}x{h}) from camera '{cam.name}'.", extras);
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse($"Game view capture failed: {e.Message}");
            }
            finally
            {
                cam.targetTexture = prevTarget;
                RenderTexture.active = prevActive;
                if (rt != null) RenderTexture.ReleaseTemporary(rt);
                if (tex != null) UnityEngine.Object.DestroyImmediate(tex);
            }
        }

        /// <summary>
        /// Picks the camera whose view best represents "the game": the tagged
        /// MainCamera, else any enabled rendering camera, else the active Scene
        /// view's camera as a last resort so the tool still returns something
        /// useful in a scene with no game camera yet.
        /// </summary>
        private static UnityEngine.Camera ResolveCamera(out string source)
        {
            if (UnityEngine.Camera.main != null)
            {
                source = "main_camera";
                return UnityEngine.Camera.main;
            }

            UnityEngine.Camera[] all = UnityEngine.Camera.allCameras;
            if (all != null && all.Length > 0)
            {
                source = "scene_camera";
                return all[0];
            }

            if (SceneView.lastActiveSceneView != null && SceneView.lastActiveSceneView.camera != null)
            {
                source = "editor_scene_view";
                return SceneView.lastActiveSceneView.camera;
            }

            source = "none";
            return null;
        }
    }
}
