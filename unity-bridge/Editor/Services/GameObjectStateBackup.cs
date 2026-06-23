using System;
using System.IO;
using System.Text;
using UnityEngine;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine.SceneManagement;
using GladeAgenticAI.Bridge;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Handles backup and restore of GameObject state
    /// </summary>
    public static class GameObjectStateBackup
    {
        private static readonly string BACKUP_ROOT = ".gladekit-backups";
        
        /// <summary>
        /// Capture current state of a GameObject
        /// </summary>
        public static GameObjectStateData CaptureState(GameObject obj)
        {
            if (obj == null) return null;
            
            Transform t = obj.transform;
            string parentPath = t.parent != null ? ToolUtils.GetGameObjectPath(t.parent.gameObject) : null;
            
            return new GameObjectStateData
            {
                name = obj.name,
                path = ToolUtils.GetGameObjectPath(obj),
                active = obj.activeSelf,
                position = new Vector3Data(t.position),
                rotation = new Vector3Data(t.rotation.eulerAngles),
                scale = new Vector3Data(t.localScale),
                localPosition = new Vector3Data(t.localPosition),
                localRotation = new Vector3Data(t.localRotation.eulerAngles),
                localScale = new Vector3Data(t.localScale),
                parentPath = parentPath,
                layer = obj.layer,
                tag = obj.tag,
                components = CaptureComponentStates(obj)
            };
        }
        
        /// <summary>
        /// Save GameObject state using PrefabUtility for complete serialization
        /// This preserves ALL state including references, child objects, and all properties
        /// Uses temporary prefab files in Assets/Temp/ that can be cleaned up later
        /// Avoids scene operations to prevent FMOD errors
        /// </summary>
        public static string SaveState(GameObject obj, string turnId)
        {
            if (obj == null) return null;
            
            // Get prefab path under Assets/Temp/ (required for Unity's AssetDatabase)
            // We'll clean these up later, but they're in a temp folder
            string prefabPath = GetPrefabBackupPath(turnId, ToolUtils.GetGameObjectPath(obj));
            string prefabDir = Path.GetDirectoryName(prefabPath);
            
            // Ensure directory exists
            if (!Directory.Exists(prefabDir))
            {
                Directory.CreateDirectory(prefabDir);
            }
            
            // Also save JSON metadata for path/name lookup
            string backupPath = GetStateBackupPath(turnId, ToolUtils.GetGameObjectPath(obj));
            string backupDir = Path.GetDirectoryName(backupPath);
            
            if (!Directory.Exists(backupDir))
            {
                Directory.CreateDirectory(backupDir);
            }
            
            try
            {
                // Use PrefabUtility to save as prefab - this doesn't require scene operations
                // PrefabUtility.SaveAsPrefabAsset saves the GameObject AND all its children
                int childCount = obj.transform.childCount;
                GameObject prefab = PrefabUtility.SaveAsPrefabAsset(obj, prefabPath);
                
                if (prefab != null)
                {
                    // Refresh AssetDatabase so Unity recognizes the new prefab
                    AssetDatabase.Refresh();
                    AssetDatabase.SaveAssets();
                    
                    // Verify children were captured
                    int prefabChildCount = prefab.transform.childCount;
                    Debug.Log($"[GameObjectStateBackup] Created prefab backup: {prefabPath} (captured {childCount} children, prefab has {prefabChildCount} children)");
                    
                    // Save JSON metadata
                    GameObjectStateData state = CaptureState(obj);
                    if (state != null)
                    {
                        // Store prefab path in prefabPath field
                        state.prefabPath = prefabPath;
                        string json = JsonUtility.ToJson(state, true);
                        File.WriteAllText(backupPath, json);
                    }
                    
                    return prefabPath;
                }
            }
            catch (Exception e)
            {
                Debug.LogError($"[GameObjectStateBackup] Failed to create prefab backup: {e.Message}");
                // Fallback to JSON-only backup
                GameObjectStateData state = CaptureState(obj);
                if (state != null)
                {
                    string json = JsonUtility.ToJson(state, true);
                    File.WriteAllText(backupPath, json);
                    return backupPath;
                }
            }
            
            return null;
        }
        
        /// <summary>
        /// Load GameObject state from backup file (JSON or Prefab)
        /// </summary>
        public static GameObjectStateData LoadState(string backupPath)
        {
            // Try JSON file first (contains metadata and prefab path)
            if (File.Exists(backupPath))
            {
                try
                {
                    string json = File.ReadAllText(backupPath);
                    GameObjectStateData state = JsonUtility.FromJson<GameObjectStateData>(json);
                    
                    // If prefab path is stored but JSON path was provided, update it
                    if (state != null && !string.IsNullOrEmpty(state.prefabPath))
                    {
                        // Ensure prefab path is correct (might be .json in backupPath, need .prefab)
                        string prefabPath = backupPath.Replace(".json", ".prefab");
                        if (File.Exists(prefabPath))
                        {
                            state.prefabPath = prefabPath;
                        }
                        else if (File.Exists(state.prefabPath))
                        {
                            // Use stored path if it exists
                        }
                        else
                        {
                            // Prefab not found, clear the path to use component-based restoration
                            state.prefabPath = null;
                        }
                    }
                    
                    return state;
                }
                catch (Exception e)
                {
                    Debug.LogError($"[GameObjectStateBackup] Failed to load state from {backupPath}: {e.Message}");
                }
            }
            
            // Try prefab file directly (if JSON path was .prefab)
            string prefabPathDirect = backupPath.Replace(".json", ".prefab");
            if (File.Exists(prefabPathDirect))
            {
                // Create minimal state from prefab (no scene operations needed)
                GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPathDirect);
                if (prefab != null)
                {
                    GameObjectStateData state = new GameObjectStateData
                    {
                        name = prefab.name,
                        prefabPath = prefabPathDirect,
                        active = prefab.activeSelf,
                        layer = prefab.layer,
                        tag = prefab.tag
                    };
                    return state;
                }
            }
            
            Debug.LogError($"[GameObjectStateBackup] Backup file not found: {backupPath}");
            return null;
        }
        
        /// <summary>
        /// Restore GameObject state
        /// </summary>
        public static bool RestoreState(GameObjectStateData state)
        {
            if (state == null) return false;
            
            GameObject obj = ToolUtils.FindGameObjectByPath(state.path);
            if (obj == null)
            {
                Debug.LogWarning($"[GameObjectStateBackup] GameObject not found: {state.path}");
                return false;
            }
            
            // Restore transform
            obj.transform.position = new Vector3(state.position.x, state.position.y, state.position.z);
            obj.transform.rotation = Quaternion.Euler(state.rotation.x, state.rotation.y, state.rotation.z);
            obj.transform.localScale = new Vector3(state.scale.x, state.scale.y, state.scale.z);
            
            // Restore parent
            if (string.IsNullOrEmpty(state.parentPath))
            {
                obj.transform.SetParent(null);
            }
            else
            {
                GameObject parent = ToolUtils.FindGameObjectByPath(state.parentPath);
                obj.transform.SetParent(parent != null ? parent.transform : null);
            }
            
            // Restore other properties
            obj.SetActive(state.active);
            obj.layer = state.layer;
            obj.tag = state.tag;
            
            // Restore components (if needed)
            // This is more complex and may need per-component handling
            
            return true;
        }
        
        /// <summary>
        /// Restore GameObject state to a specific GameObject (for recreating deleted objects)
        /// Uses PrefabUtility for complete state restoration including all references and properties
        /// Avoids scene operations to prevent FMOD errors
        /// Returns the GameObject (may be a new one if restored from prefab or recreated as primitive)
        /// </summary>
        public static GameObject RestoreStateToGameObject(GameObject obj, GameObjectStateData state)
        {
            if (obj == null || state == null) return null;
            
            // If we have a prefab backup, use it for complete restoration
            // Check if prefab file exists (Unity AssetDatabase path)
            bool prefabExists = !string.IsNullOrEmpty(state.prefabPath) && 
                               (File.Exists(state.prefabPath) || AssetDatabase.LoadAssetAtPath<GameObject>(state.prefabPath) != null);
            
            if (prefabExists && state.prefabPath.EndsWith(".prefab"))
            {
                try
                {
                    // Load the prefab (no scene operations needed)
                    GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(state.prefabPath);
                    if (prefab != null)
                    {
                        // Destroy the temporary GameObject
                        UnityEngine.Object.DestroyImmediate(obj);
                        
                        // Instantiate from prefab - this restores EVERYTHING including all children
                        // PrefabUtility.InstantiatePrefab instantiates the entire hierarchy
                        GameObject restored = PrefabUtility.InstantiatePrefab(prefab) as GameObject;
                        if (restored != null)
                        {
                            // Break prefab connection so it becomes a regular scene object
                            // This prevents it from being a prefab instance
                            PrefabUtility.UnpackPrefabInstance(restored, PrefabUnpackMode.Completely, InteractionMode.AutomatedAction);
                            
                            restored.name = state.name;
                            
                            // Verify children were restored
                            int restoredChildCount = restored.transform.childCount;
                            int prefabChildCount = prefab.transform.childCount;
                            Debug.Log($"[GameObjectStateBackup] Restored GameObject from prefab: {state.name} (prefab had {prefabChildCount} children, restored has {restoredChildCount} children)");
                            
                            // Restore parent
                            if (string.IsNullOrEmpty(state.parentPath))
                            {
                                restored.transform.SetParent(null);
                            }
                            else
                            {
                                GameObject parent = ToolUtils.FindGameObjectByPath(state.parentPath);
                                restored.transform.SetParent(parent != null ? parent.transform : null);
                            }
                            
                            // Restore transform (prefab might have different transform)
                            if (state.localPosition != null)
                            {
                                restored.transform.localPosition = new Vector3(state.localPosition.x, state.localPosition.y, state.localPosition.z);
                            }
                            else if (state.position != null)
                            {
                                restored.transform.position = new Vector3(state.position.x, state.position.y, state.position.z);
                            }
                            
                            if (state.localRotation != null)
                            {
                                restored.transform.localRotation = Quaternion.Euler(state.localRotation.x, state.localRotation.y, state.localRotation.z);
                            }
                            else if (state.rotation != null)
                            {
                                restored.transform.rotation = Quaternion.Euler(state.rotation.x, state.rotation.y, state.rotation.z);
                            }
                            
                            if (state.localScale != null)
                            {
                                restored.transform.localScale = new Vector3(state.localScale.x, state.localScale.y, state.localScale.z);
                            }
                            else if (state.scale != null)
                            {
                                restored.transform.localScale = new Vector3(state.scale.x, state.scale.y, state.scale.z);
                            }
                            
                            // Restore other properties
                            restored.SetActive(state.active);
                            restored.layer = state.layer;
                            restored.tag = state.tag;
                            
                            Debug.Log($"[GameObjectStateBackup] Restored GameObject from prefab: {state.name} (complete state with all children)");
                            return restored;
                        }
                    }
                }
                catch (Exception e)
                {
                    Debug.LogError($"[GameObjectStateBackup] Failed to restore from prefab: {e.Message}");
                    // Fall through to component-based restoration
                }
            }
            
            // Fallback to component-based restoration if prefab not available
            // Set name
            obj.name = state.name;
            
            // Restore parent first (so path can be resolved correctly)
            if (string.IsNullOrEmpty(state.parentPath))
            {
                obj.transform.SetParent(null);
            }
            else
            {
                GameObject parent = ToolUtils.FindGameObjectByPath(state.parentPath);
                obj.transform.SetParent(parent != null ? parent.transform : null);
            }
            
            // Restore transform - prefer local values if available
            if (state.localPosition != null)
            {
                obj.transform.localPosition = new Vector3(state.localPosition.x, state.localPosition.y, state.localPosition.z);
            }
            else if (state.position != null)
            {
                obj.transform.position = new Vector3(state.position.x, state.position.y, state.position.z);
            }
            
            if (state.localRotation != null)
            {
                obj.transform.localRotation = Quaternion.Euler(state.localRotation.x, state.localRotation.y, state.localRotation.z);
            }
            else if (state.rotation != null)
            {
                obj.transform.rotation = Quaternion.Euler(state.rotation.x, state.rotation.y, state.rotation.z);
            }
            
            if (state.localScale != null)
            {
                obj.transform.localScale = new Vector3(state.localScale.x, state.localScale.y, state.localScale.z);
            }
            else if (state.scale != null)
            {
                obj.transform.localScale = new Vector3(state.scale.x, state.scale.y, state.scale.z);
            }
            
            // Restore other properties
            obj.SetActive(state.active);
            obj.layer = state.layer;
            obj.tag = state.tag;
            
            // Check if this was a Unity primitive (Cube, Sphere, Capsule, Cylinder, Plane, Quad)
            // Primitives have MeshFilter + MeshRenderer + Collider
            bool isPrimitive = false;
            PrimitiveType primitiveType = PrimitiveType.Cube;
            if (state.components != null && state.components.Length > 0)
            {
                bool hasMeshFilter = false;
                bool hasMeshRenderer = false;
                bool hasBoxCollider = false;
                bool hasSphereCollider = false;
                bool hasCapsuleCollider = false;
                bool hasMeshCollider = false;
                int colliderCount = 0;
                
                foreach (var comp in state.components)
                {
                    if (comp == null || string.IsNullOrEmpty(comp.type)) continue;
                    if (comp.type.Contains("MeshFilter")) hasMeshFilter = true;
                    if (comp.type.Contains("MeshRenderer")) hasMeshRenderer = true;
                    if (comp.type.Contains("BoxCollider"))
                    {
                        hasBoxCollider = true;
                        colliderCount++;
                    }
                    if (comp.type.Contains("SphereCollider"))
                    {
                        hasSphereCollider = true;
                        colliderCount++;
                    }
                    if (comp.type.Contains("CapsuleCollider"))
                    {
                        hasCapsuleCollider = true;
                        colliderCount++;
                    }
                    if (comp.type.Contains("MeshCollider"))
                    {
                        hasMeshCollider = true;
                        colliderCount++;
                    }
                }
                
                // Detect primitive type by collider
                // Unity primitives: Cube (BoxCollider), Sphere (SphereCollider), Capsule (CapsuleCollider),
                //                  Cylinder (BoxCollider), Plane (BoxCollider), Quad (no collider by default)
                if (hasMeshFilter && hasMeshRenderer)
                {
                    // Cube and Cylinder both have BoxCollider, but Cylinder is taller
                    // Plane also has BoxCollider but is flat
                    // We'll use BoxCollider for Cube by default, but this is a limitation
                    // For more accuracy, we'd need to check mesh geometry or store primitive type
                    if (hasBoxCollider && colliderCount == 1)
                    {
                        // Could be Cube, Cylinder, or Plane - default to Cube
                        // TODO: Store primitive type in backup for accurate restoration
                        isPrimitive = true;
                        primitiveType = PrimitiveType.Cube;
                    }
                    else if (hasSphereCollider)
                    {
                        isPrimitive = true;
                        primitiveType = PrimitiveType.Sphere;
                    }
                    else if (hasCapsuleCollider)
                    {
                        isPrimitive = true;
                        primitiveType = PrimitiveType.Capsule;
                    }
                    else if (!hasBoxCollider && !hasSphereCollider && !hasCapsuleCollider && !hasMeshCollider)
                    {
                        // Quad has no collider by default
                        isPrimitive = true;
                        primitiveType = PrimitiveType.Quad;
                    }
                }
            }
            
            // If it's a primitive, recreate it properly
            if (isPrimitive)
            {
                // Destroy the empty GameObject and recreate as primitive
                string savedName = obj.name;
                UnityEngine.Object.DestroyImmediate(obj);
                obj = GameObject.CreatePrimitive(primitiveType);
                obj.name = savedName;
                
                // Restore transform again (since we recreated the object)
                if (state.localPosition != null)
                {
                    obj.transform.localPosition = new Vector3(state.localPosition.x, state.localPosition.y, state.localPosition.z);
                }
                else if (state.position != null)
                {
                    obj.transform.position = new Vector3(state.position.x, state.position.y, state.position.z);
                }
                
                if (state.localRotation != null)
                {
                    obj.transform.localRotation = Quaternion.Euler(state.localRotation.x, state.localRotation.y, state.localRotation.z);
                }
                else if (state.rotation != null)
                {
                    obj.transform.rotation = Quaternion.Euler(state.rotation.x, state.rotation.y, state.rotation.z);
                }
                
                if (state.localScale != null)
                {
                    obj.transform.localScale = new Vector3(state.localScale.x, state.localScale.y, state.localScale.z);
                }
                else if (state.scale != null)
                {
                    obj.transform.localScale = new Vector3(state.scale.x, state.scale.y, state.scale.z);
                }
            }
            else
            {
                // Recreate components for non-primitives
                if (state.components != null && state.components.Length > 0)
                {
                    foreach (var componentState in state.components)
                    {
                        if (componentState == null || string.IsNullOrEmpty(componentState.type)) continue;
                        
                        // Skip Transform (always present)
                        if (componentState.type == "UnityEngine.Transform") continue;
                        
                        try
                        {
                            // Try to get type from Unity assemblies
                            Type componentType = null;
                            
                            // Try common Unity component types first (most reliable)
                            if (componentState.type.Contains("MeshFilter"))
                                componentType = typeof(MeshFilter);
                            else if (componentState.type.Contains("MeshRenderer"))
                                componentType = typeof(MeshRenderer);
                            else if (componentState.type.Contains("BoxCollider"))
                                componentType = typeof(BoxCollider);
                            else if (componentState.type.Contains("SphereCollider"))
                                componentType = typeof(SphereCollider);
                            else if (componentState.type.Contains("CapsuleCollider"))
                                componentType = typeof(CapsuleCollider);
                            else if (componentState.type.Contains("MeshCollider"))
                                componentType = typeof(MeshCollider);
                            else if (componentState.type.Contains("Rigidbody"))
                                componentType = typeof(Rigidbody);
                            else if (componentState.type.Contains("Light"))
                                componentType = typeof(Light);
                            else if (componentState.type.Contains("Camera"))
                                componentType = typeof(Camera);
                            else if (componentState.type.Contains("AudioSource"))
                                componentType = typeof(AudioSource);
                            // UI Components
                            else if (componentState.type.Contains("Canvas"))
                                componentType = typeof(Canvas);
#if GLADE_UGUI
                            else if (componentState.type.Contains("Button"))
                                componentType = typeof(UnityEngine.UI.Button);
                            else if (componentState.type.Contains("Image"))
                                componentType = typeof(UnityEngine.UI.Image);
                            else if (componentState.type.Contains("Text") && !componentState.type.Contains("Mesh"))
                                componentType = typeof(UnityEngine.UI.Text);
#endif
                            else if (componentState.type.Contains("TextMeshPro"))
                            {
                                // TextMeshPro is optional - resolve dynamically
                                componentType = Type.GetType("TMPro.TextMeshProUGUI, Unity.TextMeshPro");
                                if (componentType == null)
                                    componentType = Type.GetType("TMPro.TextMeshProUGUI, Assembly-CSharp");
                            }
                            else if (componentState.type.Contains("RectTransform"))
                                componentType = typeof(RectTransform);
#if GLADE_UGUI
                            else if (componentState.type.Contains("ScrollRect"))
                                componentType = typeof(UnityEngine.UI.ScrollRect);
                            else if (componentState.type.Contains("Slider"))
                                componentType = typeof(UnityEngine.UI.Slider);
                            else if (componentState.type.Contains("Toggle"))
                                componentType = typeof(UnityEngine.UI.Toggle);
                            else if (componentState.type.Contains("InputField"))
                                componentType = typeof(UnityEngine.UI.InputField);
#endif
                            else
                            {
                                // Try Type.GetType with various assembly names
                                componentType = Type.GetType(componentState.type);
                                if (componentType == null)
                                    componentType = Type.GetType(componentState.type + ", UnityEngine");
                                if (componentType == null)
                                    componentType = Type.GetType(componentState.type + ", UnityEngine.CoreModule");
                                if (componentType == null)
                                    componentType = Type.GetType(componentState.type + ", Assembly-CSharp");
                                if (componentType == null)
                                {
                                    // Try searching in all loaded assemblies (for custom scripts)
                                    foreach (var assembly in System.AppDomain.CurrentDomain.GetAssemblies())
                                    {
                                        componentType = assembly.GetType(componentState.type);
                                        if (componentType != null) break;
                                    }
                                }
                            }
                            
                            if (componentType != null && !obj.GetComponent(componentType))
                            {
                                Component addedComponent = obj.AddComponent(componentType);
                                
                                // Restore component properties if available
                                if (addedComponent != null && !string.IsNullOrEmpty(componentState.propertiesJson))
                                {
                                    try
                                    {
                                        // Use JsonUtility to restore properties
                                        JsonUtility.FromJsonOverwrite(componentState.propertiesJson, addedComponent);
                                        Debug.Log($"[GameObjectStateBackup] Restored component with properties: {componentState.type}");
                                    }
                                    catch (Exception e)
                                    {
                                        Debug.LogWarning($"[GameObjectStateBackup] Failed to restore properties for {componentState.type}: {e.Message}");
                                        Debug.Log($"[GameObjectStateBackup] Component added but properties not restored: {componentState.type}");
                                    }
                                }
                                else
                                {
                                    Debug.Log($"[GameObjectStateBackup] Restored component: {componentState.type}");
                                }
                            }
                            else if (componentType == null)
                            {
                                Debug.LogWarning($"[GameObjectStateBackup] Could not resolve component type: {componentState.type}");
                            }
                            else
                            {
                                Debug.Log($"[GameObjectStateBackup] Component already exists: {componentState.type}");
                            }
                        }
                        catch (Exception e)
                        {
                            Debug.LogWarning($"[GameObjectStateBackup] Failed to restore component {componentState.type}: {e.Message}");
                        }
                    }
                }
            }
            
            return obj;
        }
        
        private static ComponentStateData[] CaptureComponentStates(GameObject obj)
        {
            // Capture component states including properties
            Component[] components = obj.GetComponents<Component>();
            ComponentStateData[] states = new ComponentStateData[components.Length];
            
            for (int i = 0; i < components.Length; i++)
            {
                if (components[i] == null) continue;
                
                // Capture component type
                string componentType = components[i].GetType().FullName;
                
                // Skip Transform - it's always present and can't be serialized with JsonUtility
                // Also skip other Unity engine types that JsonUtility can't handle
                if (componentType == "UnityEngine.Transform" || 
                    componentType == "UnityEngine.MeshFilter" ||
                    componentType == "UnityEngine.MeshRenderer" ||
                    componentType == "UnityEngine.BoxCollider" ||
                    componentType == "UnityEngine.SphereCollider" ||
                    componentType == "UnityEngine.CapsuleCollider" ||
                    componentType == "UnityEngine.MeshCollider")
                {
                    // These are handled by the scene system, no need to serialize
                    states[i] = new ComponentStateData
                    {
                        type = componentType,
                        propertiesJson = ""
                    };
                    continue;
                }
                
                // Capture component properties using Unity's JsonUtility
                // This captures all serialized fields (public and [SerializeField])
                string propertiesJson = "";
                try
                {
                    // Use JsonUtility to serialize the component
                    // Note: This only works for serializable fields and custom scripts
                    propertiesJson = JsonUtility.ToJson(components[i], false);
                }
                catch (Exception e)
                {
                    // Silently skip - engine types can't be serialized, that's expected
                    // Only log if it's not an engine type (might be a custom script issue)
                    if (!componentType.StartsWith("UnityEngine."))
                    {
                        Debug.LogWarning($"[GameObjectStateBackup] Failed to serialize component {componentType}: {e.Message}");
                    }
                }
                
                states[i] = new ComponentStateData
                {
                    type = componentType,
                    propertiesJson = propertiesJson
                };
            }
            
            return states;
        }
        
        private static string GetStateBackupPath(string turnId, string gameObjectPath)
        {
            string safePath = gameObjectPath.Replace('/', '_').Replace('\\', '_');
            return Path.Combine(BACKUP_ROOT, BackupManager.TurnSubdir(turnId), "gameobjects", $"{safePath}.json");
        }
        
        /// <summary>
        /// Get prefab backup path under Assets/Temp/ (required for Unity's AssetDatabase)
        /// These are temporary files that can be cleaned up later
        /// </summary>
        private static string GetPrefabBackupPath(string turnId, string gameObjectPath)
        {
            string safePath = gameObjectPath.Replace('/', '_').Replace('\\', '_');
            // Create under Assets/Temp/GladeKitBackups/ so Unity can manage it
            // These are temporary and can be cleaned up
            string prefabPath = Path.Combine("Assets", "Temp", "GladeKitBackups", BackupManager.TurnSubdir(turnId), $"{safePath}.prefab");
            return prefabPath;
        }
    }
}
