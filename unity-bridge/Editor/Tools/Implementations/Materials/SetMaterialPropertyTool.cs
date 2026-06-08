using System;
using System.Collections.Generic;
using System.Linq;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Materials
{
    // The modern shader-property enum (UnityEngine.Rendering) replaces the
    // long-obsolete ShaderUtil.ShaderPropertyType. Alias it for terse use.
    using ShaderPropertyType = UnityEngine.Rendering.ShaderPropertyType;

    public class SetMaterialPropertyTool : ITool
    {
        public string Name => "set_material_property";

        public string Execute(Dictionary<string, object> args)
        {
            string materialPath = args.ContainsKey("materialPath") ? args["materialPath"].ToString() : "";
            string propertyName = args.ContainsKey("propertyName") ? args["propertyName"].ToString() : "";
            string valueStr = args.ContainsKey("value") ? args["value"].ToString() : "";

            if (string.IsNullOrEmpty(materialPath))
            {
                return ToolUtils.CreateErrorResponse("materialPath is required");
            }

            if (string.IsNullOrEmpty(propertyName))
            {
                return ToolUtils.CreateErrorResponse("propertyName is required");
            }

            if (string.IsNullOrEmpty(valueStr))
            {
                return ToolUtils.CreateErrorResponse("value is required");
            }

            // Ensure path starts with Assets/
            if (!materialPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
            {
                materialPath = "Assets/" + materialPath;
            }

            // Load material
            Material mat = AssetDatabase.LoadAssetAtPath<Material>(materialPath);
            if (mat == null)
            {
                return ToolUtils.CreateErrorResponse($"Material not found at '{materialPath}'");
            }

            // Resolve propertyName to the shader's canonical form. Models often send
            // "baseColor" / "BaseColor" when the shader actually exposes "_BaseColor",
            // or send "_basecolor" with wrong casing. Resolving before dispatch means
            // mat.SetColor/SetFloat/etc. hit a real property and don't silently no-op.
            string canonicalName = ResolveShaderPropertyName(mat, propertyName);
            if (canonicalName == null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Property '{propertyName}' not found on shader '{mat.shader.name}'. " + DescribeShaderProperties(mat));
            }

            try
            {
                Undo.RecordObject(mat, $"Set Material Property: {materialPath}.{canonicalName}");

                ShaderPropertyType propType = GetShaderPropertyType(mat, canonicalName);
                bool applied = ApplyByShaderType(mat, canonicalName, valueStr, propType, out string parseError);
                if (!applied)
                {
                    return ToolUtils.CreateErrorResponse(
                        $"Failed to apply value '{valueStr}' to shader property '{canonicalName}' (type {propType}): {parseError}");
                }

                EditorUtility.SetDirty(mat);
                AssetDatabase.SaveAssets();

                return ToolUtils.CreateSuccessResponse(
                    $"Set property '{canonicalName}' on material '{materialPath}' to '{valueStr}'");
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse($"Failed to set material property: {e.Message}");
            }
        }

        /// <summary>
        /// Resolve the model's propertyName against the shader's actual property list.
        /// Tries exact match, an underscore-prefixed variant, and a case-insensitive
        /// walk of ShaderUtil.GetPropertyName(). Returns the canonical shader property
        /// name, or null if no match.
        /// </summary>
        private static string ResolveShaderPropertyName(Material mat, string propertyName)
        {
            if (mat.HasProperty(propertyName)) return propertyName;

            if (!propertyName.StartsWith("_"))
            {
                string withUnderscore = "_" + propertyName;
                if (mat.HasProperty(withUnderscore)) return withUnderscore;
            }

            var shader = mat.shader;
            if (shader == null) return null;
            int count = ShaderUtil.GetPropertyCount(shader);
            for (int i = 0; i < count; i++)
            {
                string name = ShaderUtil.GetPropertyName(shader, i);
                if (string.Equals(name, propertyName, StringComparison.OrdinalIgnoreCase))
                    return name;
                // Compare ignoring any leading underscore on either side.
                if (string.Equals(name.TrimStart('_'), propertyName.TrimStart('_'), StringComparison.OrdinalIgnoreCase))
                    return name;
            }
            return null;
        }

        private static ShaderPropertyType GetShaderPropertyType(Material mat, string canonicalName)
        {
            var shader = mat.shader;
            int count = shader.GetPropertyCount();
            for (int i = 0; i < count; i++)
            {
                if (shader.GetPropertyName(i) == canonicalName)
                    return shader.GetPropertyType(i);
            }
            // Fallback — shouldn't happen because ResolveShaderPropertyName already matched
            return ShaderPropertyType.Float;
        }

        /// <summary>
        /// Apply the string value to the resolved shader property, dispatching on the
        /// shader's declared property type rather than guessing from the value format.
        /// </summary>
        private static bool ApplyByShaderType(
            Material mat, string name, string valueStr,
            ShaderPropertyType propType, out string parseError)
        {
            parseError = null;
            switch (propType)
            {
                case ShaderPropertyType.Color:
                    try { mat.SetColor(name, ToolUtils.ParseColor(valueStr)); return true; }
                    catch (Exception e) { parseError = e.Message; return false; }

                case ShaderPropertyType.Vector:
                    try
                    {
                        // Accept "x,y,z,w", "x,y,z", or "x,y" — pad with zeros.
                        var parts = valueStr.Split(',');
                        float x = parts.Length > 0 ? ParseFloat(parts[0]) : 0f;
                        float y = parts.Length > 1 ? ParseFloat(parts[1]) : 0f;
                        float z = parts.Length > 2 ? ParseFloat(parts[2]) : 0f;
                        float w = parts.Length > 3 ? ParseFloat(parts[3]) : 0f;
                        mat.SetVector(name, new Vector4(x, y, z, w));
                        return true;
                    }
                    catch (Exception e) { parseError = e.Message; return false; }

                case ShaderPropertyType.Float:
                case ShaderPropertyType.Range:
                    if (float.TryParse(valueStr,
                            System.Globalization.NumberStyles.Float,
                            System.Globalization.CultureInfo.InvariantCulture,
                            out float f))
                    {
                        mat.SetFloat(name, f);
                        return true;
                    }
                    parseError = $"could not parse '{valueStr}' as float";
                    return false;

                case ShaderPropertyType.Texture:
                {
                    // Accept clear-texture via empty string or "null".
                    var trimmed = valueStr?.Trim().Trim('"') ?? "";
                    if (string.IsNullOrEmpty(trimmed) || trimmed.Equals("null", StringComparison.OrdinalIgnoreCase))
                    {
                        mat.SetTexture(name, null);
                        return true;
                    }
                    if (!trimmed.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                        trimmed = "Assets/" + trimmed;
                    var tex = AssetDatabase.LoadAssetAtPath<Texture>(trimmed);
                    if (tex == null)
                    {
                        parseError = $"texture not found at '{trimmed}'";
                        return false;
                    }
                    mat.SetTexture(name, tex);
                    return true;
                }

                default:
                    parseError = $"unsupported shader property type {propType}";
                    return false;
            }
        }

        private static float ParseFloat(string s)
        {
            return float.Parse(s.Trim(),
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Enumerate the shader's actual properties so an unresolved propertyName
        /// error gives the model everything it needs to retry with a real name.
        /// </summary>
        private static string DescribeShaderProperties(Material mat)
        {
            var shader = mat.shader;
            if (shader == null) return "Shader is null.";
            int count = shader.GetPropertyCount();
            if (count == 0) return "Shader exposes no properties.";

            var entries = new List<string>();
            for (int i = 0; i < count; i++)
            {
                string name = shader.GetPropertyName(i);
                var type = shader.GetPropertyType(i);
                entries.Add($"{name} ({type})");
            }
            // Cap to avoid drowning the error message on shaders with dozens of props.
            const int Cap = 30;
            if (entries.Count > Cap)
            {
                var shown = string.Join(", ", entries.Take(Cap));
                return $"Available shader properties (first {Cap} of {entries.Count}): {shown}.";
            }
            return $"Available shader properties: {string.Join(", ", entries)}.";
        }
    }
}
