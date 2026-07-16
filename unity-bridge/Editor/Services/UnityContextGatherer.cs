using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using UnityEngine.SceneManagement;
using Debug = UnityEngine.Debug;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Serializable data structures for raw Unity context data
    /// All intelligence and formatting is handled by the MCP server
    /// </summary>
    [Serializable]
    public class UnityProjectData
    {
        public ProjectInfoData projectInfo;
        public SceneSummaryData sceneSummary;
        public SceneHierarchyData sceneHierarchy;
        public ScriptData[] scripts;
        public SelectionData selection;
        public PackageData[] packages;
        public ErrorData[] errors;
    }

    [Serializable]
    public class SceneSummaryData
    {
        public string activeSceneName;
        public string activeScenePath;
        public int totalGameObjectCount;
        public int totalCameraCount;
        public string[] rootObjectNames;
    }

    [Serializable]
    public class ProjectManifestData
    {
        public string projectName;
        public string unityVersion;
        public string platform;
        public string activeSceneName;
        public string activeScenePath;
        public string activeSceneWriteUtc;
        public int sceneObjectCount;
        public int scriptCount;
        public string assetsWriteUtc;
    }

    [Serializable]
    public class ProjectInfoData
    {
        public string projectName;
        public string unityVersion;
        public string platform;
        public string inputSystem; // "NEW", "OLD", "BOTH", or null
        public string renderPipeline; // "URP", "HDRP", "Built-in", or null
        public string defaultShader; // Default shader name for the render pipeline
        public Vector3Data physicsGravity;
        public string[] layers; // Array of "index:name" strings
    }

    [Serializable]
    public class Vector3Data
    {
        public float x, y, z;
        public Vector3Data() { }
        public Vector3Data(Vector3 v) { x = v.x; y = v.y; z = v.z; }
    }

    [Serializable]
    public class SceneHierarchyData
    {
        public GameObjectData[] allGameObjects; // Flat list of objects (depth/count bounded)
        public string[] rootObjectNames; // Names of root objects for hierarchy reference
        public CameraData[] cameras;
        public bool truncated; // True if object count cap was reached
        public string note;   // Human-readable note when truncated
    }

    [Serializable]
    public class GameObjectData
    {
        public string name;
        public string path;
        public bool active;
        public Vector3Data position;
        public Vector3Data rotation; // Euler angles
        public Vector3Data scale;
        public Vector3Data localPosition;
        public Vector3Data localRotation; // Euler angles
        public string parentName;
        public string parentPath; // Full path to parent for easier lookup
        public string[] components;
        public int depth; // Depth in hierarchy (0 = root)
        // Removed children array - use flat list with parentPath instead
    }

    [Serializable]
    public class CameraData
    {
        public string name;
        public string path;
        public bool active;
        public bool enabled;
        public Vector3Data position;
        public Vector3Data rotation;
        public Vector3Data localPosition;
        public Vector3Data localRotation;
        public float fieldOfView;
        public float nearClipPlane;
        public float farClipPlane;
        public bool isMainCamera;
        public string parentName;
    }

    [Serializable]
    public class ScriptData
    {
        public string path;
        public string name;
        public int lineCount;
        public string content; // Full content if available (server decides what's relevant)
    }

    [Serializable]
    public class SelectionData
    {
        public string type; // "GameObject", "Asset", or "None"
        public string name;
        public string path;
        public string[] components; // For GameObjects
    }

    [Serializable]
    public class PackageData
    {
        public string name;
        public bool installed;
        public string version; // e.g. "3.1.2", null if unknown
    }

    [Serializable]
    public class ErrorData
    {
        public string scriptPath;
        public string errorMessage;
        public string errorType;
        public string timestamp;
        public string userQuery;
        public bool wasFixed;
        public string fixApplied;
    }

    /// <summary>
    /// Gathers raw Unity project data (no intelligence, no formatting)
    /// All intelligence and formatting is handled by the MCP server
    /// </summary>
    public static class UnityContextGatherer
    {
        public struct ContextOptions
        {
            public bool includeProjectInfo;
            public bool includeSelection;
            public bool includeSceneSummary;
            public bool includeSceneHierarchy;
            public bool includeScriptsList;
            public bool includeScriptsContent;
            public bool includePackages;
            public bool includeErrors;
            public bool includeCameras;
            public int sceneMaxDepth; // -1 = unlimited
            public int maxScriptBytes; // 0 = unlimited
        }

        // ── Phase 1.3: GatherRawData result cache ─────────────────────────────
        // Cache key = (sceneGuid, selectionPath, 2s TTL bucket, option bits).
        // Invalidated explicitly on scene save / asset import / project change.
        // The 2s bucket acts as a safety-net TTL so stale state never persists longer.
        private static UnityProjectData _cachedData;
        private static string _cachedKey;

        [InitializeOnLoadMethod]
        private static void RegisterCacheInvalidationHooks()
        {
            EditorSceneManager.sceneSaved -= OnSceneSaved;
            EditorSceneManager.sceneSaved += OnSceneSaved;
            AssetDatabase.importPackageCompleted -= OnImportPackageCompleted;
            AssetDatabase.importPackageCompleted += OnImportPackageCompleted;
            EditorApplication.projectChanged -= InvalidateGatherCache;
            EditorApplication.projectChanged += InvalidateGatherCache;
        }

        private static void OnSceneSaved(UnityEngine.SceneManagement.Scene _) => InvalidateGatherCache();
        private static void OnImportPackageCompleted(string _) => InvalidateGatherCache();

        public static void InvalidateGatherCache()
        {
            _cachedData = null;
            _cachedKey = null;
        }

        private static string ComputeGatherCacheKey(ContextOptions options)
        {
            var scene = SceneManager.GetActiveScene();
            string sceneGuid = AssetDatabase.AssetPathToGUID(scene.path ?? "") ?? scene.name;
            // 2-second bucket: same scene state within 2s returns cached data
            long bucket = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 2;
            // Include selection so a different selected object produces a different key
            string sel = "";
            if (Selection.activeGameObject != null)
                sel = Selection.activeGameObject.name;
            else if (Selection.activeObject != null)
                sel = AssetDatabase.GetAssetPath(Selection.activeObject) ?? Selection.activeObject.name;
            // Encode option flags that affect which data is gathered
            int optBits = (options.includeSceneHierarchy ? 1 : 0)
                        | (options.includeScriptsList    ? 2 : 0)
                        | (options.includeProjectInfo    ? 4 : 0)
                        | (options.includeScriptsContent ? 8 : 0)
                        | (options.includePackages       ? 16 : 0);
            return $"{sceneGuid}:{sel}:{bucket}:{optBits}";
        }
        // ─────────────────────────────────────────────────────────────────────

        /// <summary>
        /// Phase-0 instrumentation. Milliseconds spent in each GatherRawData sub-step.
        /// Updated by GatherRawData on every call; read by the HTTP bridge to surface
        /// sub-step timings in ContextGatherResponse.
        /// </summary>
        public struct GatherTimings
        {
            public double totalMs;
            public double projectInfoMs;
            public double sceneSummaryMs;
            public double hierarchyMs;
            public double scriptsMs;
            public double selectionMs;
            public double packagesMs;
            public double errorsMs;
        }

        public static GatherTimings LastGatherTimings;

        /// <summary>
        /// Lightweight manifest used for context caching handshake (fast to compute).
        /// </summary>
        public static string GetProjectManifestJson()
        {
            var manifest = BuildProjectManifest();
            return JsonUtility.ToJson(manifest);
        }

        /// <summary>
        /// Stable hash for the current project manifest (used for cache keys).
        /// </summary>
        public static string GetProjectHash()
        {
            string manifestJson = GetProjectManifestJson();
            return ComputeHash(manifestJson);
        }

        /// <summary>
        /// Gets raw Unity project data as JSON-serializable structure
        /// Server will apply all intelligence and formatting
        /// </summary>
        public static UnityProjectData GatherRawData(bool includeSceneHierarchy = true, bool includeScripts = true, bool includeProjectInfo = true)
        {
            var options = new ContextOptions
            {
                includeProjectInfo = includeProjectInfo,
                includeSelection = true,
                includeSceneSummary = false,
                includeSceneHierarchy = includeSceneHierarchy,
                includeScriptsList = includeScripts,
                includeScriptsContent = includeScripts,
                includePackages = true,
                includeErrors = true,
                includeCameras = true,
                sceneMaxDepth = -1,
                maxScriptBytes = 0,
            };

            return GatherRawData(options);
        }

        public static UnityProjectData GatherRawData(ContextOptions options)
        {
            // Phase 1.3: Return cached result if the project state hasn't changed
            string cacheKey = ComputeGatherCacheKey(options);
            if (_cachedData != null && _cachedKey == cacheKey)
            {
                LastGatherTimings = default; // timings not meaningful for a cache hit
                return _cachedData;
            }

            var data = new UnityProjectData();
            var timings = new GatherTimings();
            var swTotal = Stopwatch.StartNew();
            var sw = new Stopwatch();

            if (options.includeProjectInfo)
            {
                sw.Restart();
                data.projectInfo = GetProjectInfo();
                timings.projectInfoMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includeSceneSummary)
            {
                sw.Restart();
                data.sceneSummary = GetSceneSummary(options.includeCameras);
                timings.sceneSummaryMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includeSceneHierarchy)
            {
                sw.Restart();
                data.sceneHierarchy = GetSceneHierarchy(options.sceneMaxDepth, options.includeCameras);
                timings.hierarchyMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includeScriptsList || options.includeScriptsContent)
            {
                sw.Restart();
                data.scripts = GetScripts(options.includeScriptsContent, options.maxScriptBytes);
                timings.scriptsMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includeSelection)
            {
                sw.Restart();
                data.selection = GetSelection();
                timings.selectionMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includePackages)
            {
                sw.Restart();
                data.packages = GetPackages();
                timings.packagesMs = sw.Elapsed.TotalMilliseconds;
            }

            if (options.includeErrors)
            {
                sw.Restart();
                data.errors = GetErrors();
                timings.errorsMs = sw.Elapsed.TotalMilliseconds;
            }

            swTotal.Stop();
            timings.totalMs = swTotal.Elapsed.TotalMilliseconds;
            LastGatherTimings = timings;

            // Phase 1.3: Cache result for subsequent calls within the same 2s window
            _cachedData = data;
            _cachedKey = cacheKey;

            return data;
        }

        public static bool TryGetScriptContent(string scriptPath, out string content, out string error)
        {
            content = null;
            error = null;
            try
            {
                if (string.IsNullOrEmpty(scriptPath))
                {
                    error = "scriptPath is empty";
                    return false;
                }

                string normalizedPath = NormalizeTextAssetPath(scriptPath);
                if (string.IsNullOrEmpty(normalizedPath))
                {
                    error = $"Invalid scriptPath: {scriptPath}";
                    return false;
                }

                string fullPath = Path.Combine(Application.dataPath, normalizedPath.Replace("Assets/", ""));
                if (!File.Exists(fullPath))
                {
                    error = $"File not found: {normalizedPath}";
                    return false;
                }

                content = File.ReadAllText(fullPath);
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        /// <summary>
        /// Reads a 1-based inclusive line range from a text asset so the agent can pull one method
        /// out of a large file instead of the whole thing. startLine &lt;= 0 means "from the top";
        /// endLine &lt;= 0 means "to the end". Out-of-range bounds are clamped, and a start past the
        /// end returns empty content (not an error). totalLines always reports the file's real line
        /// count so the caller knows whether it saw a slice or the whole file.
        /// </summary>
        public static bool TryGetScriptContentSlice(
            string scriptPath, int startLine, int endLine,
            out string content, out int totalLines, out int returnedStart, out int returnedEnd, out string error)
        {
            content = null;
            totalLines = 0;
            returnedStart = 0;
            returnedEnd = 0;
            error = null;

            if (!TryGetScriptContent(scriptPath, out var full, out error))
                return false;

            // Split on '\n' and strip a trailing '\r' per line so line numbers match an editor's
            // regardless of CRLF vs LF. A trailing newline yields one empty final element, which we
            // drop so totalLines reflects the visible line count.
            string[] lines = full.Split('\n');
            int count = lines.Length;
            if (count > 0 && lines[count - 1].Length == 0)
                count--;
            totalLines = count;

            int start = startLine <= 0 ? 1 : startLine;
            int end = endLine <= 0 ? count : endLine;
            if (end > count) end = count;

            if (count == 0 || start > count)
            {
                content = "";
                returnedStart = start;
                returnedEnd = start - 1;
                return true;
            }
            if (start < 1) start = 1;

            var sb = new System.Text.StringBuilder();
            for (int i = start - 1; i <= end - 1; i++)
            {
                sb.Append(lines[i].TrimEnd('\r'));
                if (i < end - 1)
                    sb.Append('\n');
            }
            content = sb.ToString();
            returnedStart = start;
            returnedEnd = end;
            return true;
        }

        public static string[] FindScriptPaths(string nameContains, int maxResults = 20)
        {
            var results = new List<string>();
            try
            {
                var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
                foreach (var guid in scriptGuids)
                {
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(path) || !path.EndsWith(".cs"))
                        continue;
                    if (path.Contains("/Editor/") || path.StartsWith("Packages/"))
                        continue;

                    if (!string.IsNullOrEmpty(nameContains))
                    {
                        string fileName = Path.GetFileNameWithoutExtension(path);
                        if (fileName.IndexOf(nameContains, StringComparison.OrdinalIgnoreCase) < 0)
                            continue;
                    }

                    results.Add(path);
                    if (results.Count >= maxResults)
                        break;
                }
            }
            catch { }

            return results.ToArray();
        }

        public static string[] SearchScriptsContent(string query, int maxResults = 10)
        {
            var results = new List<string>();
            if (string.IsNullOrEmpty(query))
                return results.ToArray();

            try
            {
                var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
                foreach (var guid in scriptGuids)
                {
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(path) || !path.EndsWith(".cs"))
                        continue;
                    if (path.Contains("/Editor/") || path.StartsWith("Packages/"))
                        continue;

                    string fullPath = Path.Combine(Application.dataPath, path.Replace("Assets/", ""));
                    if (!File.Exists(fullPath))
                        continue;

                    string content = File.ReadAllText(fullPath);
                    if (content.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        results.Add(path);
                        if (results.Count >= maxResults)
                            break;
                    }
                }
            }
            catch { }

            return results.ToArray();
        }

        /// <summary>
        /// Finds every script that references an identifier (class, method, or field name),
        /// using whole-word matching on C# identifier boundaries so "Player" does not match
        /// "PlayerController" or a substring inside another word. This is the dependency-edge
        /// primitive: before refactoring a symbol, find the scripts that would break.
        ///
        /// Returns one entry per matching file: { path, count, matches:[{ line, text }] }, capped
        /// at maxFiles entries and ordered by match count (descending) so the heaviest dependents
        /// surface first. Unlike a naive early-out, the walk continues scanning past maxFiles to
        /// tally the TRUE blast radius — totalFileCount / totalMatchCount report how many files and
        /// references exist in total, even when only the top maxFiles carry line-level detail. This
        /// keeps a refactor from acting on a partial picture (the old code stopped counting at the
        /// cap, so a widely-used symbol looked far less used than it was). Editor and Packages
        /// scripts are excluded to match the other script-search tools.
        /// </summary>
        public static List<Dictionary<string, object>> FindReferences(
            string symbol, int maxFiles, int maxMatchesPerFile,
            out int totalFileCount, out int totalMatchCount)
        {
            var results = new List<Dictionary<string, object>>();
            totalFileCount = 0;
            totalMatchCount = 0;
            if (string.IsNullOrEmpty(symbol))
                return results;

            // Identifier-boundary match: C# identifiers are [A-Za-z0-9_]. Escape the symbol so
            // a caller passing a value with regex metacharacters can't break or widen the match.
            Regex pattern;
            try
            {
                pattern = new Regex(@"(?<![A-Za-z0-9_])" + Regex.Escape(symbol) + @"(?![A-Za-z0-9_])");
            }
            catch
            {
                return results;
            }

            try
            {
                var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
                foreach (var guid in scriptGuids)
                {
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(path) || !path.EndsWith(".cs"))
                        continue;
                    if (path.Contains("/Editor/") || path.StartsWith("Packages/"))
                        continue;

                    string fullPath = Path.Combine(Application.dataPath, path.Replace("Assets/", ""));
                    if (!File.Exists(fullPath))
                        continue;

                    string content;
                    try { content = File.ReadAllText(fullPath); }
                    catch { continue; }

                    int fileMatchCount = pattern.Matches(content).Count;
                    if (fileMatchCount == 0)
                        continue;

                    totalFileCount++;
                    totalMatchCount += fileMatchCount;

                    // Collect line-level detail only for the first maxFiles matching files; past
                    // the cap we keep scanning purely to tally the totals above.
                    if (results.Count >= maxFiles)
                        continue;

                    var matches = new List<Dictionary<string, object>>();
                    string[] lines = content.Split('\n');
                    for (int li = 0; li < lines.Length && matches.Count < maxMatchesPerFile; li++)
                    {
                        string line = lines[li].TrimEnd('\r');
                        if (!pattern.IsMatch(line))
                            continue;
                        string text = line.Trim();
                        if (text.Length > 200)
                            text = text.Substring(0, 200);
                        matches.Add(new Dictionary<string, object>
                        {
                            { "line", li + 1 },
                            { "text", text }
                        });
                    }

                    results.Add(new Dictionary<string, object>
                    {
                        { "path", path },
                        { "count", fileMatchCount },
                        { "matches", matches }
                    });
                }
            }
            catch { }

            results.Sort((a, b) => Convert.ToInt32(b["count"]).CompareTo(Convert.ToInt32(a["count"])));
            return results;
        }

        /// <summary>
        /// Finds every prefab asset and open-scene GameObject that has a component of
        /// the given type — the Inspector-wiring analog of FindReferences. Where
        /// FindReferences answers "what code references this symbol", this answers
        /// "what is this script/component actually attached to" — the blast radius of
        /// changing or removing a component, which is invisible in the source because
        /// the wiring lives in scene/prefab data, not code.
        ///
        /// Matches by simple type name (case-insensitive), so it accepts a MonoBehaviour
        /// script class ("PlayerController") or a built-in component ("Rigidbody",
        /// "BoxCollider"). Returns one entry per match: { location:"scene"|"prefab",
        /// container (scene name or prefab path), gameObject (hierarchy path), componentType }.
        /// Open scenes are scanned first, then prefab assets (Packages/ excluded). The
        /// prefab load is bounded by maxPrefabScan to stay responsive on large projects.
        /// </summary>
        public static Dictionary<string, object> FindComponentUsages(
            string componentType, int maxResults = 60, int maxPrefabScan = 2000)
        {
            var usages = new List<Dictionary<string, object>>();
            bool truncated = false;
            if (string.IsNullOrEmpty(componentType))
                return new Dictionary<string, object> { { "usages", usages }, { "truncated", false } };

            bool Matches(Component c) =>
                c != null && string.Equals(c.GetType().Name, componentType, StringComparison.OrdinalIgnoreCase);

            // 1. Open scene(s) — additively-loaded scenes included.
            try
            {
                for (int si = 0; si < SceneManager.sceneCount; si++)
                {
                    var scene = SceneManager.GetSceneAt(si);
                    if (!scene.isLoaded)
                        continue;
                    foreach (var root in scene.GetRootGameObjects())
                    {
                        foreach (var c in root.GetComponentsInChildren<Component>(true))
                        {
                            if (!Matches(c))
                                continue;
                            usages.Add(new Dictionary<string, object>
                            {
                                { "location", "scene" },
                                { "container", string.IsNullOrEmpty(scene.name) ? "(untitled scene)" : scene.name },
                                { "gameObject", GetGameObjectPath(c.gameObject) },
                                { "componentType", c.GetType().Name },
                            });
                            if (usages.Count >= maxResults)
                                return new Dictionary<string, object> { { "usages", usages }, { "truncated", true } };
                        }
                    }
                }
            }
            catch { }

            // 2. Prefab assets.
            try
            {
                var prefabGuids = AssetDatabase.FindAssets("t:Prefab");
                int scanned = 0;
                foreach (var guid in prefabGuids)
                {
                    if (scanned >= maxPrefabScan)
                    {
                        truncated = true;
                        break;
                    }
                    string path = AssetDatabase.GUIDToAssetPath(guid);
                    if (string.IsNullOrEmpty(path) || path.StartsWith("Packages/"))
                        continue;
                    // Skip GladeKit's own per-turn prefab backups — they're internal
                    // undo artifacts, not the user's project wiring, and would falsely
                    // inflate the blast radius (e.g. "used in 5 backup prefabs").
                    if (path.Contains("/GladeKitBackups/"))
                        continue;
                    var root = AssetDatabase.LoadAssetAtPath<GameObject>(path);
                    if (root == null)
                        continue;
                    scanned++;
                    foreach (var c in root.GetComponentsInChildren<Component>(true))
                    {
                        if (!Matches(c))
                            continue;
                        usages.Add(new Dictionary<string, object>
                        {
                            { "location", "prefab" },
                            { "container", path },
                            { "gameObject", GetGameObjectPath(c.gameObject) },
                            { "componentType", c.GetType().Name },
                        });
                        if (usages.Count >= maxResults)
                            return new Dictionary<string, object> { { "usages", usages }, { "truncated", true } };
                    }
                }
            }
            catch { }

            return new Dictionary<string, object> { { "usages", usages }, { "truncated", truncated } };
        }

        /// <summary>
        /// Gets raw Unity project data as JSON string
        /// Server will process this and apply formatting/intelligence
        /// </summary>
        public static string GatherRawDataJson(bool includeSceneHierarchy = true, bool includeScripts = true, bool includeProjectInfo = true)
        {
            var data = GatherRawData(includeSceneHierarchy, includeScripts, includeProjectInfo);
            return JsonUtility.ToJson(data);
        }

        public static string GatherRawDataJson(ContextOptions options)
        {
            var data = GatherRawData(options);
            return JsonUtility.ToJson(data);
        }

        /// <summary>
        /// Legacy method - kept for backward compatibility
        /// Now just returns raw JSON (server handles formatting)
        /// </summary>
        [Obsolete("Use GatherRawDataJson() instead. Server now handles all formatting.")]
        public static string GatherContext(bool includeSceneHierarchy = true, bool includeScripts = true, bool includeProjectInfo = true)
            {
            return GatherRawDataJson(includeSceneHierarchy, includeScripts, includeProjectInfo);
        }
        
        private static ProjectInfoData GetProjectInfo()
        {
            var info = new ProjectInfoData
            {
                projectName = Application.productName,
                unityVersion = Application.unityVersion,
                platform = Application.platform.ToString(),
                physicsGravity = new Vector3Data(Physics.gravity)
            };

            // Determine Input System
            #if ENABLE_INPUT_SYSTEM && !ENABLE_LEGACY_INPUT_MANAGER
            info.inputSystem = "NEW";
            #elif ENABLE_INPUT_SYSTEM && ENABLE_LEGACY_INPUT_MANAGER
            info.inputSystem = "BOTH";
            #else
            info.inputSystem = "OLD";
            #endif
            
            // Detect Render Pipeline
            var renderPipelineInfo = DetectRenderPipeline();
            info.renderPipeline = renderPipelineInfo.pipeline;
            info.defaultShader = renderPipelineInfo.shader;
            
            // Get layers
            var layers = new List<string>();
            for (int i = 0; i < 32; i++)
            {
                string layerName = LayerMask.LayerToName(i);
                if (!string.IsNullOrEmpty(layerName))
                    layers.Add($"{i}:{layerName}");
            }
            info.layers = layers.ToArray();
            
            return info;
        }

        private static ProjectManifestData BuildProjectManifest()
        {
            var activeScene = SceneManager.GetActiveScene();
            string activeScenePath = activeScene.path ?? "";
            string activeSceneWriteUtc = GetFileWriteUtc(activeScenePath);

            int scriptCount = 0;
            try
            {
                scriptCount = AssetDatabase.FindAssets("t:MonoScript").Length;
            }
            catch { }

            int sceneObjectCount = 0;
            try
            {
                sceneObjectCount = UnityEngine.Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None).Length;
            }
            catch { }

            string assetsWriteUtc = "";
            try
            {
                assetsWriteUtc = Directory.GetLastWriteTimeUtc(Application.dataPath).ToString("o");
            }
            catch { }

            return new ProjectManifestData
            {
                projectName = Application.productName,
                unityVersion = Application.unityVersion,
                platform = Application.platform.ToString(),
                activeSceneName = activeScene.name,
                activeScenePath = activeScenePath,
                activeSceneWriteUtc = activeSceneWriteUtc,
                sceneObjectCount = sceneObjectCount,
                scriptCount = scriptCount,
                assetsWriteUtc = assetsWriteUtc,
            };
        }

        private static string GetFileWriteUtc(string relativePath)
        {
            try
            {
                if (string.IsNullOrEmpty(relativePath))
                    return "";
                string fullPath = Path.GetFullPath(relativePath);
                if (!File.Exists(fullPath))
                    return "";
                return File.GetLastWriteTimeUtc(fullPath).ToString("o");
            }
            catch
            {
                return "";
            }
        }

        private static string ComputeHash(string input)
        {
            if (string.IsNullOrEmpty(input))
                return "";
            using (var sha = SHA256.Create())
            {
                byte[] bytes = Encoding.UTF8.GetBytes(input);
                byte[] hash = sha.ComputeHash(bytes);
                var sb = new StringBuilder(hash.Length * 2);
                foreach (byte b in hash)
                    sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private static (string pipeline, string shader) DetectRenderPipeline()
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
                        return ("URP", "Universal Render Pipeline/Lit");
                    if (Shader.Find("Universal Render Pipeline/Unlit") != null)
                        return ("URP", "Universal Render Pipeline/Unlit");
                    return ("URP", "Universal Render Pipeline/Lit");
                }
                
                // HDRP detection
                if (assetType.Contains("HDRenderPipelineAsset") || 
                    assetType.Contains("HD") ||
                    assetNamespace.Contains("HighDefinition"))
                {
                    if (Shader.Find("HDRP/Lit") != null)
                        return ("HDRP", "HDRP/Lit");
                    if (Shader.Find("HDRP/Unlit") != null)
                        return ("HDRP", "HDRP/Unlit");
                    return ("HDRP", "HDRP/Lit");
                }
            }
