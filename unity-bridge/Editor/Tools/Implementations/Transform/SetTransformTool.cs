using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Transform
{
    /// <summary>
    /// Shared implementation for set_transform and set_local_transform. The two
    /// tools differ only in whether they operate on world-space transform
    /// properties (position/rotation) or local-space ones (localPosition/
    /// localRotation). Scale is always local in Unity, so both share that path.
    ///
    /// Centralizing this logic eliminates the ~150 lines of near-duplicate code
    /// that previously lived in SetTransformTool + SetLocalTransformTool. Bug
    /// fixes to the operation dispatch ("set"/"add"/"multiply") now happen in
    /// one place.
    /// </summary>
    internal static class TransformToolCore
    {
        public static string Execute(Dictionary<string, object> args, bool isLocal, string toolDisplay)
        {
            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            UnityEngine.GameObject obj = ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            UnityEngine.Transform t = obj.transform;

            // Capture previous state for revert
            Vector3 prevPos = isLocal ? t.localPosition : t.position;
            Vector3 prevRot = isLocal ? t.localRotation.eulerAngles : t.rotation.eulerAngles;
            Vector3 prevScale = t.localScale;

            string operation = ToolUtils.GetStringArg(args, "operation", "set");

            Undo.RecordObject(t, $"{toolDisplay}: {gameObjectPath}");

            if (ToolUtils.HasArg(args, "position"))
            {
                Vector3 pos = ToolUtils.ParseVector3(args["position"].ToString());
                Vector3 current = isLocal ? t.localPosition : t.position;
                Vector3 next = operation switch
                {
                    "add" => current + pos,
                    "multiply" => new Vector3(current.x * pos.x, current.y * pos.y, current.z * pos.z),
                    _ => pos
                };
                if (isLocal) t.localPosition = next; else t.position = next;
            }

            if (ToolUtils.HasArg(args, "rotation"))
            {
                Vector3 rot = ToolUtils.ParseVector3(args["rotation"].ToString());
                Quaternion eulerRot = Quaternion.Euler(rot);
                if (operation == "add")
                {
                    if (isLocal) t.localRotation *= eulerRot;
                    else t.rotation *= eulerRot;
                }
                else if (operation == "multiply")
                {
                    Vector3 current = isLocal ? t.localRotation.eulerAngles : t.rotation.eulerAngles;
                    Quaternion next = Quaternion.Euler(current.x * rot.x, current.y * rot.y, current.z * rot.z);
                    if (isLocal) t.localRotation = next; else t.rotation = next;
                }
                else
                {
                    if (isLocal) t.localRotation = eulerRot; else t.rotation = eulerRot;
                }
            }

            if (ToolUtils.HasArg(args, "scale"))
            {
                Vector3 scale = ToolUtils.ParseVector3(args["scale"].ToString());
                Vector3 current = t.localScale;
                t.localScale = operation switch
                {
                    "add" => current + scale,
                    "multiply" => new Vector3(current.x * scale.x, current.y * scale.y, current.z * scale.z),
                    _ => scale
                };
            }

            var extras = new Dictionary<string, object>
            {
                ["previousState"] = new Dictionary<string, object>
                {
                    ["position"] = $"{prevPos.x},{prevPos.y},{prevPos.z}",
                    ["rotation"] = $"{prevRot.x},{prevRot.y},{prevRot.z}",
                    ["scale"] = $"{prevScale.x},{prevScale.y},{prevScale.z}",
                    ["isLocal"] = isLocal
                }
            };

            string scopeLabel = isLocal ? "local transform" : "transform";
            return ToolUtils.CreateSuccessResponse(
                $"Updated {scopeLabel} for '{gameObjectPath}' (operation: {operation})",
                extras);
        }
    }

    public class SetTransformTool : ITool
    {
        public string Name => "set_transform";

        public string Execute(Dictionary<string, object> args)
        {
            return TransformToolCore.Execute(args, isLocal: false, toolDisplay: "Set Transform");
        }
    }
}
