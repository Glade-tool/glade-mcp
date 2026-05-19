using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEditor;

namespace GladeAgenticAI.Core.Tools
{
    /// <summary>
    /// Shared utility methods for tool execution, parsing, and serialization.
    /// Extracted from ToolExecutor to adhere to DRY and standardize tool responses.
    /// </summary>
    public static class ToolUtils
    {
        /// <summary>
        /// Appends a single JSON value (scalar, list, or nested dict) to the builder.
        /// Shared between CreateSuccessResponse, CreateErrorResponse, and SerializeDictToJson
        /// so every extras-producing tool path serializes lists identically — the
        /// old pattern was "each call site re-handled types and stringified
        /// List&lt;string&gt; as its type name."
        /// </summary>
        private static void AppendJsonValue(StringBuilder sb, object value)
        {
            if (value == null) { sb.Append("null"); return; }
            if (value is string s) { sb.Append('"').Append(EscapeJsonString(s)).Append('"'); return; }
            if (value is bool b) { sb.Append(b ? "true" : "false"); return; }
            if (value is int || value is long || value is float || value is double || value is decimal)
            {
                sb.Append(Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture));
                return;
            }
            if (value is Dictionary<string, object> dict) { sb.Append(SerializeDictToJson(dict)); return; }
            if (value is IList<string> strList)
            {
                sb.Append('[');
                for (int i = 0; i < strList.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append('"').Append(EscapeJsonString(strList[i])).Append('"');
                }
                sb.Append(']');
                return;
            }
            if (value is IList<Dictionary<string, object>> dictList)
            {
                sb.Append('[');
                for (int i = 0; i < dictList.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append(SerializeDictToJson(dictList[i]));
                }
                sb.Append(']');
                return;
            }
            if (value is System.Collections.IEnumerable seq && !(value is string))
            {
                sb.Append('[');
                bool first = true;
                foreach (var item in seq)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    AppendJsonValue(sb, item);
                }
                sb.Append(']');
                return;
            }
            // Fallback: stringify. Previously this path silently produced
            // "System.Collections.Generic.List`1[System.String]" for lists
            // declared as plain object — the IEnumerable branch above catches
            // those now, so this truly is the "unknown scalar" leaf.
            sb.Append('"').Append(EscapeJsonString(value.ToString() ?? "")).Append('"');
        }

        /// <summary>
        /// Generates a standard success JSON response.
        /// </summary>
        public static string CreateSuccessResponse(string message, Dictionary<string, object> extras = null)
        {
            var sb = new StringBuilder();
            sb.Append("{\"success\":true");
            sb.Append($",\"message\":\"{EscapeJsonString(message)}\"");

            if (extras != null)
            {
                foreach (var kvp in extras)
                {
                    sb.Append(',');
                    sb.Append('"').Append(kvp.Key).Append("\":");
                    AppendJsonValue(sb, kvp.Value);
                }
            }

            sb.Append("}");
            return sb.ToString();
        }

        /// <summary>
        /// Generates a standard error JSON response.
        /// </summary>
        public static string CreateErrorResponse(string error)
        {
            return $"{{\"success\":false,\"error\":\"{EscapeJsonString(error)}\"}}";
        }

        /// <summary>
        /// Generates a standard error JSON response with extra data.
        /// </summary>
        public static string CreateErrorResponse(string error, Dictionary<string, object> extras)
        {
            var sb = new StringBuilder();
            sb.Append("{\"success\":false");
            sb.Append($",\"error\":\"{EscapeJsonString(error)}\"");

            if (extras != null)
            {
                foreach (var kvp in extras)
                {
                    sb.Append(',');
                    sb.Append('"').Append(kvp.Key).Append("\":");
                    AppendJsonValue(sb, kvp.Value);
                }
            }

            sb.Append("}");
            return sb.ToString();
        }

        /// <summary>
        /// Builds a success JSON response with a string array (e.g. "scripts": [...], "children": [...]).
        /// </summary>
        public static string BuildStringArrayResult(string key, string[] values)
        {
            var sb = new StringBuilder();
            sb.Append("{\"success\":true");
            sb.Append($",\"{key}\":[");
            for (int i = 0; i < values.Length; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append($"\"{EscapeJsonString(values[i])}\"");
            }
            sb.Append("]}");
            return sb.ToString();
        }

        /// <summary>
        /// Builds a success JSON response with count and string array (e.g. "count", "selected", [...]).
        /// </summary>
        public static string BuildStringArrayResultWithCount(string key, System.Collections.Generic.IList<string> values, string message)
        {
            var sb = new StringBuilder();
            sb.Append("{\"success\":true");
            sb.Append(",\"count\":");
            sb.Append(values.Count);
            sb.Append($",\"{key}\":[");
            for (int i = 0; i < values.Count; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append($"\"{EscapeJsonString(values[i])}\"");
            }
            sb.Append("]");
            if (!string.IsNullOrEmpty(message))
            {
                sb.Append($",\"message\":\"{EscapeJsonString(message)}\"");
            }
            sb.Append("}");
            return sb.ToString();
        }

        /// <summary>
        /// Serializes a dictionary to JSON (for custom responses like get_gameobject_info, list_materials).
        /// Handles string (escaped), bool, number, List&lt;string&gt;, List&lt;Dictionary&lt;string, object&gt;&gt;.
        /// </summary>
        public static string SerializeDictToJson(Dictionary<string, object> dict)
        {
            var sb = new StringBuilder();
            sb.Append('{');
            int i = 0;
            foreach (var kvp in dict)
            {
                if (i > 0) sb.Append(',');
                sb.Append('"').Append(kvp.Key).Append("\":");
                AppendJsonValue(sb, kvp.Value);
                i++;
            }
            sb.Append('}');
            return sb.ToString();
        }

        public static string GetGameObjectPath(GameObject obj)
        {
            if (obj == null) return "";
            string path = obj.name;
            Transform parent = obj.transform.parent;
            while (parent != null)
            {
                path = parent.name + "/" + path;
                parent = parent.parent;
            }
            return path;
        }

        /// <summary>
        /// Ensures an asset folder path exists, creating parent folders as needed.
        /// </summary>
        public static void EnsureAssetFolder(string folderPath)
        {
            if (string.IsNullOrEmpty(folderPath)) return;
            if (!folderPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                folderPath = "Assets/" + folderPath;
            if (AssetDatabase.IsValidFolder(folderPath)) return;
            string[] parts = folderPath.Split('/');
            string currentPath = "";
            for (int i = 0; i < parts.Length; i++)
            {
                if (i == 0)
                    currentPath = parts[i];
                else
                {
                    string parentPath = currentPath;
                    currentPath = currentPath + "/" + parts[i];
                    if (!AssetDatabase.IsValidFolder(currentPath))
                        AssetDatabase.CreateFolder(parentPath, parts[i]);
                }
            }
        }

        /// <summary>
        /// Finds a GameObject by hierarchy path (e.g. "Stage/Platform") or by single name.
        /// Resolves paths so child objects work; also finds inactive objects when searching
        /// by name (Unity's GameObject.Find only returns active objects).
        /// </summary>
        public static GameObject FindGameObjectByPath(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            path = path.Trim();
            if (path.Length == 0) return null;

            // Single name: try Find first (active only), then search hierarchy including inactive
            if (path.IndexOf('/') < 0)
            {
                GameObject byFind = GameObject.Find(path);
                if (byFind != null) return byFind;
                return FindGameObjectByNameInScene(path, includeInactive: true);
            }

            // Hierarchy path: walk from root
            string[] segments = path.Split('/');
            if (segments.Length == 0) return null;

            Scene scene = SceneManager.GetActiveScene();
            if (!scene.IsValid()) return null;

            GameObject[] roots = scene.GetRootGameObjects();
            GameObject current = null;
            foreach (GameObject root in roots)
            {
                if (string.Equals(root.name, segments[0].Trim(), StringComparison.OrdinalIgnoreCase))
                {
                    current = root;
                    break;
                }
            }
            if (current == null) return null;

            for (int i = 1; i < segments.Length; i++)
            {
                string childName = segments[i].Trim();
                if (string.IsNullOrEmpty(childName)) continue;
                // Use recursive search so we find children even when inactive (e.g. for set_game_object_active)
                Transform child = FindChildRecursive(current.transform, childName);
                if (child == null) return null;
                current = child.gameObject;
            }
            return current;
        }

        private static Transform FindChildRecursive(Transform parent, string name)
        {
            for (int i = 0; i < parent.childCount; i++)
            {
                Transform child = parent.GetChild(i);
                if (string.Equals(child.name, name, StringComparison.OrdinalIgnoreCase))
                    return child;
                Transform found = FindChildRecursive(child, name);
                if (found != null) return found;
            }
            return null;
        }

        /// <summary>
        /// Finds a GameObject by name anywhere in the active scene, including inactive objects.
        /// Used when GameObject.Find(name) returns null (e.g. object was just deactivated).
        /// </summary>
        private static GameObject FindGameObjectByNameInScene(string name, bool includeInactive = true)
        {
            Scene scene = SceneManager.GetActiveScene();
            if (!scene.IsValid()) return null;
            GameObject[] roots = scene.GetRootGameObjects();
            foreach (GameObject root in roots)
            {
                Transform found = FindInTransformSubtree(root.transform, name);
                if (found != null)
                    return found.gameObject;
            }
            return null;
        }

        private static Transform FindInTransformSubtree(Transform t, string name)
        {
            if (string.Equals(t.name, name, StringComparison.OrdinalIgnoreCase))
                return t;
            for (int i = 0; i < t.childCount; i++)
            {
                Transform found = FindInTransformSubtree(t.GetChild(i), name);
                if (found != null) return found;
            }
            return null;
        }

        public static string EscapeJsonString(string str)
        {
            if (string.IsNullOrEmpty(str)) return str;
            return str.Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\n", "\\n")
                .Replace("\r", "\\r")
                .Replace("\t", "\\t");
        }

        public static Vector3 ParseVector3(string str)
        {
            if (string.IsNullOrEmpty(str)) return Vector3.zero;
            string[] parts = str.Split(',');
            if (parts.Length >= 3)
            {
                float.TryParse(parts[0].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float x);
                float.TryParse(parts[1].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float y);
                float.TryParse(parts[2].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float z);
                return new Vector3(x, y, z);
            }
            return Vector3.zero;
        }

        public static Vector2 ParseVector2(string str)
        {
            if (string.IsNullOrEmpty(str)) return Vector2.zero;
            string[] parts = str.Split(',');
            if (parts.Length >= 2)
            {
                float.TryParse(parts[0].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float x);
                float.TryParse(parts[1].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float y);
                return new Vector2(x, y);
            }
            return Vector2.zero;
        }

        public static Color ParseColor(string str)
        {
            if (string.IsNullOrEmpty(str)) return Color.white;
            string[] parts = str.Split(',');
            float r = 1f, g = 1f, b = 1f, a = 1f;
            if (parts.Length >= 3)
            {
                float.TryParse(parts[0].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out r);
                float.TryParse(parts[1].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out g);
                float.TryParse(parts[2].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out b);
            }
            if (parts.Length >= 4)
            {
                float.TryParse(parts[3].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out a);
            }
            return new Color(r, g, b, a);
        }

        public static Vector4 ParseVector4(string str)
        {
            if (string.IsNullOrEmpty(str)) return Vector4.zero;
            string[] parts = str.Split(',');
            float x = 0f, y = 0f, z = 0f, w = 0f;
            
            if (parts.Length >= 1)
                float.TryParse(parts[0].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out x);
            if (parts.Length >= 2)
                float.TryParse(parts[1].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out y);
            if (parts.Length >= 3)
                float.TryParse(parts[2].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out z);
            if (parts.Length >= 4)
                float.TryParse(parts[3].Trim(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out w);
            
            return new Vector4(x, y, z, w);
        }

        public static string GetDefaultShaderForRenderPipeline()
        {
#if GLADE_SRP
            // Check GraphicsSettings for render pipeline asset
            var renderPipelineAsset = UnityEngine.Rendering.GraphicsSettings.defaultRenderPipeline;
            
            if (renderPipelineAsset != null)
            {
                string assetType = renderPipelineAsset.GetType().Name;
                string assetNamespace = renderPipelineAsset.GetType().Namespace ?? "";
                
                // URP detection
                if (assetType.Contains("UniversalRenderPipelineAsset") || 
                    assetType.Contains("Universal") ||
                    assetNamespace.Contains("Universal"))
                {
                    // Check which URP shader is available
                    if (Shader.Find("Universal Render Pipeline/Lit") != null)
                        return "Universal Render Pipeline/Lit";
                    if (Shader.Find("Universal Render Pipeline/Unlit") != null)
                        return "Universal Render Pipeline/Unlit";
                    return "Universal Render Pipeline/Lit";
                }
                
                // HDRP detection
                if (assetType.Contains("HDRenderPipelineAsset") || 
                    assetType.Contains("HD") ||
                    assetNamespace.Contains("HighDefinition"))
                {
                    if (Shader.Find("HDRP/Lit") != null)
                        return "HDRP/Lit";
                    if (Shader.Find("HDRP/Unlit") != null)
                        return "HDRP/Unlit";
                    return "HDRP/Lit";
                }
            }
#endif
            
            // Check by shader availability (fallback - more reliable)
            if (Shader.Find("Universal Render Pipeline/Lit") != null)
            {
                return "Universal Render Pipeline/Lit";
            }
            
            if (Shader.Find("HDRP/Lit") != null)
            {
                return "HDRP/Lit";
            }
            
            // Default to Built-in Standard
            return "Standard";
        }

        public static object ConvertValueToPropertyType(string valueStr, System.Type targetType)
        {
            // String
            if (targetType == typeof(string))
            {
                return valueStr;
            }
            
            // Boolean
            if (targetType == typeof(bool))
            {
                if (bool.TryParse(valueStr, out bool boolValue))
                    return boolValue;
                throw new ArgumentException($"Cannot convert '{valueStr}' to bool");
            }
            
            // Integer types
            if (targetType == typeof(int))
            {
                if (int.TryParse(valueStr, out int intValue))
                    return intValue;
                throw new ArgumentException($"Cannot convert '{valueStr}' to int");
            }
            
            if (targetType == typeof(float))
            {
                if (float.TryParse(valueStr, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float floatValue))
                    return floatValue;
                throw new ArgumentException($"Cannot convert '{valueStr}' to float");
            }
            
            if (targetType == typeof(Vector3))
            {
                return ParseVector3(valueStr);
            }
            
            if (targetType == typeof(Vector2))
            {
                var vec3 = ParseVector3(valueStr);
                return new Vector2(vec3.x, vec3.y);
            }
            
            if (targetType == typeof(Color))
            {
                return ParseColor(valueStr);
            }
            
            if (targetType == typeof(Quaternion))
            {
                var euler = ParseVector3(valueStr);
                return Quaternion.Euler(euler);
            }
            
            // Enum
            if (targetType.IsEnum)
            {
                try
                {
                    return Enum.Parse(targetType, valueStr, true);
                }
                catch
                {
                    throw new ArgumentException($"Cannot convert '{valueStr}' to enum {targetType.Name}");
                }
            }
            
            // UnityObject types (Sprite, Texture2D, Material, AudioClip, etc.) - try to load from asset path
            if (typeof(UnityEngine.Object).IsAssignableFrom(targetType))
            {
                // Remove quotes if present
                string assetPath = valueStr.Trim().Trim('"');
                
                // Special handling for GameObject, Transform, and Component references
                // These should be resolved from scene hierarchy, not asset paths
                if (targetType == typeof(GameObject) || targetType == typeof(Transform) || typeof(Component).IsAssignableFrom(targetType))
                {
                    // Try to find in scene hierarchy first
                    GameObject foundObj = FindGameObjectByPath(assetPath);
                    if (foundObj != null)
                    {
                        if (targetType == typeof(GameObject))
                            return foundObj;
                        if (targetType == typeof(Transform))
                            return foundObj.transform;
                        
                        // For Component types, try to get the component
                        Component comp = foundObj.GetComponent(targetType);
                        if (comp != null)
                            return comp;
                        
                        // If component not found, throw helpful error
                        throw new ArgumentException($"GameObject '{assetPath}' found, but it does not have a component of type '{targetType.Name}'. Available components: {string.Join(", ", foundObj.GetComponents<Component>().Select(c => c.GetType().Name))}");
                    }
                    
                    // If not found in scene, throw error (don't try asset path for scene objects)
                    throw new ArgumentException($"GameObject or Component not found at path '{assetPath}'. Make sure the GameObject exists in the scene hierarchy (e.g., 'Canvas/Ammo' or 'Canvas/Reload/ammoText').");
                }
                
                // For other UnityObject types (assets), try to load from asset path
                // Ensure path starts with Assets/
                if (!assetPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                {
                    assetPath = "Assets/" + assetPath;
                }
                
                // Try to load the asset (with case-insensitive fallback)
                UnityEngine.Object asset = ToolUtils.LoadAssetAtPathCaseInsensitive<UnityEngine.Object>(assetPath);
                
                if (asset == null)
                {
                    // Try to find similar assets for better error message
                    string fileName = System.IO.Path.GetFileName(assetPath);
                    string searchName = !string.IsNullOrEmpty(fileName) ? System.IO.Path.GetFileNameWithoutExtension(fileName) : "";
                    string suggestion = "";
                    
                    if (!string.IsNullOrEmpty(searchName))
                    {
                        string[] guids = AssetDatabase.FindAssets(searchName);
                        var similarPaths = new List<string>();
                        foreach (var guid in guids.Take(3))
                        {
                            string foundPath = AssetDatabase.GUIDToAssetPath(guid);
                            if (!string.IsNullOrEmpty(foundPath) && !foundPath.StartsWith("Packages/"))
                                similarPaths.Add(foundPath);
                        }
                        if (similarPaths.Count > 0)
                        {
                            suggestion = $" Similar assets found: {string.Join(", ", similarPaths)}";
                        }
                    }
                    
                    throw new ArgumentException($"Asset not found at path '{assetPath}'. Make sure the asset exists and the path is correct (e.g., 'Assets/Sprites/MySprite.png').{suggestion}");
                }
                
                // Special case: If target type is Sprite but asset is Texture2D, automatically convert import settings
                if (targetType == typeof(Sprite) && asset is Texture2D)
                {
                    var importer = AssetImporter.GetAtPath(assetPath) as TextureImporter;
                    if (importer != null && importer.textureType != TextureImporterType.Sprite)
                    {
                        // Convert Texture2D import to Sprite import
                        importer.textureType = TextureImporterType.Sprite;
                        // Default to Single sprite mode if not already set
                        if (importer.spriteImportMode == SpriteImportMode.None)
                        {
                            importer.spriteImportMode = SpriteImportMode.Single;
                        }
                        importer.SaveAndReimport();
                        
                        // Force asset database refresh
                        AssetDatabase.Refresh();
                        
                        // Try to load as Sprite (works for Single sprite mode)
                        Sprite sprite = AssetDatabase.LoadAssetAtPath<Sprite>(assetPath);
                        if (sprite != null)
                        {
                            return sprite;
                        }
                        
                        // If Single mode didn't work, try loading all sub-assets (for Multiple sprite sheets)
                        UnityEngine.Object[] allAssets = AssetDatabase.LoadAllAssetsAtPath(assetPath);
                        foreach (var obj in allAssets)
                        {
                            if (obj is Sprite)
                            {
                                return obj as Sprite;
                            }
                        }
                        
                        // If still no sprite found, throw helpful error
                        throw new ArgumentException($"Converted texture at '{assetPath}' to Sprite import type, but could not load the Sprite. The texture may need to be reimported manually.");
                    }
                    else if (importer != null && importer.textureType == TextureImporterType.Sprite)
                    {
                        // Already Sprite type, but loaded as Texture2D - try loading as Sprite directly
                        Sprite sprite = AssetDatabase.LoadAssetAtPath<Sprite>(assetPath);
                        if (sprite != null)
                        {
                            return sprite;
                        }
                        
                        // Try loading all sub-assets
                        UnityEngine.Object[] allAssets = AssetDatabase.LoadAllAssetsAtPath(assetPath);
                        foreach (var obj in allAssets)
                        {
                            if (obj is Sprite)
                            {
                                return obj as Sprite;
                            }
                        }
                    }
                }
                
                // Check if the loaded asset type matches the target type
                if (!targetType.IsAssignableFrom(asset.GetType()))
                {
                    string additionalHelp = "";
                    if (targetType == typeof(Sprite) && asset is Texture2D)
                    {
                        additionalHelp = " Note: Automatic conversion from Texture2D to Sprite was attempted. If this error persists, the texture may need manual configuration via set_sprite_import_settings.";
                    }
                    throw new ArgumentException($"Asset at path '{assetPath}' is of type '{asset.GetType().Name}' but property requires type '{targetType.Name}'.{additionalHelp}");
                }
                
                return asset;
            }
            
            // Default: try to convert to string and use reflection
            throw new ArgumentException($"Unsupported property type: {targetType.Name}");
        }

        public static List<string> GetPathsFromArgsOrSelection(Dictionary<string, object> args, string key)
        {
            var paths = new List<string>();
            
            if (args.ContainsKey(key) && args[key] != null)
            {
                var pathsObj = args[key];
                if (pathsObj is List<object> pathList)
                {
                    foreach (var p in pathList)
                        if (!string.IsNullOrEmpty(p?.ToString()))
                            paths.Add(p.ToString());
                }
                else if (pathsObj is string pathStr && !string.IsNullOrEmpty(pathStr))
                {
                    if (pathStr.StartsWith("["))
                    {
                        pathStr = pathStr.Trim('[', ']');
                        foreach (var p in pathStr.Split(','))
                        {
                            string cleaned = p.Trim().Trim('"');
                            if (!string.IsNullOrEmpty(cleaned))
                                paths.Add(cleaned);
                        }
                    }
                    else
                    {
                        paths.Add(pathStr);
                    }
                }
            }
            
            // Fall back to selection if no paths provided
            if (paths.Count == 0)
            {
                foreach (var obj in UnityEditor.Selection.gameObjects)
                {
                    if (obj != null)
                        paths.Add(GetGameObjectPath(obj));
                }
            }
            
            return paths;
        }

        public static Bounds GetObjectBounds(GameObject obj)
        {
            Renderer renderer = obj.GetComponent<Renderer>();
            if (renderer != null)
                return renderer.bounds;
            
            Collider collider = obj.GetComponent<Collider>();
            if (collider != null)
                return collider.bounds;
            
            // Fallback: use position with small bounds
            return new Bounds(obj.transform.position, Vector3.one * 0.1f);
        }

        /// <summary>
        /// Gets mesh/renderer bounds in local space (for collider sizing).
        /// Aggregates ALL renderers on this object and its children to handle compound/FBX objects.
        /// Correctly handles negative scale by using lossyScale for world-to-local size conversion.
        /// </summary>
        public static Bounds GetMeshBounds(GameObject obj)
        {
            // Gather ALL renderers on this object and children (handles compound/FBX objects)
            Renderer[] allRenderers = obj.GetComponentsInChildren<Renderer>(includeInactive: false);
            if (allRenderers.Length > 0)
            {
                Bounds combined = allRenderers[0].bounds;
                for (int i = 1; i < allRenderers.Length; i++)
                    combined.Encapsulate(allRenderers[i].bounds);

                // Convert world-space center to local space
                Vector3 localCenter = obj.transform.InverseTransformPoint(combined.center);
                // Convert world-space size to local space using lossyScale (avoids negative size from rotation)
                Vector3 ls = obj.transform.lossyScale;
                Vector3 localSize = new Vector3(
                    Mathf.Abs(ls.x) > 0.0001f ? combined.size.x / Mathf.Abs(ls.x) : combined.size.x,
                    Mathf.Abs(ls.y) > 0.0001f ? combined.size.y / Mathf.Abs(ls.y) : combined.size.y,
                    Mathf.Abs(ls.z) > 0.0001f ? combined.size.z / Mathf.Abs(ls.z) : combined.size.z
                );
                return new Bounds(localCenter, localSize);
            }

            // Fallback: SkinnedMeshRenderer (returns mesh-local bounds directly)
            SkinnedMeshRenderer skinnedRenderer = obj.GetComponentInChildren<SkinnedMeshRenderer>(includeInactive: false);
            if (skinnedRenderer != null && skinnedRenderer.sharedMesh != null)
                return skinnedRenderer.sharedMesh.bounds;

            // Fallback: use small default bounds
            return new Bounds(Vector3.zero, Vector3.one * 0.1f);
        }

        /// <summary>
        /// Checks for collider conflicts on a GameObject.
        /// Returns dictionary with conflict information.
        /// </summary>
        public static Dictionary<string, object> CheckColliderConflicts(GameObject obj)
        {
            var conflicts = new Dictionary<string, object>();
            var existingColliders = new List<string>();
            var warnings = new List<string>();

            // Check for existing colliders
            Collider[] colliders = obj.GetComponents<Collider>();
            foreach (var collider in colliders)
            {
                if (collider != null && collider.enabled)
                {
                    existingColliders.Add(collider.GetType().Name);
                }
            }

            // Check for CharacterController
            CharacterController charController = obj.GetComponent<CharacterController>();
            bool hasCharacterController = charController != null && charController.enabled;

            conflicts["hasColliders"] = existingColliders.Count > 0;
            conflicts["existingColliders"] = existingColliders;
            conflicts["hasCharacterController"] = hasCharacterController;
            conflicts["warnings"] = warnings;

            // Generate warnings
            if (hasCharacterController && existingColliders.Count > 0)
            {
                warnings.Add($"WARNING: GameObject has CharacterController AND {existingColliders.Count} other collider(s). CharacterController includes its own collider - additional colliders may cause conflicts.");
            }
            else if (hasCharacterController)
            {
                warnings.Add("INFO: GameObject has CharacterController (includes built-in collider). Adding additional colliders may cause conflicts.");
            }

            if (existingColliders.Count > 1)
            {
                warnings.Add($"WARNING: GameObject has {existingColliders.Count} colliders. Multiple colliders on the same object may cause unexpected physics behavior.");
            }

            conflicts["warnings"] = warnings;
            conflicts["isConflicted"] = warnings.Count > 0;

            return conflicts;
        }

        /// <summary>
        /// Calculates appropriate collider size/radius/height from bounds for a given collider type.
        /// For CapsuleCollider, automatically detects the dominant axis (X=0, Y=1, Z=2) so
        /// horizontal or depth-oriented objects get the correct capsule orientation.
        /// </summary>
        public static Dictionary<string, object> CalculateColliderSizeFromBounds(Bounds bounds, string colliderType)
        {
            var result = new Dictionary<string, object>();
            Vector3 size = bounds.size;

            switch (colliderType.ToLower())
            {
                case "box":
                    result["center"] = bounds.center;
                    result["size"] = size;
                    break;
                case "sphere":
                    // Use the largest dimension for radius
                    float radius = Mathf.Max(size.x, size.y, size.z) * 0.5f;
                    result["center"] = bounds.center;
                    result["radius"] = radius;
                    break;
                case "capsule":
                {
                    // Detect dominant axis: whichever dimension is longest becomes the capsule's height axis
                    int direction = 1; // Y default (vertical)
                    if (size.x >= size.y && size.x >= size.z)      direction = 0; // X is longest
                    else if (size.z >= size.x && size.z >= size.y) direction = 2; // Z is longest

                    float capsuleHeight, capsuleRadius;
                    if (direction == 0)
                    {
                        capsuleHeight = size.x;
                        capsuleRadius = Mathf.Max(size.y, size.z) * 0.5f;
                    }
                    else if (direction == 2)
                    {
                        capsuleHeight = size.z;
                        capsuleRadius = Mathf.Max(size.x, size.y) * 0.5f;
                    }
                    else
                    {
                        capsuleHeight = size.y;
                        capsuleRadius = Mathf.Max(size.x, size.z) * 0.5f;
                    }

                    result["center"]    = bounds.center;
                    result["radius"]    = capsuleRadius;
                    result["height"]    = capsuleHeight;
                    result["direction"] = direction;
                    break;
                }
                default:
                    result["center"] = bounds.center;
                    result["size"] = size;
                    break;
            }

            return result;
        }

        /// <summary>
        /// Analyzes mesh bounds to suggest the best primitive collider type (Box, Sphere, or Capsule).
        /// Returns a dictionary with suggested type and confidence score.
        /// </summary>
        public static Dictionary<string, object> SuggestPrimitiveColliderType(GameObject obj)
        {
            var result = new Dictionary<string, object>();
            Bounds meshBounds = GetMeshBounds(obj);
            
            if (meshBounds.size.magnitude < 0.01f)
            {
                result["suggestedType"] = "Box";
                result["confidence"] = 0.5f;
                result["reason"] = "No mesh found, defaulting to Box";
                return result;
            }

            Vector3 size = meshBounds.size;
            float maxDim = Mathf.Max(size.x, size.y, size.z);
            float minDim = Mathf.Min(size.x, size.y, size.z);
            float midDim = size.x + size.y + size.z - maxDim - minDim;
            
            // Calculate aspect ratios
            float aspectXY = size.x / (size.y > 0.001f ? size.y : 0.001f);
            float aspectXZ = size.x / (size.z > 0.001f ? size.z : 0.001f);
            float aspectYZ = size.y / (size.z > 0.001f ? size.z : 0.001f);
            
            // Check if dimensions are roughly equal (sphere-like)
            float dimensionVariance = (Mathf.Abs(size.x - size.y) + Mathf.Abs(size.y - size.z) + Mathf.Abs(size.x - size.z)) / maxDim;
            bool isRoughlySpherical = dimensionVariance < 0.2f; // Within 20% variance
            
            // Check if it's capsule-like (one dimension significantly longer, other two similar)
            bool isCapsuleLike = false;
            float capsuleConfidence = 0f;
            if (size.y > size.x * 1.5f && size.y > size.z * 1.5f && Mathf.Abs(size.x - size.z) / maxDim < 0.3f)
            {
                // Y is much longer, X and Z are similar (vertical capsule)
                isCapsuleLike = true;
                capsuleConfidence = 0.8f;
            }
            else if (size.x > size.y * 1.5f && size.x > size.z * 1.5f && Mathf.Abs(size.y - size.z) / maxDim < 0.3f)
            {
                // X is much longer, Y and Z are similar (horizontal capsule)
                isCapsuleLike = true;
                capsuleConfidence = 0.7f;
            }
            else if (size.z > size.x * 1.5f && size.z > size.y * 1.5f && Mathf.Abs(size.x - size.y) / maxDim < 0.3f)
            {
                // Z is much longer, X and Y are similar (depth capsule)
                isCapsuleLike = true;
                capsuleConfidence = 0.7f;
            }

            // Determine best fit
            if (isRoughlySpherical)
            {
                result["suggestedType"] = "Sphere";
                result["confidence"] = 0.9f;
                result["reason"] = $"Mesh is roughly spherical (dimensions: {size.x:F2}, {size.y:F2}, {size.z:F2})";
            }
            else if (isCapsuleLike)
            {
                result["suggestedType"] = "Capsule";
                result["confidence"] = capsuleConfidence;
                result["reason"] = $"Mesh is capsule-like (one dimension significantly longer)";
            }
            else
            {
                result["suggestedType"] = "Box";
                result["confidence"] = 0.8f;
                result["reason"] = $"Mesh is box-like (dimensions: {size.x:F2}, {size.y:F2}, {size.z:F2})";
            }

            result["meshBounds"] = meshBounds;
            return result;
        }

        public static float GetAxisValue(Vector3 v, string axis)
        {
            switch (axis.ToLower())
            {
                case "x": return v.x;
                case "y": return v.y;
                case "z": return v.z;
                default: return 0f;
            }
        }

        public static Vector3 SetAxisValue(Vector3 v, string axis, float value)
        {
            switch (axis.ToLower())
            {
                case "x": v.x = value; break;
                case "y": v.y = value; break;
                case "z": v.z = value; break;
            }
            return v;
        }

        public static void CollectHierarchyPaths(GameObject obj, List<string> paths, bool includeInactive, int maxDepth, int depth)
        {
            if (!includeInactive && !obj.activeInHierarchy) return;
            if (maxDepth >= 0 && depth > maxDepth) return;

            paths.Add(GetGameObjectPath(obj));
            for (int i = 0; i < obj.transform.childCount; i++)
            {
                CollectHierarchyPaths(obj.transform.GetChild(i).gameObject, paths, includeInactive, maxDepth, depth + 1);
            }
        }

        /// <summary>
        /// Parses a bool from a dictionary value that may be a bool, string, or other type.
        /// </summary>
        public static bool ParseBool(object value)
        {
            if (value is bool b) return b;
            if (value != null && bool.TryParse(value.ToString(), out bool v)) return v;
            return false;
        }

        // ----- Argument extraction helpers -----
        // These replace the ~200 hand-rolled `args.ContainsKey(k) ? args[k]?.ToString() : ""`
        // patterns scattered across tool implementations. Centralizing here makes
        // numeric coercion consistent: AI providers send ints as int, floats as
        // float, but JSON round-trips can convert numbers to string.

        /// <summary>True when args has the key with a non-null value.</summary>
        public static bool HasArg(Dictionary<string, object> args, string key)
        {
            return args != null && args.ContainsKey(key) && args[key] != null;
        }

        /// <summary>Extracts a string arg. Returns default when missing or null.</summary>
        public static string GetStringArg(Dictionary<string, object> args, string key, string defaultValue = "")
        {
            if (!HasArg(args, key)) return defaultValue;
            return args[key].ToString();
        }

        /// <summary>
        /// Extracts an int arg, coercing from int, long, float, double, or string.
        /// Returns default when missing or unparseable.
        /// </summary>
        public static int GetIntArg(Dictionary<string, object> args, string key, int defaultValue = 0)
        {
            if (!HasArg(args, key)) return defaultValue;
            object v = args[key];
            if (v is int i) return i;
            if (v is long l) return (int)l;
            if (v is float f) return (int)f;
            if (v is double d) return (int)d;
            if (int.TryParse(v.ToString(), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out int parsed))
                return parsed;
            if (float.TryParse(v.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float fp))
                return (int)fp;
            return defaultValue;
        }

        /// <summary>
        /// Extracts a float arg, coercing from int, long, float, double, or string.
        /// Returns default when missing or unparseable.
        /// </summary>
        public static float GetFloatArg(Dictionary<string, object> args, string key, float defaultValue = 0f)
        {
            if (!HasArg(args, key)) return defaultValue;
            object v = args[key];
            if (v is float f) return f;
            if (v is double d) return (float)d;
            if (v is int i) return i;
            if (v is long l) return l;
            if (float.TryParse(v.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float parsed))
                return parsed;
            return defaultValue;
        }

        /// <summary>
        /// Extracts a bool arg with the same coercion rules as ParseBool.
        /// Returns default when missing.
        /// </summary>
        public static bool GetBoolArg(Dictionary<string, object> args, string key, bool defaultValue = false)
        {
            if (!HasArg(args, key)) return defaultValue;
            object v = args[key];
            if (v is bool b) return b;
            if (bool.TryParse(v.ToString(), out bool parsed)) return parsed;
            return defaultValue;
        }

        /// <summary>
        /// Validates that all required keys exist in args with non-null, non-empty-string values.
        /// Returns null if all present; otherwise returns a ready-to-return CreateErrorResponse JSON.
        /// Usage:  var err = ToolUtils.ValidateRequiredArgs(args, "gameObjectPath", "componentType");
        ///         if (err != null) return err;
        /// </summary>
        public static string ValidateRequiredArgs(Dictionary<string, object> args, params string[] keys)
        {
            foreach (var key in keys)
            {
                if (!HasArg(args, key))
                    return CreateErrorResponse($"{key} is required");
                if (args[key] is string s && string.IsNullOrEmpty(s))
                    return CreateErrorResponse($"{key} is required");
            }
            return null;
        }

        /// <summary>
        /// Records an undo step, marks the asset dirty, and saves the asset database.
        /// Use after mutating any asset (Material, ScriptableObject, AnimatorController, etc.).
        /// Centralizing this trio prevents the "forgot SaveAssets" bug that silently
        /// drops changes when Unity closes without an explicit save.
        /// </summary>
        public static void RecordAndSaveAsset(UnityEngine.Object asset, string undoLabel)
        {
            if (asset == null) return;
            if (!string.IsNullOrEmpty(undoLabel))
                Undo.RecordObject(asset, undoLabel);
            EditorUtility.SetDirty(asset);
            AssetDatabase.SaveAssets();
        }

        /// <summary>
        /// Convenience overload of NormalizeAssetPath that returns just the resolved path
        /// without the actualPath out-param. Use when callers don't need to differentiate
        /// "exact match" from "case-corrected match".
        /// </summary>
        public static string NormalizeAssetPath(string assetPath)
        {
            return NormalizeAssetPath(assetPath, out _);
        }

        public static int ParseLayerMask(object value)
        {
            if (value == null) return ~0;
            if (value is int i) return i;
            if (value is float f) return (int)f;
            string s = value.ToString();
            if (string.IsNullOrEmpty(s) || s.Equals("Everything", StringComparison.OrdinalIgnoreCase)) return ~0;
            if (int.TryParse(s, out int mask)) return mask;
            var parts = s.Split(',');
            var names = parts.Select(p => p.Trim()).Where(p => !string.IsNullOrEmpty(p)).ToArray();
            return LayerMask.GetMask(names);
        }

#if GLADE_INPUT_SYSTEM
        public static UnityEngine.InputSystem.InputActionType ParseInputActionType(string type)
        {
            switch (type.ToLower())
            {
                case "button":
                    return UnityEngine.InputSystem.InputActionType.Button;
                case "pass":
                case "passthrough":
                    return UnityEngine.InputSystem.InputActionType.PassThrough;
                default:
                    return UnityEngine.InputSystem.InputActionType.Value;
            }
        }
#endif

        /// <summary>
        /// Parses a flat JSON object string into a dictionary.
        /// Handles escaped strings; suitable for tool argument payloads.
        /// </summary>
        public static Dictionary<string, object> ParseJsonToDict(string json)
        {
            var dict = new Dictionary<string, object>();
            if (string.IsNullOrEmpty(json) || json == "{}") return dict;

            json = json.Trim();
            if (json.StartsWith("{") && json.EndsWith("}"))
                json = json.Substring(1, json.Length - 2);

            int depth = 0;
            bool inString = false;
            bool escapeNext = false;
            int start = 0;
            var pairs = new List<string>();

            for (int i = 0; i < json.Length; i++)
            {
                char c = json[i];
                if (escapeNext) { escapeNext = false; continue; }
                if (c == '\\') { escapeNext = true; continue; }
                if (c == '"') { inString = !inString; continue; }
                if (!inString)
                {
                    if (c == '{' || c == '[') depth++;
                    else if (c == '}' || c == ']') depth--;
                    else if (c == ',' && depth == 0)
                    {
                        pairs.Add(json.Substring(start, i - start));
                        start = i + 1;
                    }
                }
            }
            if (start < json.Length)
                pairs.Add(json.Substring(start));

            foreach (var pair in pairs)
            {
                int colonIdx = pair.IndexOf(':');
                if (colonIdx > 0)
                {
                    string key = UnescapeJsonString(pair.Substring(0, colonIdx).Trim());
                    string value = pair.Substring(colonIdx + 1).Trim();
                    key = key.Trim('"');
                    dict[key] = ParseJsonValue(value);
                }
            }
            return dict;
        }

        /// <summary>
        /// Parses a JSON array string (e.g. "[{...}, {...}]") into a List<object>.
        /// Objects become Dictionary&lt;string, object&gt;; quoted strings are unescaped.
        /// Returns false when input isn't a JSON array.
        /// </summary>
        public static bool TryParseJsonArrayToList(string json, out List<object> list)
        {
            list = null;
            if (string.IsNullOrWhiteSpace(json)) return false;
            json = json.Trim();
            if (!json.StartsWith("[") || !json.EndsWith("]")) return false;

            string inner = json.Substring(1, json.Length - 2).Trim();
            list = new List<object>();
            if (inner.Length == 0) return true;

            int depth = 0;
            bool inString = false;
            bool escapeNext = false;
            int start = 0;
            var items = new List<string>();

            for (int i = 0; i < inner.Length; i++)
            {
                char c = inner[i];
                if (escapeNext) { escapeNext = false; continue; }
                if (c == '\\') { escapeNext = true; continue; }
                if (c == '"') { inString = !inString; continue; }

                if (!inString)
                {
                    if (c == '{' || c == '[') depth++;
                    else if (c == '}' || c == ']') depth--;
                    else if (c == ',' && depth == 0)
                    {
                        items.Add(inner.Substring(start, i - start));
                        start = i + 1;
                    }
                }
            }
            if (start < inner.Length)
                items.Add(inner.Substring(start));

            foreach (var item in items)
            {
                string trimmed = item.Trim();
                if (trimmed.StartsWith("{") && trimmed.EndsWith("}"))
                {
                    list.Add(ParseJsonToDict(trimmed));
                }
                else if (trimmed.StartsWith("\"") && trimmed.EndsWith("\""))
                {
                    list.Add(UnescapeJsonString(trimmed));
                }
                else
                {
                    list.Add(trimmed);
                }
            }

            return true;
        }

        private static object ParseJsonValue(string value)
        {
            value = value.Trim();
            if (value.StartsWith("\"") && value.EndsWith("\""))
                return UnescapeJsonString(value);
            if (value == "true") return true;
            if (value == "false") return false;
            if (value == "null") return null;
            if (float.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float f))
                return f;
            return value;
        }

        private static string UnescapeJsonString(string str)
        {
            str = str.Trim('"');
            return str.Replace("\\\"", "\"").Replace("\\n", "\n").Replace("\\r", "\r").Replace("\\t", "\t").Replace("\\\\", "\\");
        }

        /// <summary>
        /// Resolves a type string for an EditorCurveBinding. Accepts short names
        /// ("Transform", "SpriteRenderer", "GameObject"), namespaced names
        /// ("UnityEngine.Transform"), assembly-qualified names
        /// ("UnityEngine.Transform, UnityEngine"), and user-defined MonoBehaviour
        /// names. Returns null if the string can't be resolved.
        ///
        /// Differs from FindComponentType: animation curves can target GameObject
        /// (m_IsActive activation curves) which is not a Component-derived type.
        /// </summary>
        public static System.Type FindAnimationBindingType(string typeName)
        {
            if (string.IsNullOrEmpty(typeName)) return null;
            string trimmed = typeName.Trim();

            // 1) Direct lookup (handles assembly-qualified names like "UnityEngine.Transform, UnityEngine")
            System.Type type = System.Type.GetType(trimmed);
            if (type != null && IsValidAnimationBindingType(type)) return type;

            // 2) UnityEngine.* namespace fallback
            type = System.Type.GetType($"UnityEngine.{trimmed}");
            if (type != null && IsValidAnimationBindingType(type)) return type;

            // 3) Reuse the Component resolution chain
            System.Type componentType = FindComponentType(trimmed);
            if (componentType != null) return componentType;

            // 4) Final scan: GameObject and any UnityEngine.Object subtype matched by short name
            foreach (var assembly in System.AppDomain.CurrentDomain.GetAssemblies())
            {
                System.Type[] types;
                try { types = assembly.GetTypes(); }
                catch (System.Reflection.ReflectionTypeLoadException rtle) { types = rtle.Types; }
                catch { continue; }
                if (types == null) continue;

                for (int i = 0; i < types.Length; i++)
                {
                    var t = types[i];
                    if (t == null) continue;
                    if (!IsValidAnimationBindingType(t)) continue;
                    if (t.Name == trimmed) return t;
                }
            }

            return null;
        }

        private static bool IsValidAnimationBindingType(System.Type t)
        {
            if (t == null) return false;
            if (typeof(Component).IsAssignableFrom(t)) return true;
            if (t == typeof(GameObject)) return true;
            return false;
        }

        public static System.Type FindComponentType(string typeName)
        {
            if (string.IsNullOrEmpty(typeName)) return null;

            // 1) Try direct lookup (works for fully-qualified names)
            System.Type type = System.Type.GetType(typeName);
            if (type != null && typeof(Component).IsAssignableFrom(type))
                return type;

            // 2) Try with UnityEngine namespace (common built-in components)
            type = System.Type.GetType($"UnityEngine.{typeName}");
            if (type != null && typeof(Component).IsAssignableFrom(type))
                return type;

            // 3) Try assembly GetType for fully-qualified names
            foreach (var assembly in System.AppDomain.CurrentDomain.GetAssemblies())
            {
                try
                {
                    type = assembly.GetType(typeName);
                    if (type != null && typeof(Component).IsAssignableFrom(type))
                        return type;

                    type = assembly.GetType($"UnityEngine.{typeName}");
                    if (type != null && typeof(Component).IsAssignableFrom(type))
                        return type;
                }
                catch { }
            }

            // 4) FINAL fallback: scan all loaded types by short Name (lets you pass "PlayerMovement" instead of namespace-qualified name).
            // This is slower but makes tools more forgiving. If multiple matches exist, prefer first found.
            foreach (var assembly in System.AppDomain.CurrentDomain.GetAssemblies())
            {
                try
                {
                    var types = assembly.GetTypes();
                    for (int i = 0; i < types.Length; i++)
                    {
                        var t = types[i];
                        if (t == null) continue;
                        if (!typeof(Component).IsAssignableFrom(t)) continue;
                        if (t.Name == typeName)
                            return t;
                    }
                }
                catch (System.Reflection.ReflectionTypeLoadException rtle)
                {
                    // Some assemblies may fail to load all types; still scan what we can.
                    var types = rtle.Types;
                    if (types != null)
                    {
                        for (int i = 0; i < types.Length; i++)
                        {
                            var t = types[i];
                            if (t == null) continue;
                            if (!typeof(Component).IsAssignableFrom(t)) continue;
                            if (t.Name == typeName)
                                return t;
                        }
                    }
                }
                catch { }
            }

            return null;
        }

        public static string FindPrefabPathByName(string prefabName, out List<string> matches)
        {
            matches = new List<string>();
            if (string.IsNullOrEmpty(prefabName))
            {
                return null;
            }

            string[] guids = AssetDatabase.FindAssets($"t:Prefab {prefabName}");
            if (guids == null || guids.Length == 0)
            {
                return null;
            }

            foreach (var guid in guids)
            {
                var path = AssetDatabase.GUIDToAssetPath(guid);
                if (!string.IsNullOrEmpty(path))
                {
                    matches.Add(path);
                }
            }

            if (matches.Count == 0)
            {
                return null;
            }

            var exactMatches = matches
                .Where(p => string.Equals(System.IO.Path.GetFileNameWithoutExtension(p), prefabName, StringComparison.OrdinalIgnoreCase))
                .OrderBy(p => p.Length)
                .ToList();

            if (exactMatches.Count > 0)
            {
                matches = exactMatches;
            }

            return matches.FirstOrDefault();
        }

        /// <summary>
        /// Loads an asset at the given path with case-insensitive matching.
        /// If the exact path doesn't work, searches for a case-insensitive match.
        /// This helps when the AI provides paths with incorrect casing.
        /// </summary>
        public static T LoadAssetAtPathCaseInsensitive<T>(string assetPath) where T : UnityEngine.Object
        {
            if (string.IsNullOrEmpty(assetPath))
                return null;

            // Normalize path
            if (!assetPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                assetPath = "Assets/" + assetPath;
            
            // Normalize path separators
            assetPath = assetPath.Replace('\\', '/');

            // Try exact path first (fastest)
            T asset = AssetDatabase.LoadAssetAtPath<T>(assetPath);
            if (asset != null)
                return asset;

            // If exact path fails, try case-insensitive search
            // Get the filename and directory
            string fileName = System.IO.Path.GetFileName(assetPath);
            string directory = System.IO.Path.GetDirectoryName(assetPath)?.Replace('\\', '/');
            
            if (string.IsNullOrEmpty(fileName) || string.IsNullOrEmpty(directory))
                return null;

            // Search for assets with matching filename (case-insensitive)
            // First try searching in the specified directory
            string[] guids = AssetDatabase.FindAssets(System.IO.Path.GetFileNameWithoutExtension(fileName), new[] { directory });
            
            // If no results, try searching in Assets/ (broader search for directory case mismatches)
            if (guids == null || guids.Length == 0)
            {
                guids = AssetDatabase.FindAssets(System.IO.Path.GetFileNameWithoutExtension(fileName));
            }
            
            foreach (var guid in guids)
            {
                string foundPath = AssetDatabase.GUIDToAssetPath(guid);
                if (string.IsNullOrEmpty(foundPath) || foundPath.StartsWith("Packages/"))
                    continue;

                // Check if filename matches (case-insensitive)
                string foundFileName = System.IO.Path.GetFileName(foundPath);
                if (string.Equals(foundFileName, fileName, StringComparison.OrdinalIgnoreCase))
                {
                    // Also check directory matches (case-insensitive)
                    string foundDir = System.IO.Path.GetDirectoryName(foundPath)?.Replace('\\', '/');
                    if (string.Equals(foundDir, directory, StringComparison.OrdinalIgnoreCase))
                    {
                        asset = AssetDatabase.LoadAssetAtPath<T>(foundPath);
                        if (asset != null)
                            return asset;
                    }
                }
            }

            return null;
        }

        /// <summary>
        /// Normalizes an asset path to ensure consistent format (forward slashes, Assets/ prefix).
        /// Also attempts to find the correct case if the path doesn't exist exactly.
        /// </summary>
        public static string NormalizeAssetPath(string assetPath, out string actualPath)
        {
            actualPath = null;
            if (string.IsNullOrEmpty(assetPath))
                return assetPath;

            // Normalize separators
            string normalized = assetPath.Replace('\\', '/').Trim();
            
            // Ensure Assets/ prefix
            if (!normalized.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                normalized = "Assets/" + normalized;

            // Try to find actual path with correct casing
            string fileName = System.IO.Path.GetFileName(normalized);
            string directory = System.IO.Path.GetDirectoryName(normalized)?.Replace('\\', '/');
            
            if (!string.IsNullOrEmpty(fileName) && !string.IsNullOrEmpty(directory))
            {
                // Search for the file
                string[] guids = AssetDatabase.FindAssets(System.IO.Path.GetFileNameWithoutExtension(fileName), new[] { directory });
                
                foreach (var guid in guids)
                {
                    string foundPath = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(foundPath))
                        continue;

                    string foundFileName = System.IO.Path.GetFileName(foundPath);
                    string foundDir = System.IO.Path.GetDirectoryName(foundPath)?.Replace('\\', '/');
                    
                    if (string.Equals(foundFileName, fileName, StringComparison.OrdinalIgnoreCase) &&
                        string.Equals(foundDir, directory, StringComparison.OrdinalIgnoreCase))
                    {
                        actualPath = foundPath;
                        return foundPath; // Return the actual path with correct casing
                    }
                }
            }

            // If we couldn't find a match, return normalized path
            actualPath = normalized;
            return normalized;
        }

        public static string SerializeSerializedPropertyValue(UnityEditor.SerializedProperty prop)
        {
            switch (prop.propertyType)
            {
                case UnityEditor.SerializedPropertyType.Integer:
                    return prop.intValue.ToString(System.Globalization.CultureInfo.InvariantCulture);
                case UnityEditor.SerializedPropertyType.Boolean:
                    return prop.boolValue.ToString().ToLower();
                case UnityEditor.SerializedPropertyType.Float:
                    return prop.floatValue.ToString(System.Globalization.CultureInfo.InvariantCulture);
                case UnityEditor.SerializedPropertyType.String:
                    return $"\"{EscapeJsonString(prop.stringValue)}\"";
                case UnityEditor.SerializedPropertyType.Color:
                    var c = prop.colorValue;
                    return $"\"{c.r.ToString(System.Globalization.CultureInfo.InvariantCulture)},{c.g.ToString(System.Globalization.CultureInfo.InvariantCulture)},{c.b.ToString(System.Globalization.CultureInfo.InvariantCulture)},{c.a.ToString(System.Globalization.CultureInfo.InvariantCulture)}\"";
                case UnityEditor.SerializedPropertyType.ObjectReference:
                    return prop.objectReferenceValue != null ? $"\"{EscapeJsonString(prop.objectReferenceValue.name)}\"" : "null";
                case UnityEditor.SerializedPropertyType.Vector2:
                    var v2 = prop.vector2Value;
                    return $"\"{v2.x.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v2.y.ToString(System.Globalization.CultureInfo.InvariantCulture)}\"";
                case UnityEditor.SerializedPropertyType.Vector3:
                    var v3 = prop.vector3Value;
                    return $"\"{v3.x.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v3.y.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v3.z.ToString(System.Globalization.CultureInfo.InvariantCulture)}\"";
                case UnityEditor.SerializedPropertyType.Vector4:
                    var v4 = prop.vector4Value;
                    return $"\"{v4.x.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v4.y.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v4.z.ToString(System.Globalization.CultureInfo.InvariantCulture)},{v4.w.ToString(System.Globalization.CultureInfo.InvariantCulture)}\"";
                case UnityEditor.SerializedPropertyType.Enum:
                    if (prop.enumValueIndex < 0 || prop.enumValueIndex >= prop.enumNames.Length)
                        return "\"\"";
                    return $"\"{EscapeJsonString(prop.enumNames[prop.enumValueIndex])}\"";
                default:
                    return $"\"{EscapeJsonString(prop.displayName)}\"";
            }
        }
    }
}