#endif

            // Check by shader availability (fallback)
            if (Shader.Find("Universal Render Pipeline/Lit") != null)
            {
                return ("URP", "Universal Render Pipeline/Lit");
            }
            
            if (Shader.Find("HDRP/Lit") != null)
            {
                return ("HDRP", "HDRP/Lit");
            }
            
            // Default to Built-in
            return ("Built-in", "Standard");
        }

        // Hard safety cap — keeps JSON under ~5 MB even for the most complex scenes.
        private const int MaxHierarchyObjects = 2000;

        private static SceneHierarchyData GetSceneHierarchy(int maxDepth, bool includeCameras)
        {
            var hierarchy = new SceneHierarchyData();
            var results = new List<GameObjectData>();
            var rootObjectNames = new List<string>();

            var activeScene = UnityEngine.SceneManagement.SceneManager.GetActiveScene();
            var rootObjects = activeScene.GetRootGameObjects();

            foreach (var root in rootObjects)
                rootObjectNames.Add(root.name);

            // BFS ensures balanced coverage across ALL root objects before descending.
            // (DFS would spend the entire budget on the first deep subtree — e.g. Microverse
            // terrain chunks would consume all 2000 slots, and the AI would never see the
            // Player, Cameras, or Lights.)
            var queue = new Queue<(GameObject go, int depth, string parentPath)>();
            foreach (var root in rootObjects)
                queue.Enqueue((root, 0, null));

            while (queue.Count > 0 && results.Count < MaxHierarchyObjects)
            {
                var (go, depth, parentPath) = queue.Dequeue();
                // Build path top-down from traversal context — O(1) string concat, no upward walk.
                string fullPath = parentPath != null ? parentPath + "/" + go.name : go.name;

                results.Add(CreateGameObjectData(go, depth, fullPath, parentPath));

                // Only enqueue children within the depth limit
                if (maxDepth < 0 || depth + 1 <= maxDepth)
                {
                    foreach (Transform child in go.transform)
                        queue.Enqueue((child.gameObject, depth + 1, fullPath));
                }
            }

            bool truncated = queue.Count > 0;

            hierarchy.allGameObjects = results.ToArray();
            hierarchy.rootObjectNames = rootObjectNames.ToArray();
            hierarchy.truncated = truncated;
            if (truncated)
            {
                hierarchy.note = $"Scene hierarchy capped at {MaxHierarchyObjects} objects. " +
                    "Use find_game_objects with hasComponent or nameContains to locate specific objects.";
            }

            if (includeCameras)
            {
                var cameras = UnityEngine.Object.FindObjectsByType<Camera>(FindObjectsSortMode.None);
                hierarchy.cameras = cameras
                    .Where(cam => cam.gameObject.scene == activeScene)
                    .Select(cam => ConvertCamera(cam))
                    .ToArray();
            }
            else
            {
                hierarchy.cameras = Array.Empty<CameraData>();
            }

            return hierarchy;
        }

        private static SceneSummaryData GetSceneSummary(bool includeCameras)
        {
            var activeScene = SceneManager.GetActiveScene();
            var rootObjects = activeScene.GetRootGameObjects();
            var rootNames = rootObjects.Select(go => go.name).ToArray();

            // Count objects by walking transforms (uses cached childCount — no GC alloc).
            // Avoids FindObjectsByType which allocates an array of every GameObject in the scene.
            int objectCount = 0;
            foreach (var root in rootObjects)
                objectCount += CountChildrenRecursive(root.transform);

            int cameraCount = 0;
            if (includeCameras)
            {
                try
                {
                    cameraCount = UnityEngine.Object.FindObjectsByType<Camera>(FindObjectsSortMode.None)
                        .Count(cam => cam.gameObject.scene == activeScene);
                }
                catch { }
            }

            return new SceneSummaryData
            {
                activeSceneName = activeScene.name,
                activeScenePath = activeScene.path ?? "",
                totalGameObjectCount = objectCount,
                totalCameraCount = cameraCount,
                rootObjectNames = rootNames
            };
        }

        private static int CountChildrenRecursive(Transform t)
        {
            int count = 1; // count self
            for (int i = 0; i < t.childCount; i++)
                count += CountChildrenRecursive(t.GetChild(i));
            return count;
        }

        /// <summary>
        /// Build GameObjectData using pre-computed traversal state.
        /// Path and parentPath are passed down from the BFS caller — no upward hierarchy walk needed.
        /// </summary>
        private static GameObjectData CreateGameObjectData(
            GameObject go, int depth, string fullPath, string parentPath)
        {
            var data = new GameObjectData
            {
                name = go.name,
                path = fullPath,
                active = go.activeSelf,
                position = new Vector3Data(go.transform.position),
                rotation = new Vector3Data(go.transform.eulerAngles),
                scale = new Vector3Data(go.transform.localScale),
                localPosition = new Vector3Data(go.transform.localPosition),
                localRotation = new Vector3Data(go.transform.localEulerAngles),
                parentName = go.transform.parent != null ? go.transform.parent.name : null,
                parentPath = parentPath,
                depth = depth
            };

            var components = go.GetComponents<Component>();
            data.components = components
                .Where(c => c != null && !(c is Transform))
                .Select(c => c.GetType().Name)
                .ToArray();

            return data;
        }

        private static CameraData ConvertCamera(Camera cam)
        {
            return new CameraData
            {
                name = cam.name,
                path = GetGameObjectPath(cam.gameObject),
                active = cam.gameObject.activeSelf,
                enabled = cam.enabled,
                position = new Vector3Data(cam.transform.position),
                rotation = new Vector3Data(cam.transform.eulerAngles),
                localPosition = new Vector3Data(cam.transform.localPosition),
                localRotation = new Vector3Data(cam.transform.localEulerAngles),
                fieldOfView = cam.fieldOfView,
                nearClipPlane = cam.nearClipPlane,
                farClipPlane = cam.farClipPlane,
                isMainCamera = cam.CompareTag("MainCamera") || Camera.main == cam,
                parentName = cam.transform.parent != null ? cam.transform.parent.name : null
            };
        }

        private static ScriptData[] GetScripts(bool includeContent, int maxBytes)
        {
            var scripts = new List<ScriptData>();
            var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
            int totalBytes = 0;

            foreach (var guid in scriptGuids)
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (string.IsNullOrEmpty(path) || !path.EndsWith(".cs"))
                    continue;
                
                // Skip Editor scripts and Unity internal scripts
                if (path.Contains("/Editor/") || path.StartsWith("Packages/"))
                    continue;

                string name = Path.GetFileNameWithoutExtension(path);
                
                try
                {
                    string fullPath = Path.Combine(Application.dataPath, path.Replace("Assets/", ""));
                    if (File.Exists(fullPath))
                    {
                        var lines = File.ReadAllLines(fullPath);
                        string content = null;
                        if (includeContent)
                        {
                            content = File.ReadAllText(fullPath);
                            if (maxBytes > 0)
                            {
                                int bytes = Encoding.UTF8.GetByteCount(content);
                                if (totalBytes + bytes > maxBytes)
                                {
                                    break;
                                }
                                totalBytes += bytes;
                            }
                        }

                        scripts.Add(new ScriptData
                        {
                            path = path,
                            name = name,
                            lineCount = lines.Length,
                            content = content // Server decides what's relevant
                        });
                    }
                }
                catch { }
            }

            return scripts.ToArray();
        }

        private static string NormalizeScriptPath(string scriptPath)
        {
            // Legacy method for backward compatibility - defaults to .cs
            string normalized = NormalizeTextAssetPath(scriptPath);
            if (string.IsNullOrEmpty(normalized))
                return "";
            // If no extension was provided, default to .cs
            if (!System.IO.Path.HasExtension(normalized))
                normalized += ".cs";
            return normalized;
        }

        private static string NormalizeTextAssetPath(string assetPath)
        {
            // Generic path normalizer that preserves file extension
            // Supports .cs, .shader, .compute, .hlsl, .cginc, and other text-based Unity assets
            string normalized = assetPath.Replace("\\", "/").Trim();
            if (string.IsNullOrEmpty(normalized))
                return "";
            if (!normalized.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                normalized = "Assets/" + normalized.TrimStart('/');
            // Preserve existing extension, don't force .cs
            return normalized;
        }

        private static SelectionData GetSelection()
            {
            var selection = new SelectionData();
            
            if (Selection.activeGameObject != null)
            {
                var go = Selection.activeGameObject;
                selection.type = "GameObject";
                selection.name = go.name;
                selection.path = GetGameObjectPath(go);
                
                var components = go.GetComponents<Component>();
                selection.components = components
                    .Where(c => c != null)
                    .Select(c => c.GetType().Name)
                    .ToArray();
            }
            else if (Selection.activeObject != null)
            {
                selection.type = "Asset";
                selection.name = Selection.activeObject.name;
                string path = AssetDatabase.GetAssetPath(Selection.activeObject);
                selection.path = path;
            }
            else
            {
                selection.type = "None";
            }

            return selection;
        }

        private static PackageData[] GetPackages()
        {
            var packages = new List<PackageData>();

            // Read package versions from packages-lock.json for accurate version reporting
            var packageVersions = GetPackageVersions();

            // Check for common packages
            #if GLADE_INPUT_SYSTEM
            packageVersions.TryGetValue("com.unity.inputsystem", out string inputVersion);
            packages.Add(new PackageData { name = "com.unity.inputsystem", installed = true, version = inputVersion });
            #endif

            // Cinemachine: check for both v2 (CinemachineVirtualCamera) and v3 (CinemachineCamera) types
            var cinemachineV2Type = System.Type.GetType("Cinemachine.CinemachineVirtualCamera, Cinemachine");
            var cinemachineV3Type = System.Type.GetType("Unity.Cinemachine.CinemachineCamera, Unity.Cinemachine");
            if (cinemachineV3Type != null || cinemachineV2Type != null)
            {
                packageVersions.TryGetValue("com.unity.cinemachine", out string cmVersion);
                packages.Add(new PackageData { name = "com.unity.cinemachine", installed = true, version = cmVersion });
            }

            // Check if TMP package is installed (types available)
            var tmpType = System.Type.GetType("TMPro.TextMeshProUGUI, Unity.TextMeshPro");
            if (tmpType != null)
            {
                // Also check if Essential Resources are actually imported
                string resourcesPath = System.IO.Path.Combine(Application.dataPath, "TextMesh Pro", "Resources");
                bool essentialResourcesImported = System.IO.Directory.Exists(resourcesPath);

                // Only report TMP as installed if BOTH package AND Essential Resources are present
                if (essentialResourcesImported)
                {
                    packageVersions.TryGetValue("com.unity.textmeshpro", out string tmpVersion);
                    packages.Add(new PackageData { name = "com.unity.textmeshpro", installed = true, version = tmpVersion });
                }
            }

            var navMeshType = System.Type.GetType("UnityEngine.AI.NavMeshAgent, UnityEngine.AIModule");
            if (navMeshType != null)
                packages.Add(new PackageData { name = "Navigation/AI", installed = true });

            return packages.ToArray();
        }

        /// <summary>
        /// Read package versions from Packages/packages-lock.json (reliable, no async API needed).
        /// Falls back to manifest.json if lock file unavailable.
        /// </summary>
        private static Dictionary<string, string> GetPackageVersions()
        {
            var versions = new Dictionary<string, string>();
            try
            {
                // packages-lock.json is in the project root alongside Assets/
                string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
                string lockPath = Path.Combine(projectRoot, "Packages", "packages-lock.json");

                if (File.Exists(lockPath))
                {
                    string json = File.ReadAllText(lockPath);
                    // Simple JSON parsing — look for "com.unity.xxx": { "version": "X.Y.Z" }
                    // Unity's JsonUtility can't parse arbitrary JSON, so we use string matching
                    ParsePackageVersionsFromLockFile(json, versions);
                }
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[GladeAI] Could not read package versions: {e.Message}");
            }
            return versions;
        }

        private static void ParsePackageVersionsFromLockFile(string json, Dictionary<string, string> versions)
        {
            // packages-lock.json format: { "dependencies": { "com.unity.cinemachine": { "version": "3.1.2", ... }, ... } }
            // We parse this with simple string operations since JsonUtility doesn't handle arbitrary JSON
            int depIndex = json.IndexOf("\"dependencies\"");
            if (depIndex < 0) return;

            int pos = depIndex;
            while (pos < json.Length)
            {
                // Find next package name starting with "com.unity."
                int pkgStart = json.IndexOf("\"com.unity.", pos);
                if (pkgStart < 0) break;

                int pkgEnd = json.IndexOf("\"", pkgStart + 1);
                if (pkgEnd < 0) break;

                string pkgName = json.Substring(pkgStart + 1, pkgEnd - pkgStart - 1);

                // Find "version" key after this package name
                int versionKeyPos = json.IndexOf("\"version\"", pkgEnd);
                if (versionKeyPos < 0) break;

                // Make sure we're still within this package's block (next package shouldn't appear before version)
                int nextPkg = json.IndexOf("\"com.unity.", pkgEnd + 1);
                if (nextPkg >= 0 && nextPkg < versionKeyPos)
                {
                    pos = pkgEnd + 1;
                    continue;
                }

                // Extract version value
                int colonPos = json.IndexOf(":", versionKeyPos);
                if (colonPos < 0) break;
                int valStart = json.IndexOf("\"", colonPos);
                if (valStart < 0) break;
                int valEnd = json.IndexOf("\"", valStart + 1);
                if (valEnd < 0) break;

                string version = json.Substring(valStart + 1, valEnd - valStart - 1);
                if (!versions.ContainsKey(pkgName))
                    versions[pkgName] = version;

                pos = valEnd + 1;
            }
        }

        private static ErrorData[] GetErrors()
        {
            // ErrorTracker returns formatted strings, we need raw data
            // For now, return empty - server can handle error context separately
            // Or ErrorTracker could be refactored to return raw data too
            return new ErrorData[0];
        }

        private static string GetGameObjectPath(GameObject go)
        {
            var path = new List<string>();
            Transform current = go.transform;
            
            while (current != null)
            {
                path.Insert(0, current.name);
                current = current.parent;
            }
            
            return string.Join("/", path);
        }
    }
}
