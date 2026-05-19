using System;
using System.Collections.Generic;
using System.Linq;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Components
{
    public class SetScriptComponentPropertyTool : ITool
    {
        public string Name => "set_script_component_property";

        public string Execute(Dictionary<string, object> args)
        {
            var err = ToolUtils.ValidateRequiredArgs(args, "scriptName", "propertyName", "value");
            if (err != null) return err;

            string gameObjectPath = ToolUtils.GetStringArg(args, "gameObjectPath");
            string scriptName = ToolUtils.GetStringArg(args, "scriptName");
            string propertyName = ToolUtils.GetStringArg(args, "propertyName");
            string valueStr = ToolUtils.GetStringArg(args, "value");
            bool appendToList = ToolUtils.GetBoolArg(args, "appendToList");

            UnityEngine.GameObject obj = string.IsNullOrEmpty(gameObjectPath)
                ? null : ToolUtils.FindGameObjectByPath(gameObjectPath);
            if (obj == null)
                return ToolUtils.CreateErrorResponse($"GameObject '{gameObjectPath}' not found");

            // Component lookup strategy is the only thing that differs from set_component_property:
            // here we iterate the GameObject's components and match by class name (full, partial,
            // or case-insensitive). Falls back to ToolUtils.FindComponentType for exact-type
            // lookup when the script isn't attached but its type exists.
            Component scriptComponent = null;
            System.Type componentType = null;

            Component[] allComponents = obj.GetComponents<Component>();
            foreach (var comp in allComponents)
            {
                if (comp == null) continue;
                System.Type compType = comp.GetType();
                string typeName = compType.Name;
                if (string.Equals(typeName, scriptName, StringComparison.OrdinalIgnoreCase) ||
                    typeName.Contains(scriptName, StringComparison.OrdinalIgnoreCase) ||
                    scriptName.Contains(typeName, StringComparison.OrdinalIgnoreCase))
                {
                    scriptComponent = comp;
                    componentType = compType;
                    break;
                }
            }

            if (scriptComponent == null)
            {
                componentType = ToolUtils.FindComponentType(scriptName);
                if (componentType != null)
                    scriptComponent = obj.GetComponent(componentType);
            }

            if (scriptComponent == null || componentType == null)
                return ScriptNotFoundError(allComponents, scriptName, gameObjectPath);

            return ComponentPropertyCore.SetProperty(
                scriptComponent, componentType, propertyName, valueStr, appendToList,
                gameObjectPath, typeName: componentType.Name, label: "script component");
        }

        private static string ScriptNotFoundError(
            Component[] allComponents, string scriptName, string gameObjectPath)
        {
            var scriptComponents = allComponents
                .Where(c => c != null && c.GetType().Namespace != "UnityEngine")
                .Select(c => c.GetType().Name)
                .Distinct()
                .ToList();

            string availableList = scriptComponents.Count > 0
                ? $" Available script components on '{gameObjectPath}': {string.Join(", ", scriptComponents)}"
                : $" No script components found on '{gameObjectPath}'. Use add_component to add the script first.";

            return ToolUtils.CreateErrorResponse(
                $"Script component '{scriptName}' not found on '{gameObjectPath}'.{availableList}");
        }
    }
}
