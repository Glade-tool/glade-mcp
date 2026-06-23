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
    using Camera = UnityEngine.Camera;

    /// <summary>
    /// Adds trauma-based screen shake to the camera in ONE call: writes a VETTED
    /// CameraShake script and attaches it to the main camera (found, or created if the
    /// scene has none). The other half of "juice" alongside hit VFX — a camera kick on
    /// impact/landing/death is what makes a hit feel like it connected.
    ///
    /// Why a template tool: hand-written shake is reliably bad — per-frame random
    /// jitter (reads as static), intensity-linear shake (can't be both a subtle
    /// footstep and a violent explosion), shake that never decays, and — worst —
    /// shake that fights a camera which is ALSO being moved by a follow script. The
    /// vetted CameraShake.cs is trauma-based (shake = trauma squared), smooth-noise
    /// driven, self-decaying, and RECOVERS the follow pose each frame so it layers on
    /// top of FollowCamera instead of fighting it.
    ///
    /// Trigger it from anywhere in gameplay code:
    ///     CameraShake.Shake(0.5f);   // 0..1, bigger = harder kick
    ///
    /// ATOMIC but DEFERRED: writes the script and QUEUES the CameraShake component onto
    /// the camera to attach on the next compile. Currently 3D.
    /// </summary>
    public class CreateScreenShakeTool : ITool
    {
        public string Name => "create_screen_shake";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string cameraName = ToolUtils.GetStringArg(args, "cameraName", "");
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "CameraShake.cs.txt", "CameraShake.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            var notes = new List<string>();
            GameObject cameraObj = ResolveCamera(cameraName, notes, out string camErr);
            if (!string.IsNullOrEmpty(camErr)) return ToolUtils.CreateErrorResponse(camErr);

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(cameraObj.name, null, "CameraShake", null),
            });

            try { EditorSceneManager.MarkSceneDirty(cameraObj.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "cameraObject", cameraObj.name },
                { "trigger", "CameraShake.Shake(0.5f);" },
                { "queuedComponents", new List<string> { $"CameraShake → {cameraObj.name}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added trauma-based screen shake to '{cameraObj.name}'. This tool is ATOMIC: it wrote a VETTED " +
                "CameraShake script and QUEUED the CameraShake component to attach on the next compile. DO NOT call " +
                "add_component. It composes with FollowCamera (recovers the follow pose, then layers a transient kick " +
                "on top), so it won't pin a following camera. Trigger it from gameplay code with " +
                "'CameraShake.Shake(0.5f);' (0..1) — on a hit, a death, a hard landing, or where you spawn VFX. Your " +
                "remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        // Find the main camera (by name if given, else the tagged/any Camera), or
        // create one if the scene has none — so screen shake works on a bare scene.
        private static GameObject ResolveCamera(string cameraName, List<string> notes, out string error)
        {
            error = "";

            if (!string.IsNullOrEmpty(cameraName))
            {
                var named = GameObject.Find(cameraName);
                if (named == null)
                {
                    error = $"Camera '{cameraName}' not found. Omit cameraName to use the main camera, " +
                            "or pass the name of an existing camera object.";
                    return null;
                }
                if (named.GetComponent<Camera>() == null)
                {
                    error = $"'{cameraName}' has no Camera component — screen shake must attach to a camera.";
                    return null;
                }
                return named;
            }

            if (Camera.main != null) return Camera.main.gameObject;

            var anyCam = Object.FindFirstObjectByType<Camera>();
            if (anyCam != null) return anyCam.gameObject;

            // No camera at all — scaffold one (tagged MainCamera so Camera.main resolves it).
            var go = new GameObject("Main Camera");
            go.AddComponent<Camera>();
            go.AddComponent<AudioListener>();
            try { go.tag = "MainCamera"; } catch { /* tag undefined in this project */ }
            go.transform.position = new Vector3(0f, 3f, -8f);
            go.transform.rotation = Quaternion.Euler(15f, 0f, 0f);
            Undo.RegisterCreatedObjectUndo(go, "Create Camera");
            notes.Add("created Main Camera (scene had none)");
            return go;
        }
    }
}
