using System;
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Components
{
    public class SetComponentPropertyTool : ITool
    {
        public string Name => "set_component_property";

        public string Execute(Dictionary<string, object> args)
        {
            var err = ToolUtils.ValidateRequiredArgs(args, "componentType", "propertyName", "value");
            if (err != null) return err;

            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            string componentType = ToolUtils.GetStringArg(args, "componentType");
            string propertyName = ToolUtils.GetStringArg(args, "propertyName");
            string valueStr = ToolUtils.GetStringArg(args, "value");
            bool appendToList = ToolUtils.GetBoolArg(args, "appendToList");

            UnityEngine.GameObject obj = string.IsNullOrEmpty(gameObjectPath)
                ? null : ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            // GameObject is not a Component in Unity; tag and layer are properties on the
            // GameObject itself. Handle them here so calls like
            // set_component_property(path, "GameObject", "tag", "Player") work.
            if (string.Equals(componentType, "GameObject", StringComparison.OrdinalIgnoreCase))
                return SetOnGameObject(obj, gameObjectPath, propertyName, valueStr);

            // Resolve component type. Unity scripts compile into assemblies; until compilation
            // + domain reload finish, the type can't be found — surface that explicitly so the
            // AI knows to wait rather than retrying with garbage.
            System.Type type = ToolUtils.FindComponentType(componentType);
            if (type == null || !typeof(Component).IsAssignableFrom(type))
                return TypeNotFoundError(componentType);

            Component comp = obj.GetComponent(type);
            if (comp == null)
                return ToolUtils.CreateErrorResponse(
                    $"Component '{componentType}' not found on '{gameObjectPath}'");

            return ComponentPropertyCore.SetProperty(
                comp, type, propertyName, valueStr, appendToList,
                gameObjectPath, typeName: componentType, label: "component");
        }

        private static string SetOnGameObject(
            UnityEngine.GameObject obj, string gameObjectPath, string propertyName, string valueStr)
        {
            if (string.Equals(propertyName, "tag", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    Undo.RecordObject(obj, $"Set Tag: {gameObjectPath}");
                    obj.tag = valueStr;
                    return ToolUtils.CreateSuccessResponse(
                        $"Set property 'tag' on GameObject '{gameObjectPath}' to '{valueStr}'");
                }
                catch (UnityException)
                {
                    return ToolUtils.CreateErrorResponse(
                        $"Tag '{valueStr}' does not exist. Add it in Edit > Project Settings > Tags and Layers, or use set_tag.");
                }
            }
            if (string.Equals(propertyName, "layer", StringComparison.OrdinalIgnoreCase))
            {
                if (int.TryParse(valueStr, out int layer) && layer >= 0 && layer <= 31)
                {
                    Undo.RecordObject(obj, $"Set Layer: {gameObjectPath}");
                    obj.layer = layer;
                    return ToolUtils.CreateSuccessResponse(
                        $"Set property 'layer' on GameObject '{gameObjectPath}' to '{valueStr}'");
                }
                int layerByName = LayerMask.NameToLayer(valueStr);
                if (layerByName >= 0)
                {
                    Undo.RecordObject(obj, $"Set Layer: {gameObjectPath}");
                    obj.layer = layerByName;
                    return ToolUtils.CreateSuccessResponse(
                        $"Set property 'layer' on GameObject '{gameObjectPath}' to '{valueStr}'");
                }
                return ToolUtils.CreateErrorResponse(
                    $"Layer '{valueStr}' is not valid. Use a layer index (0-31) or a layer name from Edit > Project Settings > Tags and Layers.");
            }
            return ToolUtils.CreateErrorResponse(
                "Component type 'GameObject' only supports properties 'tag' and 'layer'. For tag use set_component_property with propertyName 'tag' or use set_tag.");
        }

        private static string TypeNotFoundError(string componentType)
        {
            if (EditorApplication.isCompiling)
            {
                var extras = new Dictionary<string, object>
                {
                    { "requiresCompilation", true },
                    { "isCompiling", true }
                };
                return ToolUtils.CreateErrorResponse(
                    $"Component type '{componentType}' not found. Unity is currently compiling. Please wait for compilation to finish, then try again.",
                    extras);
            }

            // Look for a script file with this name on disk so we can hint
            // "your type exists but hasn't compiled yet" — much more useful
            // than a blanket "not found".
            string foundScriptPath = FindScriptFileForType(componentType);
            if (foundScriptPath != null)
            {
                var extras = new Dictionary<string, object>
                {
                    { "scriptExists", true },
                    { "scriptPath", foundScriptPath },
                    { "requiresCompilation", true }
                };
                return ToolUtils.CreateErrorResponse(
                    $"Component type '{componentType}' not found. Script file exists at '{foundScriptPath}' but is not yet compiled. Wait for Unity to finish compiling scripts, then try again.",
                    extras);
            }

            return ToolUtils.CreateErrorResponse(
                $"Component type '{componentType}' not found. No matching script file found in the project.");
        }

        private static string FindScriptFileForType(string componentType)
        {
            string[] possiblePaths = new string[]
            {
                $"Assets/Scripts/{componentType}.cs",
                $"Assets/{componentType}.cs",
                $"Assets/Scripts/Player/{componentType}.cs",
                $"Assets/Scripts/Game/{componentType}.cs"
            };
            foreach (var path in possiblePaths)
                if (System.IO.File.Exists(path)) return path;

            // Broader scan via AssetDatabase
            string[] allScripts = AssetDatabase.FindAssets("t:MonoScript");
            foreach (var guid in allScripts)
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (path.EndsWith($"{componentType}.cs", StringComparison.OrdinalIgnoreCase))
                    return path;
            }
            return null;
        }
    }
}
