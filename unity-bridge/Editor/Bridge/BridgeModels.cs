using System;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Bridge
{
    /// <summary>
    /// Request/Response models for Unity Bridge HTTP API
    /// </summary>
    
    [Serializable]
    public class ToolExecuteRequest
    {
        public string toolName;
        public string arguments; // JSON string
    }
    
    [Serializable]
    public class ToolExecuteResponse
    {
        public bool success;
        public string result; // JSON string from ToolExecutor
        public bool requiresCompilation;
        public int compilationCount = -1; // Current compilation count when requiresCompilation is true
        public string error;
    }
    
    [Serializable]
    public class ContextGatherRequest
    {
        public bool includeProjectInfo = true;
        public bool includeSelection = true;
        public bool includeSceneSummary = false;
        public bool includeSceneHierarchy = true;
        public bool includeScriptsList = true;
        public bool includeScriptsContent = true;
        public bool includePackages = true;
        public bool includeErrors = true;
        public bool includeCameras = true;
        public int sceneMaxDepth = -1; // -1 = unlimited
        public int maxScriptBytes = 0; // 0 = unlimited
    }
    
    [Serializable]
    public class ContextGatherResponse
    {
        public bool success;
        public string projectHash;
        public string context; // JSON string
        public string error;
        // Phase-0 instrumentation — milliseconds spent gathering each sub-step.
        // 0 means the sub-step was skipped by options.
        public double total_ms;
        public double project_info_ms;
        public double scene_summary_ms;
        public double hierarchy_ms;
        public double scripts_ms;
        public double selection_ms;
        public double packages_ms;
        public double errors_ms;
    }
    
    [Serializable]
    public class HealthResponse
    {
        public string status; // "ok" or "error"
        public string unityVersion;
        public string projectName;
        public string projectPath; // Absolute path to the Unity project root (parent of Assets/)
        public bool isCompiling;
        public string error;
        // Bridge self-identification (added v0.4.0). Lets clients detect which
        // bridge variant is installed and warn on stale versions without
        // scraping package.json from disk.
        public string bridgeVersion; // e.g. "0.4.0" — null if package.json unreadable
        public string bridgeKind;    // "mcp" | "agenticai" | null
        // User-toggled feature flags surfaced to clients so the tool registry
        // can be filtered before the LLM ever sees it. Default true.
        public bool assetPipelineEnabled = true;
    }
    
    [Serializable]
    public class CompilationStatusResponse
    {
        public bool isCompiling;
        public string status; // "idle", "compiling", "error"
        public int compilationCount;
    }
    
    [Serializable]
    public class ScriptListResponse
    {
        public bool success;
        public ScriptInfo[] scripts;
        public string error;
    }
    
    [Serializable]
    public class ScriptInfo
    {
        public string path; // Relative to Assets folder
        public string name; // Script name without extension
        public string fullPath; // Full path including Assets/
    }
    
    [Serializable]
    public class AssetListResponse
    {
        public bool success;
        public AssetInfo[] assets;
        public string error;
    }
    
    [Serializable]
    public class AssetInfo
    {
        public string path; // Relative to Assets folder
        public string name; // Asset name
        public string type; // e.g., "Prefab", "Material", "Texture2D"
        public string fullPath; // Full path including Assets/
    }
    
    [Serializable]
    public class ErrorContextResponse
    {
        public bool success;
        public string errorContext;
        public string error;
    }
    
    [Serializable]
    public class ScriptContentRequest
    {
        public string[] paths; // Array of script paths to fetch content for
    }
    
    [Serializable]
    public class ScriptContentItem
    {
        public string path;
        public string name;
        public string content;
        public bool success;
        public string error;
    }
    
    [Serializable]
    public class ScriptContentResponse
    {
        public bool success;
        public ScriptContentItem[] scripts;
        public string error;
    }
    
    // ===== REVERT SYSTEM MODELS =====
    
    [Serializable]
    public class TurnRevertRequest
    {
        public string turnId;
        public FileChangeInfo[] fileChanges;
        public GameObjectChangeInfo[] gameObjectChanges;
    }

    [Serializable]
    public class FileChangeInfo
    {
        public string changeType;  // "created", "modified", "deleted"
        public string filePath;
        public string backupPath;  // Path to backup file (if exists)
    }

    [Serializable]
    public class GameObjectChangeInfo
    {
        public string changeType;  // "created", "modified", "deleted"
        public string gameObjectPath;
        public string stateBackupPath;  // Path to JSON state backup
        public GameObjectStateData previousState;  // Inline state (optional)
    }

    [Serializable]
    public class GameObjectStateData
    {
        public string name;
        public string path;
        public bool active;
        public Vector3Data position;
        public Vector3Data rotation;  // Euler angles
        public Vector3Data scale;
        public Vector3Data localPosition;
        public Vector3Data localRotation;
        public Vector3Data localScale;
        public string parentPath;
        public int layer;
        public string tag;
        public ComponentStateData[] components;
        public string prefabPath;  // Path to prefab backup for complete state restoration
    }

    [Serializable]
    public class ComponentStateData
    {
        public string type;
        public string propertiesJson;  // JSON string of properties
    }

    [Serializable]
    public class TurnRevertResponse
    {
        public bool success;
        public string message;
        public string error;
        public int filesRestored;
        public int filesDeleted;
        public int gameObjectsRestored;
        public int gameObjectsDeleted;
    }

    [Serializable]
    public class TurnAcceptRequest
    {
        public string turnId;
    }

    [Serializable]
    public class TurnAcceptResponse
    {
        public bool success;
        public string message;
        public string error;
    }
    
    [Serializable]
    public class FileBackupRequest
    {
        public string filePath;
        public string turnId;
    }

    [Serializable]
    public class FileBackupResponse
    {
        public bool success;
        public string backupPath;
        public string error;
    }

    [Serializable]
    public class GameObjectBackupRequest
    {
        public string gameObjectPath;
        public string turnId;
    }

    [Serializable]
    public class GameObjectBackupResponse
    {
        public bool success;
        public string backupPath;
        public string error;
    }

    [Serializable]
    public class BackupExistsRequest
    {
        public string[] paths;
    }

    [Serializable]
    public class BackupExistsResponse
    {
        public bool success;
        public string[] existingPaths;
        public string error;
    }
    
    [Serializable]
    public class ToolsListResponse
    {
        public bool success;
        public string[] toolNames;
        public string error;
    }

    /// <summary>
    /// One in-flight IAsyncTool call's live state. `progress` is in [0,1]
    /// only when `hasProgress` is true; consumers MUST treat any other value
    /// as "indeterminate" (e.g. show a marquee, not a bar). `phase` is a
    /// free-form short label like "downloading" or "extracting" and may be
    /// empty between phases — never compare to a fixed enum.
    /// </summary>
    [Serializable]
    public class AsyncProgressEntry
    {
        public string toolName;
        public string phase;
        public float progress;     // [0,1] iff hasProgress, otherwise -1f sentinel
        public bool hasProgress;
        public float elapsedSeconds;
    }

    [Serializable]
    public class AsyncProgressResponse
    {
        public AsyncProgressEntry[] inFlight;
    }

    // ===== BATCH EXECUTION MODELS =====

    [Serializable]
    public class BatchExecuteRequest
    {
        public BatchToolCall[] calls;
    }

    [Serializable]
    public class BatchToolCall
    {
        public string toolName;
        public string arguments; // JSON string
    }

    [Serializable]
    public class BatchExecuteResponse
    {
        public bool success;
        public BatchToolResult[] results;
        public string error;
    }

    [Serializable]
    public class BatchToolResult
    {
        public string toolName;
        public bool success;
        public string result; // JSON string from ToolExecutor
        public string error;
        public bool requiresCompilation;
    }
}
