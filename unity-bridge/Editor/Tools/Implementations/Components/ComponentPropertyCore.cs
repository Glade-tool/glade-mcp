using System;
using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Components
{
    /// <summary>
    /// Shared property-setting logic for set_component_property and
    /// set_script_component_property. Both tools used to duplicate this
    /// ~500-line machinery — the only real difference is *how* they resolve
    /// the target Component (type lookup vs name match). Once resolved, the
    /// 5-layer property-resolution chain (reflection prop / case-insensitive
    /// prop / field / case-insensitive field / SerializedObject), list-append
    /// handling, and value coercion is identical.
    /// </summary>
    internal static class ComponentPropertyCore
    {
        private const System.Reflection.BindingFlags BFlags =
            System.Reflection.BindingFlags.Public |
            System.Reflection.BindingFlags.NonPublic |
            System.Reflection.BindingFlags.Instance;

        private const System.Reflection.BindingFlags BFlagsIgnoreCase =
            BFlags | System.Reflection.BindingFlags.IgnoreCase;

        /// <summary>
        /// Sets a property/field on a resolved component.
        /// </summary>
        /// <param name="label">"component" or "script component" — used in result messages so
        /// the caller controls phrasing.</param>
        /// <param name="typeName">Human-readable type name for error messages (e.g. "Rigidbody",
        /// "PlayerMovement"). Usually componentType.Name.</param>
        public static string SetProperty(
            Component comp,
            System.Type compType,
            string propertyName,
            string valueStr,
            bool appendToList,
            string gameObjectPath,
            string typeName,
            string label)
        {
            // 1) Reflection property (exact, then case-insensitive)
            var prop = compType.GetProperty(propertyName, BFlags)
                    ?? compType.GetProperty(propertyName, BFlagsIgnoreCase);
            if (prop != null && prop.CanWrite)
            {
                try
                {
                    if (appendToList && IsListOrArrayType(prop.PropertyType))
                        return AppendToList(comp, prop.Name, valueStr, prop.PropertyType,
                            gameObjectPath, typeName, label, isProperty: true);

                    object converted = ToolUtils.ConvertValueToPropertyType(valueStr, prop.PropertyType);
                    Undo.RecordObject(comp, $"Set Property: {gameObjectPath}.{typeName}.{prop.Name}");
                    prop.SetValue(comp, converted);
                    EditorUtility.SetDirty(comp);

                    return ToolUtils.CreateSuccessResponse(
                        $"Set property '{prop.Name}' on {label} '{typeName}' of '{gameObjectPath}' to '{valueStr}'");
                }
                catch (Exception e)
                {
                    return ToolUtils.CreateErrorResponse($"Failed to set property: {e.Message}");
                }
            }

            // 2) Reflection field (exact, then case-insensitive)
            var field = compType.GetField(propertyName, BFlags)
                    ?? compType.GetField(propertyName, BFlagsIgnoreCase);
            if (field != null && !field.IsLiteral && !field.IsInitOnly)
            {
                try
                {
                    if (appendToList && IsListOrArrayType(field.FieldType))
                        return AppendToList(comp, field.Name, valueStr, field.FieldType,
                            gameObjectPath, typeName, label, isProperty: false);

                    object converted = ToolUtils.ConvertValueToPropertyType(valueStr, field.FieldType);
                    Undo.RecordObject(comp, $"Set Field: {gameObjectPath}.{typeName}.{field.Name}");
                    field.SetValue(comp, converted);
                    EditorUtility.SetDirty(comp);

                    return ToolUtils.CreateSuccessResponse(
                        $"Set field '{field.Name}' on {label} '{typeName}' of '{gameObjectPath}' to '{valueStr}'");
                }
                catch (Exception e)
                {
                    return ToolUtils.CreateErrorResponse($"Failed to set field: {e.Message}");
                }
            }

            // 3) SerializedObject fallback — rescues m_* internal names on built-in C++
            // components, and [SerializeField] private fields that reflection can't see on the
            // derived type. This is the path that makes get_component_inspector_properties'
            // `internalName` field actually usable as input here.
            var serializedResult = TrySetViaSerializedObject(
                comp, propertyName, valueStr, appendToList, gameObjectPath, typeName, label);
            if (serializedResult != null) return serializedResult;

            // Final: report what was available
            return BuildNotFoundError(comp, compType, propertyName, typeName, label);
        }

        // ---- Type/element introspection ----

        public static bool IsListOrArrayType(System.Type type)
        {
            if (type == null) return false;
            if (type.IsArray) return true;
            if (!type.IsGenericType) return false;
            var def = type.GetGenericTypeDefinition();
            return def == typeof(List<>)
                || def == typeof(IList<>)
                || def == typeof(ICollection<>);
        }

        public static System.Type GetElementType(System.Type listType)
        {
            if (listType == null) return null;
            if (listType.IsArray) return listType.GetElementType();
            if (listType.IsGenericType)
            {
                var args = listType.GetGenericArguments();
                if (args.Length > 0) return args[0];
            }
            return null;
        }

        // ---- SerializedObject fallback ----

        private static string TrySetViaSerializedObject(
            Component comp,
            string propertyName,
            string valueStr,
            bool appendToList,
            string gameObjectPath,
            string typeName,
            string label)
        {
            try
            {
                var so = new SerializedObject(comp);
                SerializedProperty sp = so.FindProperty(propertyName);
                if (sp == null)
                {
                    // Case-insensitive walk of the top-level iterator. We don't recurse —
                    // nested paths still need exact propertyPath syntax.
                    var iter = so.GetIterator();
                    bool enterChildren = true;
                    while (iter.NextVisible(enterChildren))
                    {
                        enterChildren = false;
                        if (string.Equals(iter.name, propertyName, StringComparison.OrdinalIgnoreCase))
                        {
                            sp = so.FindProperty(iter.propertyPath);
                            break;
                        }
                    }
                }
                if (sp == null) return null;

                if (appendToList && sp.isArray)
                {
                    sp.arraySize += 1;
                    var element = sp.GetArrayElementAtIndex(sp.arraySize - 1);
                    ApplySerializedValue(element, valueStr);
                    so.ApplyModifiedProperties();
                    EditorUtility.SetDirty(comp);
                    return ToolUtils.CreateSuccessResponse(
                        $"Appended 1 item to serialized list '{sp.name}' on {label} '{typeName}' of '{gameObjectPath}'");
                }

                Undo.RecordObject(comp, $"Set Serialized: {gameObjectPath}.{typeName}.{sp.name}");
                if (!ApplySerializedValue(sp, valueStr))
                {
                    return ToolUtils.CreateErrorResponse(
                        $"Could not convert value '{valueStr}' to serialized property '{sp.name}' " +
                        $"(type {sp.propertyType}) on {label} '{typeName}'.");
                }
                so.ApplyModifiedProperties();
                EditorUtility.SetDirty(comp);
                return ToolUtils.CreateSuccessResponse(
                    $"Set serialized property '{sp.name}' on {label} '{typeName}' of '{gameObjectPath}' to '{valueStr}'");
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse($"Failed to set via SerializedObject: {e.Message}");
            }
        }

        private static bool ApplySerializedValue(SerializedProperty sp, string valueStr)
        {
            switch (sp.propertyType)
            {
                case SerializedPropertyType.Boolean:
                    if (bool.TryParse(valueStr, out var bv)) { sp.boolValue = bv; return true; }
                    return false;
                case SerializedPropertyType.Integer:
                case SerializedPropertyType.LayerMask:
                case SerializedPropertyType.Character:
                    if (int.TryParse(valueStr, out var iv)) { sp.intValue = iv; return true; }
                    return false;
                case SerializedPropertyType.Float:
                    if (float.TryParse(valueStr,
                            System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture,
                            out var fv))
                    { sp.floatValue = fv; return true; }
                    return false;
                case SerializedPropertyType.String:
                    sp.stringValue = valueStr; return true;
                case SerializedPropertyType.Enum:
                    return ApplyEnumByNameOrIndex(sp, valueStr);
                case SerializedPropertyType.Color:
                    try { sp.colorValue = ToolUtils.ParseColor(valueStr); return true; } catch { return false; }
                case SerializedPropertyType.Vector2:
                    try { var v = ToolUtils.ParseVector3(valueStr); sp.vector2Value = new Vector2(v.x, v.y); return true; } catch { return false; }
                case SerializedPropertyType.Vector3:
                    try { sp.vector3Value = ToolUtils.ParseVector3(valueStr); return true; } catch { return false; }
                case SerializedPropertyType.Vector4:
                    try
                    {
                        var v = ToolUtils.ParseVector3(valueStr);
                        sp.vector4Value = new Vector4(v.x, v.y, v.z, 0f);
                        return true;
                    }
                    catch { return false; }
                case SerializedPropertyType.Quaternion:
                    try { sp.quaternionValue = Quaternion.Euler(ToolUtils.ParseVector3(valueStr)); return true; } catch { return false; }
                case SerializedPropertyType.ObjectReference:
                {
                    var trimmed = valueStr?.Trim().Trim('"') ?? "";
                    if (string.IsNullOrEmpty(trimmed)) { sp.objectReferenceValue = null; return true; }
                    var asset = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(trimmed);
                    if (asset != null) { sp.objectReferenceValue = asset; return true; }
                    var go = ToolUtils.FindGameObjectByPath(trimmed);
                    if (go != null) { sp.objectReferenceValue = go; return true; }
                    return false;
                }
                default:
                    return false;
            }
        }

        private static bool ApplyEnumByNameOrIndex(SerializedProperty sp, string valueStr)
        {
            // Accept either an enum-name string ("Off") or the integer index ("0").
            if (int.TryParse(valueStr, out var enumIdx)
                && enumIdx >= 0 && sp.enumNames != null && enumIdx < sp.enumNames.Length)
            {
                sp.enumValueIndex = enumIdx;
                return true;
            }
            if (sp.enumNames != null)
            {
                for (int i = 0; i < sp.enumNames.Length; i++)
                {
                    if (string.Equals(sp.enumNames[i], valueStr, StringComparison.OrdinalIgnoreCase))
                    {
                        sp.enumValueIndex = i;
                        return true;
                    }
                }
            }
            return false;
        }

        // ---- List append (reflection-typed) ----

        private static string AppendToList(
            UnityEngine.Object target,
            string memberName,
            string valueStr,
            System.Type listType,
            string gameObjectPath,
            string typeName,
            string label,
            bool isProperty)
        {
            string memberKind = isProperty ? "Property" : "Field";
            try
            {
                var so = new SerializedObject(target);
                var listProp = so.FindProperty(memberName);
                if (listProp == null || !listProp.isArray)
                    return ToolUtils.CreateErrorResponse(
                        $"{memberKind} '{memberName}' is not a serialized list/array. Cannot append.");

                var elementType = GetElementType(listType);
                if (elementType == null)
                    return ToolUtils.CreateErrorResponse(
                        $"Could not determine element type for list '{memberName}'");

                var itemsToAdd = ParseListValue(valueStr, elementType);
                if (itemsToAdd.Count == 0)
                    return ToolUtils.CreateErrorResponse(
                        $"No valid items found in value to append to list '{memberName}'");

                Undo.RecordObject(target, $"Append to List: {gameObjectPath}.{typeName}.{memberName}");

                int startIndex = listProp.arraySize;
                listProp.arraySize = startIndex + itemsToAdd.Count;
                for (int i = 0; i < itemsToAdd.Count; i++)
                {
                    var element = listProp.GetArrayElementAtIndex(startIndex + i);
                    SetSerializedPropertyValue(element, itemsToAdd[i], elementType);
                }

                so.ApplyModifiedProperties();
                EditorUtility.SetDirty(target);

                return ToolUtils.CreateSuccessResponse(
                    $"Appended {itemsToAdd.Count} item(s) to list '{memberName}' on {label} '{typeName}' of '{gameObjectPath}'");
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Failed to append to list {memberKind.ToLower()}: {e.Message}");
            }
        }

        private static List<object> ParseListValue(string valueStr, System.Type elementType)
        {
            var result = new List<object>();
            valueStr = valueStr.Trim();

            if (valueStr.StartsWith("[") && valueStr.EndsWith("]"))
            {
                string inner = valueStr.Substring(1, valueStr.Length - 2).Trim();
                if (string.IsNullOrEmpty(inner)) return result;
                foreach (var item in inner.Split(','))
                {
                    string trimmed = item.Trim().Trim('"', '\'');
                    if (string.IsNullOrEmpty(trimmed)) continue;
                    try { result.Add(ToolUtils.ConvertValueToPropertyType(trimmed, elementType)); }
                    catch { /* skip invalid */ }
                }
                return result;
            }

            // Single item — try direct, then comma-separated.
            try
            {
                result.Add(ToolUtils.ConvertValueToPropertyType(valueStr, elementType));
                return result;
            }
            catch { /* fall through */ }

            foreach (var item in valueStr.Split(','))
            {
                string trimmed = item.Trim().Trim('"', '\'');
                if (string.IsNullOrEmpty(trimmed)) continue;
                try { result.Add(ToolUtils.ConvertValueToPropertyType(trimmed, elementType)); }
                catch { /* skip invalid */ }
            }
            return result;
        }

        private static void SetSerializedPropertyValue(SerializedProperty prop, object value, System.Type elementType)
        {
            if (value == null)
            {
                if (prop.propertyType == SerializedPropertyType.ObjectReference)
                    prop.objectReferenceValue = null;
                return;
            }

            if (elementType == typeof(int) || elementType == typeof(short) || elementType == typeof(byte))
            {
                if (value is int intVal) prop.intValue = intVal;
                else if (int.TryParse(value.ToString(), out int parsed)) prop.intValue = parsed;
                return;
            }
            if (elementType == typeof(float) || elementType == typeof(double))
            {
                if (value is float f) prop.floatValue = f;
                else if (value is double d) prop.floatValue = (float)d;
                else if (float.TryParse(value.ToString(),
                            System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture,
                            out float parsed))
                    prop.floatValue = parsed;
                return;
            }
            if (elementType == typeof(bool))
            {
                if (value is bool b) prop.boolValue = b;
                else if (bool.TryParse(value.ToString(), out bool parsed)) prop.boolValue = parsed;
                return;
            }
            if (elementType == typeof(string))
            {
                prop.stringValue = value.ToString();
                return;
            }
            if (elementType == typeof(Vector2)) { if (value is Vector2 v) prop.vector2Value = v; return; }
            if (elementType == typeof(Vector3)) { if (value is Vector3 v) prop.vector3Value = v; return; }
            if (elementType == typeof(Vector4)) { if (value is Vector4 v) prop.vector4Value = v; return; }
            if (elementType == typeof(Color))   { if (value is Color c) prop.colorValue = c; return; }

            if (elementType.IsEnum)
            {
                string valueStr = value.ToString().Trim();
                if (prop.enumNames != null && prop.enumNames.Length > 0)
                {
                    for (int i = 0; i < prop.enumNames.Length; i++)
                    {
                        if (string.Equals(prop.enumNames[i], valueStr, StringComparison.OrdinalIgnoreCase))
                        {
                            prop.enumValueIndex = i;
                            return;
                        }
                    }
                }
                try
                {
                    object enumValue = Enum.Parse(elementType, valueStr, true);
                    string enumName = Enum.GetName(elementType, enumValue);
                    if (!string.IsNullOrEmpty(enumName))
                    {
                        string[] enumNames = Enum.GetNames(elementType);
                        for (int i = 0; i < enumNames.Length; i++)
                        {
                            if (string.Equals(enumNames[i], enumName, StringComparison.OrdinalIgnoreCase))
                            {
                                prop.enumValueIndex = i;
                                return;
                            }
                        }
                    }
                }
                catch
                {
                    string[] enumNames = Enum.GetNames(elementType);
                    for (int i = 0; i < enumNames.Length; i++)
                    {
                        if (string.Equals(enumNames[i], valueStr, StringComparison.OrdinalIgnoreCase))
                        {
                            prop.enumValueIndex = i;
                            return;
                        }
                    }
                }
                return;
            }

            if (typeof(UnityEngine.Object).IsAssignableFrom(elementType))
            {
                if (value is UnityEngine.Object obj) prop.objectReferenceValue = obj;
            }
        }

        // ---- Helpful "not found" error with available members ----

        private static string BuildNotFoundError(
            Component comp, System.Type compType, string propertyName, string typeName, string label)
        {
            var availableProperties = compType.GetProperties(BFlags)
                .Where(p => p.CanWrite)
                .Select(p => p.Name);
            var availableFields = compType.GetFields(BFlags)
                .Where(f => !f.IsLiteral && !f.IsInitOnly)
                .Select(f => f.Name);
            var availableNames = availableProperties.Concat(availableFields).Distinct().ToList();

            var serializedNames = new List<string>();
            try
            {
                var so = new SerializedObject(comp);
                var iter = so.GetIterator();
                bool enterChildren = true;
                while (iter.NextVisible(enterChildren))
                {
                    enterChildren = false;
                    if (iter.name != "m_Script") serializedNames.Add(iter.name);
                }
            }
            catch { /* surface what we have */ }

            string reflectionList = availableNames.Count > 0
                ? $" Reflection-visible on '{typeName}': {string.Join(", ", availableNames)}."
                : "";
            string serializedList = serializedNames.Count > 0
                ? $" Serialized on '{typeName}': {string.Join(", ", serializedNames)}."
                : "";

            return ToolUtils.CreateErrorResponse(
                $"Property or field '{propertyName}' not found or not writable on {label} '{typeName}'.{reflectionList}{serializedList}");
        }
    }
}
