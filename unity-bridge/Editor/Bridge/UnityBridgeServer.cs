using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEditor;
using UnityEditor.Compilation;
using UnityEngine;
using GladeAgenticAI.Services;
using GladeAgenticAI.Bridge;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Bridge
{
    /// <summary>
    /// HTTP server that exposes Unity tool execution and context gathering via REST API.
    /// Runs on localhost:8765 and processes requests on Unity main thread.
    /// </summary>
    [InitializeOnLoad]
    public static class UnityBridgeServer
    {
        private static HttpListener _listener;
        private static Thread _listenerThread;
        private static bool _isRunning = false;
        private static readonly Queue<HttpListenerContext> _requestQueue = new Queue<HttpListenerContext>();
        private static DateTime _lastRequestTime = DateTime.MinValue;
        private const int Port = 8765;
        private static readonly string BaseUrl = $"http://localhost:{Port}/";

        // Console / runtime-error capture lives in RuntimeLogStream.cs (a
        // proper [InitializeOnLoad] service with a 500-entry ring buffer +
        // monotonic cursors + per-event fingerprints). This handler is now
        // a thin delegate over that service. The service subscribes to
        // logMessageReceivedThreaded itself, so we no longer hook it here.
        private const double ConnectionTimeoutSeconds = 10.0; // Consider disconnected if no request in 10 seconds
        private static int _compilationCount = 0;

        // Tool call tracking (exposed to GladeKitMCPWindow)
        private static int _toolCallCount = 0;
        private static string _lastToolCalled = null;

        // ── Async tool dispatch ──────────────────────────────────────────────
        //
        // Tools that implement IAsyncTool yield back to the Editor between
        // phases (typically across network waits). For those, HandleToolExecute
        // calls BeginExecute, parks the HttpListenerContext + handle in
        // _pendingAsync, and returns from ProcessRequests so the Editor can
        // paint. Each subsequent EditorApplication.update tick re-enters
        // PollPendingAsync, which calls Handle.PollResult() on every pending
        // call — when one returns non-null, the response is sent and the
        // pending entry is removed.
        //
        // 300s deadline parallels the MCP-side per-tool HTTP timeout for
        // import_asset (mcp-server/src/gladekit_mcp/registry.py). Anything
        // longer is dead inventory — the upstream caller has already given up.
        private const double AsyncToolDeadlineSeconds = 300.0;

        private sealed class PendingAsyncCall
        {
            public HttpListenerContext Context;
            public IAsyncToolHandle Handle;
            public string ToolName;
            public DateTime Deadline;
            public DateTime StartedAt;
        }

        private static readonly List<PendingAsyncCall> _pendingAsync = new List<PendingAsyncCall>();

        /// <summary>Whether the bridge HTTP server is currently running.</summary>
        public static bool IsRunning => _isRunning;

        /// <summary>Number of tool calls executed this session.</summary>
        public static int ToolCallCount => _toolCallCount;

        /// <summary>Name of the last tool that was called, or null if none.</summary>
        public static string LastToolCalled => _lastToolCalled;

        static UnityBridgeServer()
        {
            EditorApplication.update += ProcessRequests;
            CompilationPipeline.compilationFinished -= OnCompilationFinished;
            CompilationPipeline.compilationFinished += OnCompilationFinished;
            // Runtime log capture is owned by RuntimeLogStream ([InitializeOnLoad]
            // in unity-bridge/Editor/Services/RuntimeLogStream.cs). It subscribes
            // on its own static ctor; no hookup needed here.
            StartServer();
        }

        private static void OnCompilationFinished(object obj)
        {
            _compilationCount++;
        }

        /// <summary>
        /// Start the HTTP server on a background thread
        /// </summary>
        public static void StartServer()
        {
            if (_isRunning)
            {
                Debug.Log("[UnityBridge] Server already running");
                return;
            }

            try
            {
                _listener = new HttpListener();
                _listener.Prefixes.Add(BaseUrl);
                _listener.Start();
                _isRunning = true;

                _listenerThread = new Thread(ListenForRequests)
                {
                    IsBackground = true,
                    Name = "UnityBridgeServer"
                };
                _listenerThread.Start();
                
                Debug.Log($"[UnityBridge] ✅ Server started successfully on {BaseUrl}");
                Debug.Log($"[UnityBridge] 📋 Ready to accept requests. Tools list endpoint: {BaseUrl}api/tools/list");
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Failed to start server: {e.Message}");
                _isRunning = false;
            }
        }

        /// <summary>
        /// Stop the HTTP server
        /// </summary>
        public static void StopServer()
        {
            if (!_isRunning)
                return;

            _isRunning = false;
            _listener?.Stop();
            _listener?.Close();
            _listener = null;

            // Drop any in-flight async tool handles. Don't try to send a
            // graceful error to the client — at this point we may be in
            // shutdown / domain-reload territory and the listener is gone.
            foreach (var pending in _pendingAsync)
            {
                try { pending.Handle.Dispose(); } catch { /* ignore */ }
            }
            _pendingAsync.Clear();

            Debug.Log("[UnityBridge] Server stopped");
        }

        /// <summary>
        /// Background thread that accepts HTTP connections
        /// </summary>
        private static void ListenForRequests()
        {
            while (_isRunning && _listener != null && _listener.IsListening)
            {
                try
                {
                    var context = _listener.GetContext();
                    lock (_requestQueue)
                    {
                        _requestQueue.Enqueue(context);
                    }
                }
                catch (HttpListenerException)
                {
                    // Server stopped
                    break;
                }
                catch (System.Threading.ThreadAbortException)
                {
                    // Unity domain reload - expected, exit quietly
                    // ThreadAbortException automatically re-throws, but we're breaking anyway
                    break;
                }
                catch (Exception e)
                {
                    // Check if this is a thread abort (Unity domain reload)
                    // ThreadAbortException message often contains "Thread was being aborted"
                    if (e is System.Threading.ThreadAbortException || 
                        e.Message.Contains("Thread was being aborted", System.StringComparison.OrdinalIgnoreCase))
                    {
                        // Unity domain reload - expected, exit quietly
                        break;
                    }
                    
                    // Only log other errors if not shutting down
                    if (_isRunning)
                    {
                        Debug.LogError($"[UnityBridge] Error accepting request: {e.Message}");
                    }
                }
            }
        }

        /// <summary>
        /// Process queued requests on Unity main thread (called via EditorApplication.update).
        ///
        /// Phase 2.2: Drain the queue into a local snapshot under the lock, then release
        /// the lock before invoking HandleRequest. This lets the listener thread enqueue
        /// new requests while we're processing earlier ones — without it, a slow tool
        /// (e.g. AssetDatabase.Refresh) would block the listener for the whole tick.
        /// Combined with the background response-write offload, the main thread yields
        /// to Unity between tools.
        /// </summary>
        private static void ProcessRequests()
        {
            if (!_isRunning)
                return;

            List<HttpListenerContext> toProcess = null;
            lock (_requestQueue)
            {
                if (_requestQueue.Count > 0)
                {
                    toProcess = new List<HttpListenerContext>(_requestQueue.Count);
                    while (_requestQueue.Count > 0)
                    {
                        toProcess.Add(_requestQueue.Dequeue());
                    }
                }
            }

            if (toProcess != null)
            {
                foreach (var context in toProcess)
                {
                    HandleRequest(context);
                }
            }

            // Drain completed async tool calls. Runs every tick — cheap when
            // _pendingAsync is empty (the common case).
            PollPendingAsync();
        }

        /// <summary>
        /// One pass over pending IAsyncTool handles. Sends the response for
        /// any that completed (or timed out) and removes them from the list.
        /// Called from <see cref="ProcessRequests"/> on the Unity main thread.
        /// </summary>
        private static void PollPendingAsync()
        {
            if (_pendingAsync.Count == 0) return;

            // Iterate backwards so in-place removal is safe.
            for (int i = _pendingAsync.Count - 1; i >= 0; i--)
            {
                var pending = _pendingAsync[i];
                string result = null;
                bool deadlineHit = DateTime.UtcNow > pending.Deadline;

                try
                {
                    result = deadlineHit
                        ? ToolUtils.CreateErrorResponse(
                            $"Tool {pending.ToolName} exceeded async deadline of {AsyncToolDeadlineSeconds:F0}s")
                        : pending.Handle.PollResult();
                }
                catch (Exception e)
                {
                    Debug.LogError($"[UnityBridge] Async tool '{pending.ToolName}' threw during poll: {e}");
                    result = ToolUtils.CreateErrorResponse($"Async tool '{pending.ToolName}' faulted: {e.Message}");
                }

                if (result == null) continue; // still working

                try { pending.Handle.Dispose(); } catch { /* best-effort cleanup */ }

                _toolCallCount++;
                _lastToolCalled = pending.ToolName;
                // SessionTracker uses the original args; we don't have them here
                // (parsed inside ToolExecutor.TryBeginAsync). Recording the result
                // without args is still useful for the activity feed.
                SessionTracker.Record(pending.ToolName, "{}", result);

                var toolResponse = new ToolExecuteResponse
                {
                    success = true,
                    result = result,
                    requiresCompilation = ToolRequiresCompilation(pending.ToolName),
                    compilationCount = ToolRequiresCompilation(pending.ToolName) ? _compilationCount : -1,
                    error = null,
                };

                try
                {
                    SendJson(pending.Context.Response, toolResponse);
                }
                catch (Exception e)
                {
                    Debug.LogWarning($"[UnityBridge] Failed to send async tool response for '{pending.ToolName}': {e.Message}");
                }

                _pendingAsync.RemoveAt(i);
            }
        }

        /// <summary>
        /// Handle an HTTP request
        /// </summary>
        private static void HandleRequest(HttpListenerContext context)
        {
            var request = context.Request;
            var response = context.Response;

            // Add CORS headers so browser-based and desktop clients can connect
            response.AddHeader("Access-Control-Allow-Origin", "*");
            response.AddHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            response.AddHeader("Access-Control-Allow-Headers", "Content-Type");

            // Handle preflight OPTIONS request
            if (request.HttpMethod == "OPTIONS")
            {
                response.StatusCode = 200;
                response.Close();
                return;
            }

            // Update last request time so the status window can show when a
            // client last communicated with Unity.
            _lastRequestTime = DateTime.Now;
            
            string path = request.Url.AbsolutePath;

            try
            {
                string method = request.HttpMethod;

                if (path == "/api/health" && method == "GET")
                {
                    HandleHealth(context);
                }
                else if (path == "/api/compilation/status" && method == "GET")
                {
                    HandleCompilationStatus(context);
                }
                else if (path == "/api/tools/execute" && method == "POST")
                {
                    HandleToolExecute(context);
                }
                else if (path == "/api/batch" && method == "POST")
                {
                    HandleBatchExecute(context);
                }
                else if (path == "/api/context/gather" && method == "POST")
                {
                    HandleContextGather(context);
                }
                else if (path == "/api/scripts/list" && method == "GET")
                {
                    HandleScriptList(context);
                }
                else if (path == "/api/scripts/content" && method == "POST")
                {
                    HandleScriptContent(context);
                }
                else if (path == "/api/settings" && method == "POST")
                {
                    HandleSettings(context);
                }
                else if (path == "/api/assets/list" && method == "GET")
                {
                    HandleAssetList(context);
                }
                else if (path == "/api/file/backup" && method == "POST")
                {
                    HandleFileBackup(context);
                }
                else if (path == "/api/gameobject/backup" && method == "POST")
                {
                    HandleGameObjectBackup(context);
                }
                else if (path == "/api/backup/exists" && method == "POST")
                {
                    HandleBackupExists(context);
                }
                else if (path == "/api/turn/revert" && method == "POST")
                {
                    HandleTurnRevert(context);
                }
                else if (path == "/api/turn/accept" && method == "POST")
                {
                    HandleTurnAccept(context);
                }
                else if (path == "/api/errors/context" && method == "GET")
                {
                    HandleGetErrorContext(context);
                }
                else if (path == "/api/console/events" && method == "GET")
                {
                    HandleConsoleEvents(context);
                }
                else if (path == "/api/tools/list" && method == "GET")
                {
                    HandleToolsList(context);
                }
                else if (path == "/api/async/progress" && method == "GET")
                {
                    HandleAsyncProgress(context);
                }
                else
                {
                    SendError(response, 404, "Not Found");
                }
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Error handling request: {e}");
                SendError(response, 500, $"Internal Server Error: {e.Message}");
            }
        }

        /// <summary>
        /// Handle GET /api/health
        /// </summary>
        private static void HandleHealth(HttpListenerContext context)
        {
            var (bridgeVersion, bridgeKind) = ReadBridgePackageInfo();
            var response = new HealthResponse
            {
                status = "ok",
                unityVersion = Application.unityVersion,
                projectName = Application.productName,
                projectPath = Path.GetFullPath(Path.Combine(Application.dataPath, "..")),
                isCompiling = EditorApplication.isCompiling,
                bridgeVersion = bridgeVersion,
                bridgeKind = bridgeKind,
                assetPipelineEnabled = AssetPipelineGuard.IsEnabled
            };

            SendJson(context.Response, response);
        }

        // Cached so /api/health doesn't hit disk on every poll.
        private static string _cachedBridgeVersion;
        private static string _cachedBridgeKind;
        private static bool _bridgeInfoLoaded;

        /// <summary>
        /// Read bridgeVersion and bridgeKind from the installed package's package.json.
        /// Searches both Packages/com.gladekit.{mcp-bridge|agenticai}/package.json
        /// (embedded) and Library/PackageCache/com.gladekit.{...}@*/package.json (UPM
        /// git cache). Returns (null, null) if neither package can be located —
        /// typically only happens in dev when the bridge is loose under Assets/.
        /// </summary>
        private static (string version, string kind) ReadBridgePackageInfo()
        {
            if (_bridgeInfoLoaded) return (_cachedBridgeVersion, _cachedBridgeKind);

            try
            {
                string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
                string[] candidatePackages = { "com.gladekit.mcp-bridge", "com.gladekit.agenticai" };

                foreach (var pkgName in candidatePackages)
                {
                    string embedded = Path.Combine(projectRoot, "Packages", pkgName, "package.json");
                    if (File.Exists(embedded))
                    {
                        string version = ExtractVersionField(File.ReadAllText(embedded));
                        if (!string.IsNullOrEmpty(version))
                        {
                            _cachedBridgeVersion = version;
                            _cachedBridgeKind = pkgName == "com.gladekit.mcp-bridge" ? "mcp" : "agenticai";
                            _bridgeInfoLoaded = true;
                            return (_cachedBridgeVersion, _cachedBridgeKind);
                        }
                    }

                    string cacheDir = Path.Combine(projectRoot, "Library", "PackageCache");
                    if (Directory.Exists(cacheDir))
                    {
                        // UPM git packages live at Library/PackageCache/<name>@<hash>/
                        var matches = Directory.GetDirectories(cacheDir, pkgName + "@*");
                        foreach (var dir in matches)
                        {
                            string pj = Path.Combine(dir, "package.json");
                            if (!File.Exists(pj)) continue;
                            string version = ExtractVersionField(File.ReadAllText(pj));
                            if (!string.IsNullOrEmpty(version))
                            {
                                _cachedBridgeVersion = version;
                                _cachedBridgeKind = pkgName == "com.gladekit.mcp-bridge" ? "mcp" : "agenticai";
                                _bridgeInfoLoaded = true;
                                return (_cachedBridgeVersion, _cachedBridgeKind);
                            }
                        }
                    }
                }
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[UnityBridge] Failed to read bridge package info: {e.Message}");
            }

            _bridgeInfoLoaded = true;
            return (null, null);
        }

        // Tiny single-field probe — avoids pulling in a JSON parser just for one
        // field. package.json always has "version" near the top.
        private static string ExtractVersionField(string json)
        {
            if (string.IsNullOrEmpty(json)) return null;
            const string needle = "\"version\"";
            int i = json.IndexOf(needle, StringComparison.Ordinal);
            if (i < 0) return null;
            int colon = json.IndexOf(':', i + needle.Length);
            if (colon < 0) return null;
            int q1 = json.IndexOf('"', colon + 1);
            if (q1 < 0) return null;
            int q2 = json.IndexOf('"', q1 + 1);
            if (q2 < 0) return null;
            return json.Substring(q1 + 1, q2 - q1 - 1);
        }

        /// <summary>
        /// Handle GET /api/compilation/status
        /// </summary>
        private static void HandleCompilationStatus(HttpListenerContext context)
        {
            bool isCompiling = EditorApplication.isCompiling;
            var response = new CompilationStatusResponse
            {
                isCompiling = isCompiling,
                status = isCompiling ? "compiling" : "idle",
                compilationCount = _compilationCount
            };

            SendJson(context.Response, response);
        }

        /// <summary>
        /// Handle GET /api/async/progress — read-only snapshot of every
        /// in-flight IAsyncTool call. Intended to be polled at ~1Hz by a
        /// client while dispatching a long-running tool (e.g. import_asset)
        /// so the user sees a live phase + percent indicator rather than a
        /// silent connection during a large download. The response is
        /// independent of any per-call id: clients match entries by
        /// toolName + position, which is sufficient given the typical case
        /// is one async tool in flight at a time.
        /// </summary>
        private static void HandleAsyncProgress(HttpListenerContext context)
        {
            var now = DateTime.UtcNow;
            var snapshots = new List<(string toolName, IAsyncToolHandle handle, DateTime startedAt)>(_pendingAsync.Count);
            foreach (var pending in _pendingAsync)
            {
                snapshots.Add((pending.ToolName, pending.Handle, pending.StartedAt));
            }
            var entries = BuildAsyncProgressSnapshot(snapshots, now);
            SendJson(context.Response, new AsyncProgressResponse { inFlight = entries });
        }

        /// <summary>
        /// Pure-data shaper for the /api/async/progress response. Extracted
        /// from the route handler so it can be unit-tested without spinning
        /// up an HttpListener. Tolerant of misbehaving handles — any tool
        /// whose Phase/Progress getter throws is reported with a sentinel
        /// indeterminate entry rather than aborting the whole snapshot.
        /// </summary>
        internal static AsyncProgressEntry[] BuildAsyncProgressSnapshot(
            IReadOnlyList<(string toolName, IAsyncToolHandle handle, DateTime startedAt)> snapshots,
            DateTime now)
        {
            var entries = new AsyncProgressEntry[snapshots.Count];
            for (int i = 0; i < snapshots.Count; i++)
            {
                var (toolName, handle, startedAt) = snapshots[i];
                string phase = "";
                float progress = -1f;
                bool hasProgress = false;
                try
                {
                    phase = handle?.Phase ?? "";
                    var p = handle?.Progress;
                    if (p.HasValue)
                    {
                        hasProgress = true;
                        progress = p.Value;
                    }
                }
                catch (Exception e)
                {
                    // Never let a misbehaving tool getter break the endpoint —
                    // the whole point is to be a heartbeat while work is alive.
                    Debug.LogWarning($"[UnityBridge] Async tool '{toolName}' threw during progress read: {e.Message}");
                }

                entries[i] = new AsyncProgressEntry
                {
                    toolName = toolName ?? "",
                    phase = phase,
                    progress = progress,
                    hasProgress = hasProgress,
                    elapsedSeconds = (float)(now - startedAt).TotalSeconds,
                };
            }
            return entries;
        }

        /// <summary>
        /// Handle GET /api/tools/list
        /// </summary>
        private static void HandleToolsList(HttpListenerContext context)
        {
            try
            {
                var registry = new ToolRegistry();
                var toolNames = registry.GetAllToolNames();
                
                Debug.Log($"[UnityBridge] 📋 GET /api/tools/list - Request received");
                Debug.Log($"[UnityBridge] 📋 Returning {toolNames.Count} registered tools");
                
                var response = new ToolsListResponse
                {
                    success = true,
                    toolNames = toolNames.ToArray(),
                    error = null
                };

                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Error in /api/tools/list: {e.Message}");
                var response = new ToolsListResponse
                {
                    success = false,
                    toolNames = new string[0],
                    error = e.Message
                };
                SendJson(context.Response, response);
            }
        }

        /// <summary>
        /// Handle POST /api/tools/execute
        /// </summary>
        private static void HandleToolExecute(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<ToolExecuteRequest>(requestBody);

                if (string.IsNullOrEmpty(request.toolName))
                {
                    SendError(context.Response, 400, "toolName is required");
                    return;
                }

                if (string.IsNullOrEmpty(request.arguments))
                {
                    request.arguments = "{}";
                }

                // Check if Unity is compiling
                if (EditorApplication.isCompiling)
                {
                    var response = new ToolExecuteResponse
                    {
                        success = false,
                        result = "",
                        requiresCompilation = true,
                        error = "Unity is currently compiling. Please wait for compilation to finish."
                    };
                    SendJson(context.Response, response);
                    return;
                }

                // ── Async dispatch path ──────────────────────────────────
                // Tools implementing IAsyncTool yield back to the Editor's
                // update loop between phases — typically across a network
                // wait. The response is sent later by PollPendingAsync once
                // the handle reports completion. Returning here keeps the
                // HttpListenerContext alive (HttpListener doesn't close the
                // connection until response.Close() is called).
                var asyncBegin = ToolExecutor.TryBeginAsync(request.toolName, request.arguments);
                if (asyncBegin != null)
                {
                    if (asyncBegin.ImmediateResult != null)
                    {
                        // Validation rejected before any async work began —
                        // record + send synchronously, same shape as the sync
                        // path below.
                        _toolCallCount++;
                        _lastToolCalled = request.toolName;
                        SessionTracker.Record(request.toolName, request.arguments, asyncBegin.ImmediateResult);
                        var rejectedResponse = new ToolExecuteResponse
                        {
                            success = true,
                            result = asyncBegin.ImmediateResult,
                            requiresCompilation = false,
                            compilationCount = -1,
                            error = null,
                        };
                        SendJson(context.Response, rejectedResponse);
                        return;
                    }

                    var now = DateTime.UtcNow;
                    _pendingAsync.Add(new PendingAsyncCall
                    {
                        Context = context,
                        Handle = asyncBegin.Handle,
                        ToolName = request.toolName,
                        Deadline = now.AddSeconds(AsyncToolDeadlineSeconds),
                        StartedAt = now,
                    });
                    return;
                }

                // ── Sync dispatch path (unchanged) ───────────────────────
                string result = ToolExecutor.ExecuteTool(request.toolName, request.arguments);
                _toolCallCount++;
                _lastToolCalled = request.toolName;
                SessionTracker.Record(request.toolName, request.arguments, result);

                // Check if tool requires compilation (based on tool name)
                bool requiresCompilation = ToolRequiresCompilation(request.toolName);

                var toolResponse = new ToolExecuteResponse
                {
                    success = true,
                    result = result,
                    requiresCompilation = requiresCompilation,
                    compilationCount = requiresCompilation ? _compilationCount : -1,
                    error = null
                };

                SendJson(context.Response, toolResponse);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Tool execution error: {e}");
                var errorResponse = new ToolExecuteResponse
                {
                    success = false,
                    result = "",
                    requiresCompilation = false,
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/batch — execute multiple tools in a single request.
        /// Collect-all error model: partial failures are returned per-result so
        /// the AI can see which steps succeeded and retry only the failed ones.
        /// </summary>
        private static void HandleBatchExecute(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<BatchExecuteRequest>(requestBody);

                if (request == null)
                {
                    Debug.LogError($"[UnityBridge] Failed to deserialize batch request. Body: {requestBody}");
                    var errorResponse = new BatchExecuteResponse
                    {
                        success = false,
                        results = new BatchToolResult[0],
                        error = "Failed to deserialize request JSON"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }

                if (request.calls == null || request.calls.Length == 0)
                {
                    var errorResponse = new BatchExecuteResponse
                    {
                        success = false,
                        results = new BatchToolResult[0],
                        error = "calls array is required and must not be empty"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }

                if (request.calls.Length > 50)
                {
                    var errorResponse = new BatchExecuteResponse
                    {
                        success = false,
                        results = new BatchToolResult[0],
                        error = "Maximum 50 tool calls per batch"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }

                // Check if Unity is compiling
                if (EditorApplication.isCompiling)
                {
                    var compileResponse = new BatchExecuteResponse
                    {
                        success = false,
                        results = new BatchToolResult[0],
                        error = "Unity is currently compiling. Please wait for compilation to finish."
                    };
                    SendJson(context.Response, compileResponse);
                    return;
                }

                var results = new BatchToolResult[request.calls.Length];
                bool anyRequiresCompilation = false;

                for (int i = 0; i < request.calls.Length; i++)
                {
                    var call = request.calls[i];
                    var toolResult = new BatchToolResult();
                    toolResult.toolName = call.toolName;

                    if (string.IsNullOrEmpty(call.toolName))
                    {
                        toolResult.success = false;
                        toolResult.error = "toolName is required";
                        results[i] = toolResult;
                        continue;
                    }

                    string args = string.IsNullOrEmpty(call.arguments) ? "{}" : call.arguments;

                    try
                    {
                        string result = ToolExecutor.ExecuteTool(call.toolName, args);
                        _toolCallCount++;
                        _lastToolCalled = call.toolName;
                        SessionTracker.Record(call.toolName, args, result);

                        toolResult.success = true;
                        toolResult.result = result;
                        toolResult.requiresCompilation = ToolRequiresCompilation(call.toolName);
                        if (toolResult.requiresCompilation)
                            anyRequiresCompilation = true;
                    }
                    catch (Exception e)
                    {
                        toolResult.success = false;
                        toolResult.error = e.Message;
                    }

                    results[i] = toolResult;
                }

                var batchResponse = new BatchExecuteResponse
                {
                    success = true,
                    results = results,
                    error = null
                };
                SendJson(context.Response, batchResponse);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Batch execution error: {e}");
                var errorResponse = new BatchExecuteResponse
                {
                    success = false,
                    results = new BatchToolResult[0],
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/context/gather
        /// </summary>
        private static void HandleContextGather(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<ContextGatherRequest>(requestBody);

                // Build context options
                var options = new UnityContextGatherer.ContextOptions
                {
                    includeProjectInfo = request.includeProjectInfo,
                    includeSelection = request.includeSelection,
                    includeSceneSummary = request.includeSceneSummary,
                    includeSceneHierarchy = request.includeSceneHierarchy,
                    includeScriptsList = request.includeScriptsList,
                    includeScriptsContent = request.includeScriptsContent,
                    includePackages = request.includePackages,
                    includeErrors = request.includeErrors,
                    includeCameras = request.includeCameras,
                    sceneMaxDepth = request.sceneMaxDepth,
                    maxScriptBytes = request.maxScriptBytes
                };

                // Gather context data
                var data = UnityContextGatherer.GatherRawData(options);
                var gatherTimings = UnityContextGatherer.LastGatherTimings;
                string contextJson = JsonUtility.ToJson(data);
                string projectHash = UnityContextGatherer.GetProjectHash();

                var response = new ContextGatherResponse
                {
                    success = true,
                    projectHash = projectHash,
                    context = contextJson,
                    error = null,
                    total_ms = gatherTimings.totalMs,
                    project_info_ms = gatherTimings.projectInfoMs,
                    scene_summary_ms = gatherTimings.sceneSummaryMs,
                    hierarchy_ms = gatherTimings.hierarchyMs,
                    scripts_ms = gatherTimings.scriptsMs,
                    selection_ms = gatherTimings.selectionMs,
                    packages_ms = gatherTimings.packagesMs,
                    errors_ms = gatherTimings.errorsMs,
                };

                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Context gather error: {e}");
                var errorResponse = new ContextGatherResponse
                {
                    success = false,
                    projectHash = "",
                    context = "",
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle GET /api/scripts/list
        /// </summary>
        private static void HandleScriptList(HttpListenerContext context)
        {
            try
            {
                var scriptGuids = AssetDatabase.FindAssets("t:MonoScript");
                var scripts = new List<ScriptInfo>();

                foreach (var guid in scriptGuids)
                {
                    string fullPath = AssetDatabase.GUIDToAssetPath(guid);
                    
                    // Skip editor scripts in Packages folder
                    if (fullPath.StartsWith("Packages/"))
                        continue;
                    
                    // Skip meta files
                    if (fullPath.EndsWith(".meta"))
                        continue;

                    string path = fullPath;
                    if (path.StartsWith("Assets/"))
                        path = path.Substring(7); // Remove "Assets/" prefix

                    string name = Path.GetFileNameWithoutExtension(fullPath);

                    scripts.Add(new ScriptInfo
                    {
                        path = path,
                        name = name,
                        fullPath = fullPath
                    });
                }

                var response = new ScriptListResponse
                {
                    success = true,
                    scripts = scripts.ToArray(),
                    error = null
                };

                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Script list error: {e}");
                var errorResponse = new ScriptListResponse
                {
                    success = false,
                    scripts = new ScriptInfo[0],
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/scripts/content - Get content of multiple scripts
        /// </summary>
        private static void HandleScriptContent(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<ScriptContentRequest>(requestBody);
                
                var scriptItems = new List<ScriptContentItem>();
                
                if (request.paths != null)
                {
                    foreach (var path in request.paths)
                    {
                        var item = new ScriptContentItem
                        {
                            path = path,
                            name = Path.GetFileNameWithoutExtension(path),
                            success = false
                        };
                        
                        try
                        {
                            // Construct full path
                            string fullPath = path;
                            if (!path.StartsWith("Assets/"))
                            {
                                fullPath = "Assets/" + path;
                            }
                            
                            // Read file content
                            string absolutePath = Path.Combine(Application.dataPath, "..", fullPath);
                            if (File.Exists(absolutePath))
                            {
                                item.content = File.ReadAllText(absolutePath);
                                item.success = true;
                            }
                            else
                            {
                                item.error = "File not found";
                            }
                        }
                        catch (Exception e)
                        {
                            item.error = e.Message;
                        }
                        
                        scriptItems.Add(item);
                    }
                }
                
                var response = new ScriptContentResponse
                {
                    success = true,
                    scripts = scriptItems.ToArray(),
                    error = null
                };
                
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Script content error: {e}");
                var errorResponse = new ScriptContentResponse
                {
                    success = false,
                    scripts = new ScriptContentItem[0],
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle GET /api/assets/list
        /// </summary>
        private static void HandleAssetList(HttpListenerContext context)
        {
            try
            {
                var assets = new List<AssetInfo>();
                
                // Get query parameter for asset type filter (optional)
                string typeFilter = context.Request.QueryString["type"]; // e.g., "Prefab", "Material", "Texture2D"
                
                string searchQuery = "t:Object";
                if (!string.IsNullOrEmpty(typeFilter))
                {
                    searchQuery = $"t:{typeFilter}";
                }

                var guids = AssetDatabase.FindAssets(searchQuery);

                foreach (var guid in guids)
                {
                    string fullPath = AssetDatabase.GUIDToAssetPath(guid);
                    
                    // Skip Packages folder
                    if (fullPath.StartsWith("Packages/"))
                        continue;
                    
                    // Skip meta files
                    if (fullPath.EndsWith(".meta"))
                        continue;
                    
                    // Skip scripts (handled separately)
                    if (fullPath.EndsWith(".cs"))
                        continue;

                    string path = fullPath;
                    if (path.StartsWith("Assets/"))
                        path = path.Substring(7); // Remove "Assets/" prefix

                    string name = Path.GetFileNameWithoutExtension(fullPath);
                    string type = AssetDatabase.GetMainAssetTypeAtPath(fullPath)?.Name ?? "Object";

                    assets.Add(new AssetInfo
                    {
                        path = path,
                        name = name,
                        type = type,
                        fullPath = fullPath
                    });
                }

                var response = new AssetListResponse
                {
                    success = true,
                    assets = assets.ToArray(),
                    error = null
                };

                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Asset list error: {e}");
                var errorResponse = new AssetListResponse
                {
                    success = false,
                    assets = new AssetInfo[0],
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle GET /api/errors/context
        /// </summary>
        private static void HandleGetErrorContext(HttpListenerContext context)
        {
            try
            {
                string errorContext = ErrorTracker.GetAllErrorContext();
                var response = new ErrorContextResponse
                {
                    success = true,
                    errorContext = errorContext,
                    error = null
                };
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Error context error: {e}");
                var errorResponse = new ErrorContextResponse
                {
                    success = false,
                    errorContext = "",
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle GET /api/console/events — returns and clears pending error/
        /// exception log events. Delegates to RuntimeLogStream which owns the
        /// underlying ring buffer. Wire shape preserved exactly so the
        /// renderer's useConsoleWatcher.ts continues to work unchanged.
        /// </summary>
        private static void HandleConsoleEvents(HttpListenerContext context)
        {
            var snapshot = RuntimeLogStream.DrainWithConditionDedup();

            var events = new List<object>();
            foreach (var evt in snapshot)
            {
                events.Add(new
                {
                    message = evt.Message,
                    stackTrace = evt.StackTrace,
                    logType = evt.LogType,
                    timestamp = evt.Timestamp,
                });
            }

            SendJson(context.Response, new { events });
        }

        /// <summary>
        /// Handle POST /api/file/backup
        /// </summary>
        private static void HandleFileBackup(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<FileBackupRequest>(requestBody);
                
                if (string.IsNullOrEmpty(request.filePath) || string.IsNullOrEmpty(request.turnId))
                {
                    var errorResponse = new FileBackupResponse
                    {
                        success = false,
                        backupPath = "",
                        error = "filePath and turnId are required"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }
                
                string filePath = request.filePath;
                if (!filePath.StartsWith("Assets/"))
                {
                    filePath = "Assets/" + filePath;
                }
                
                if (!File.Exists(filePath))
                {
                    var errorResponse = new FileBackupResponse
                    {
                        success = false,
                        backupPath = "",
                        error = $"File not found: {filePath}"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }
                
                // Create backup path
                string backupDir = Path.Combine(".gladekit-backups", $"turn-{request.turnId}", "files");
                string relativePath = filePath.Replace("Assets/", "");
                string backupPath = Path.Combine(backupDir, relativePath);
                string backupDirPath = Path.GetDirectoryName(backupPath);
                
                if (!Directory.Exists(backupDirPath))
                {
                    Directory.CreateDirectory(backupDirPath);
                }
                
                // Copy file
                File.Copy(filePath, backupPath, true);
                
                // Also backup .meta file if it exists
                string metaPath = filePath + ".meta";
                if (File.Exists(metaPath))
                {
                    File.Copy(metaPath, backupPath + ".meta", true);
                }
                
                var response = new FileBackupResponse
                {
                    success = true,
                    backupPath = backupPath,
                    error = null
                };
                
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] File backup error: {e}");
                var errorResponse = new FileBackupResponse
                {
                    success = false,
                    backupPath = "",
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/gameobject/backup
        /// </summary>
        private static void HandleGameObjectBackup(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<GameObjectBackupRequest>(requestBody);
                
                if (string.IsNullOrEmpty(request.gameObjectPath) || string.IsNullOrEmpty(request.turnId))
                {
                    var errorResponse = new GameObjectBackupResponse
                    {
                        success = false,
                        backupPath = "",
                        error = "gameObjectPath and turnId are required"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }
                
                GameObject obj = ToolUtils.FindGameObjectByPath(request.gameObjectPath);
                if (obj == null)
                {
                    var errorResponse = new GameObjectBackupResponse
                    {
                        success = false,
                        backupPath = "",
                        error = $"GameObject not found: {request.gameObjectPath}"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }
                
                string backupPath = GameObjectStateBackup.SaveState(obj, request.turnId);
                
                var response = new GameObjectBackupResponse
                {
                    success = true,
                    backupPath = backupPath,
                    error = null
                };
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] GameObject backup error: {e}");
                var errorResponse = new GameObjectBackupResponse
                {
                    success = false,
                    backupPath = "",
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/backup/exists
        /// </summary>
        private static void HandleBackupExists(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<BackupExistsRequest>(requestBody);

                if (request == null || request.paths == null)
                {
                    var errorResponse = new BackupExistsResponse
                    {
                        success = false,
                        existingPaths = new string[0],
                        error = "paths array is required"
                    };
                    SendJson(context.Response, errorResponse);
                    return;
                }

                var existing = new List<string>();
                foreach (var rawPath in request.paths)
                {
                    if (string.IsNullOrEmpty(rawPath))
                    {
                        continue;
                    }

                    var normalized = rawPath.Replace('\\', '/');
                    if (File.Exists(normalized))
                    {
                        existing.Add(rawPath);
                    }
                }

                var response = new BackupExistsResponse
                {
                    success = true,
                    existingPaths = existing.ToArray(),
                    error = null
                };
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Backup exists check error: {e}");
                var errorResponse = new BackupExistsResponse
                {
                    success = false,
                    existingPaths = new string[0],
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/turn/revert
        /// </summary>
        private static void HandleTurnRevert(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<TurnRevertRequest>(requestBody);
                
                int filesRestored = 0;
                int filesDeleted = 0;
                int gameObjectsRestored = 0;
                int gameObjectsDeleted = 0;
                
                // Process file changes (in reverse order)
                if (request.fileChanges != null)
                {
                    for (int i = request.fileChanges.Length - 1; i >= 0; i--)
                    {
                        var change = request.fileChanges[i];
                        
                        if (change.changeType == "created")
                        {
                            // Delete created file
                            // Normalize path (Unity uses forward slashes)
                            string normalizedPath = change.filePath.Replace('\\', '/');
                            
                            if (File.Exists(normalizedPath))
                            {
                                Debug.Log($"[TurnRevert] Deleting created file: {normalizedPath}");
                                try
                                {
                                    File.Delete(normalizedPath);
                                    string metaPath = normalizedPath + ".meta";
                                    if (File.Exists(metaPath))
                                    {
                                        File.Delete(metaPath);
                                    }
                                    filesDeleted++;
                                    Debug.Log($"[TurnRevert] Successfully deleted file: {normalizedPath}");
                                }
                                catch (Exception e)
                                {
                                    Debug.LogError($"[TurnRevert] Failed to delete file {normalizedPath}: {e.Message}");
                                }
                            }
                            else
                            {
                                Debug.LogWarning($"[TurnRevert] File not found for deletion: {normalizedPath} (original: {change.filePath})");
                            }
                        }
                        else if (change.changeType == "modified" || change.changeType == "deleted")
                        {
                            // Restore from backup
                            if (!string.IsNullOrEmpty(change.backupPath) && File.Exists(change.backupPath))
                            {
                                string dir = Path.GetDirectoryName(change.filePath);
                                if (!Directory.Exists(dir))
                                {
                                    Directory.CreateDirectory(dir);
                                }
                                
                                File.Copy(change.backupPath, change.filePath, true);
                                string metaBackup = change.backupPath + ".meta";
                                string metaPath = change.filePath + ".meta";
                                if (File.Exists(metaBackup))
                                {
                                    File.Copy(metaBackup, metaPath, true);
                                }
                                filesRestored++;
                            }
                        }
                    }
                }
                
                // Process GameObject changes (in reverse order)
                if (request.gameObjectChanges != null)
                {
                    for (int i = request.gameObjectChanges.Length - 1; i >= 0; i--)
                    {
                        var change = request.gameObjectChanges[i];
                        
                        if (change.changeType == "created")
                        {
                            // Destroy created GameObject
                            GameObject obj = ToolUtils.FindGameObjectByPath(change.gameObjectPath);
                            if (obj != null)
                            {
                                Debug.Log($"[TurnRevert] Destroying created GameObject: {change.gameObjectPath}");
                                UnityEngine.Object.DestroyImmediate(obj);
                                gameObjectsDeleted++;
                            }
                            else
                            {
                                Debug.LogWarning($"[TurnRevert] GameObject not found for deletion: {change.gameObjectPath}");
                            }
                        }
                        else if (change.changeType == "modified")
                        {
                            // Restore state from backup using prefab system for complete restoration including components
                            if (!string.IsNullOrEmpty(change.stateBackupPath))
                            {
                                var state = GameObjectStateBackup.LoadState(change.stateBackupPath);
                                if (state != null)
                                {
                                    GameObject obj = ToolUtils.FindGameObjectByPath(change.gameObjectPath);
                                    if (obj != null)
                                    {
                                        // Use RestoreStateToGameObject for complete restoration including components
                                        // This restores from prefab backup which captures all components
                                        GameObject restoredObj = GameObjectStateBackup.RestoreStateToGameObject(obj, state);
                                        if (restoredObj != null)
                                        {
                                            gameObjectsRestored++;
                                            Debug.Log($"[TurnRevert] Restored GameObject: {change.gameObjectPath} (components restored)");
                                        }
                                        else
                                        {
                                            Debug.LogWarning($"[TurnRevert] Failed to restore GameObject: {change.gameObjectPath}");
                                        }
                                    }
                                    else
                                    {
                                        Debug.LogWarning($"[TurnRevert] GameObject not found for restoration: {change.gameObjectPath}");
                                    }
                                }
                                else
                                {
                                    Debug.LogError($"[TurnRevert] Failed to load state from backup: {change.stateBackupPath}");
                                }
                            }
                        }
                        else if (change.changeType == "deleted")
                        {
                            // Recreate GameObject from state
                            if (!string.IsNullOrEmpty(change.stateBackupPath))
                            {
                                var state = GameObjectStateBackup.LoadState(change.stateBackupPath);
                                if (state != null)
                                {
                                    // Create new GameObject with the saved name
                                    // RestoreStateToGameObject will recreate as primitive if needed
                                    GameObject recreated = new GameObject(state.name);
                                    
                                    // Restore state directly to the newly created GameObject
                                    // Note: RestoreStateToGameObject may recreate the GameObject as a primitive and return a new reference
                                    GameObject restoredObj = GameObjectStateBackup.RestoreStateToGameObject(recreated, state);
                                    if (restoredObj != null)
                                    {
                                        gameObjectsRestored++;
                                        Debug.Log($"[TurnRevert] Recreated GameObject: {change.gameObjectPath} (name: {state.name})");
                                    }
                                    else
                                    {
                                        Debug.LogWarning($"[TurnRevert] Failed to recreate GameObject: {change.gameObjectPath}");
                                        // Clean up if restoration failed
                                        if (recreated != null)
                                            UnityEngine.Object.DestroyImmediate(recreated);
                                    }
                                }
                                else
                                {
                                    Debug.LogError($"[TurnRevert] Failed to load state from backup: {change.stateBackupPath}");
                                }
                            }
                            else
                            {
                                Debug.LogWarning($"[TurnRevert] No state backup path for deleted GameObject: {change.gameObjectPath}");
                            }
                        }
                    }
                }
                
                // Refresh asset database after file changes
                if (filesRestored > 0 || filesDeleted > 0)
                {
                    AssetDatabase.Refresh();
                }
                
                // Delete backup folders after revert (cleanup)
                // 1. JSON backups in .gladekit-backups/
                string backupDir = Path.Combine(".gladekit-backups", $"turn-{request.turnId}");
                if (Directory.Exists(backupDir))
                {
                    try
                    {
                        Directory.Delete(backupDir, true);
                        Debug.Log($"[TurnRevert] Deleted backup folder: {backupDir}");
                    }
                    catch (Exception e)
                    {
                        Debug.LogWarning($"[TurnRevert] Failed to delete backup folder: {e.Message}");
                    }
                }
                
                // 2. Prefab backups in Assets/Temp/GladeKitBackups/
                string prefabBackupDir = Path.Combine("Assets", "Temp", "GladeKitBackups", $"turn-{request.turnId}");
                if (Directory.Exists(prefabBackupDir))
                {
                    try
                    {
                        Directory.Delete(prefabBackupDir, true);
                        // Also delete .meta files
                        string metaFile = prefabBackupDir + ".meta";
                        if (File.Exists(metaFile))
                        {
                            File.Delete(metaFile);
                        }
                        AssetDatabase.Refresh();
                        Debug.Log($"[TurnRevert] Deleted prefab backup folder: {prefabBackupDir}");
                    }
                    catch (Exception e)
                    {
                        Debug.LogWarning($"[TurnRevert] Failed to delete prefab backup folder: {e.Message}");
                    }
                }
                
                var response = new TurnRevertResponse
                {
                    success = true,
                    message = $"Reverted turn: {filesRestored} files restored, {filesDeleted} files deleted, {gameObjectsRestored} GameObjects restored, {gameObjectsDeleted} GameObjects deleted",
                    error = null,
                    filesRestored = filesRestored,
                    filesDeleted = filesDeleted,
                    gameObjectsRestored = gameObjectsRestored,
                    gameObjectsDeleted = gameObjectsDeleted
                };
                
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Turn revert error: {e}");
                var errorResponse = new TurnRevertResponse
                {
                    success = false,
                    message = "",
                    error = e.Message,
                    filesRestored = 0,
                    filesDeleted = 0,
                    gameObjectsRestored = 0,
                    gameObjectsDeleted = 0
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Handle POST /api/turn/accept
        /// </summary>
        private static void HandleTurnAccept(HttpListenerContext context)
        {
            try
            {
                string requestBody = ReadRequestBody(context.Request);
                var request = JsonUtility.FromJson<TurnAcceptRequest>(requestBody);
                
                // Delete backup folders for this turn
                // 1. JSON backups in .gladekit-backups/
                string backupDir = Path.Combine(".gladekit-backups", $"turn-{request.turnId}");
                if (Directory.Exists(backupDir))
                {
                    try
                    {
                        Directory.Delete(backupDir, true);
                        Debug.Log($"[TurnAccept] Deleted backup folder: {backupDir}");
                    }
                    catch (Exception e)
                    {
                        Debug.LogWarning($"[TurnAccept] Failed to delete backup folder: {e.Message}");
                    }
                }
                else
                {
                    Debug.Log($"[TurnAccept] Backup folder not found (may have been already deleted): {backupDir}");
                }
                
                // 2. Prefab backups in Assets/Temp/GladeKitBackups/
                string prefabBackupDir = Path.Combine("Assets", "Temp", "GladeKitBackups", $"turn-{request.turnId}");
                if (Directory.Exists(prefabBackupDir))
                {
                    try
                    {
                        Directory.Delete(prefabBackupDir, true);
                        // Also delete .meta files
                        string metaFile = prefabBackupDir + ".meta";
                        if (File.Exists(metaFile))
                        {
                            File.Delete(metaFile);
                        }
                        AssetDatabase.Refresh();
                        Debug.Log($"[TurnAccept] Deleted prefab backup folder: {prefabBackupDir}");
                    }
                    catch (Exception e)
                    {
                        Debug.LogWarning($"[TurnAccept] Failed to delete prefab backup folder: {e.Message}");
                    }
                }
                
                var response = new TurnAcceptResponse
                {
                    success = true,
                    message = $"Accepted turn {request.turnId}",
                    error = null
                };
                
                SendJson(context.Response, response);
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Turn accept error: {e}");
                var errorResponse = new TurnAcceptResponse
                {
                    success = false,
                    message = "",
                    error = e.Message
                };
                SendJson(context.Response, errorResponse);
            }
        }

        /// <summary>
        /// Check if a tool requires compilation
        /// </summary>
        private static bool ToolRequiresCompilation(string toolName)
        {
            // Tools that trigger compilation
            return toolName == "create_script" || 
                   toolName == "modify_script" ||
                   toolName == "add_component"; // Adding components may require scripts to be compiled first
        }

        /// <summary>
        /// Read request body as string
        /// </summary>
        private static string ReadRequestBody(HttpListenerRequest request)
        {
            using (var reader = new StreamReader(request.InputStream, request.ContentEncoding))
            {
                return reader.ReadToEnd();
            }
        }

        /// <summary>
        /// Phase 2.2 feature flag: when true, response write + close is pushed to a background
        /// Task so the Unity main thread is freed to process the next queued request sooner.
        /// Serialization (JsonUtility.ToJson) stays on the main thread because Unity's JSON
        /// serializer is not guaranteed thread-safe for Unity objects.
        ///
        /// Toggle via Unity EditorPrefs key "GladeAI.OffloadSerialization" (default: true).
        /// Set to false to restore the previous fully-synchronous behavior.
        /// </summary>
        private static bool OffloadSerializationEnabled
        {
            get { return EditorPrefs.GetBool("GladeAI.OffloadSerialization", true); }
        }

        /// <summary>
        /// Send JSON response. Serialization happens on the current thread; the blocking
        /// stream write + Close are offloaded to a background Task when the feature flag is on.
        /// </summary>
        private static void SendJson(HttpListenerResponse response, object obj)
        {
            // Serialize on the calling (main) thread — JsonUtility is not guaranteed thread-safe.
            string json = JsonUtility.ToJson(obj);
            byte[] buffer = Encoding.UTF8.GetBytes(json);

            response.ContentType = "application/json";
            response.ContentLength64 = buffer.Length;
            response.StatusCode = 200;

            WriteAndClose(response, buffer);
        }

        /// <summary>
        /// Write a pre-built response body + close the HTTP response, optionally off the main thread.
        /// Captured variables are all primitives / byte[], safe for background use.
        /// </summary>
        private static void WriteAndClose(HttpListenerResponse response, byte[] buffer)
        {
            if (OffloadSerializationEnabled)
            {
                Task.Run(() =>
                {
                    try
                    {
                        response.OutputStream.Write(buffer, 0, buffer.Length);
                    }
                    catch (Exception e)
                    {
                        Debug.LogWarning($"[UnityBridge] Background response write failed: {e.Message}");
                    }
                    finally
                    {
                        try { response.Close(); } catch { /* client may have disconnected */ }
                    }
                });
            }
            else
            {
                try
                {
                    response.OutputStream.Write(buffer, 0, buffer.Length);
                }
                finally
                {
                    response.Close();
                }
            }
        }

        /// <summary>
        /// Handle settings update request. Reads optional bool fields manually because
        /// JsonUtility silently drops <c>Nullable&lt;bool&gt;</c> fields, which made the
        /// pre-2026-05-07 implementation a no-op in production (verified live: no
        /// "Updated referenceDemoAssets" log fired despite repeated POSTs).
        /// </summary>
        private static void HandleSettings(HttpListenerContext context)
        {
            var response = context.Response;
            try
            {
                using (var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8))
                {
                    string json = reader.ReadToEnd();

                    bool? referenceDemoAssets = TryReadBoolField(json, "referenceDemoAssets");
                    if (referenceDemoAssets.HasValue)
                    {
                        EditorPrefs.SetBool("GladeAI.ReferenceDemoAssets", referenceDemoAssets.Value);
                        Debug.Log($"[UnityBridge] Updated referenceDemoAssets setting: {referenceDemoAssets.Value}");
                    }

                    bool? assetPipelineEnabled = TryReadBoolField(json, "assetPipelineEnabled");
                    if (assetPipelineEnabled.HasValue)
                    {
                        AssetPipelineGuard.SetEnabled(assetPipelineEnabled.Value);
                        Debug.Log($"[UnityBridge] Updated assetPipelineEnabled setting: {assetPipelineEnabled.Value}");
                    }

                    // Plain anonymous types don't serialize through JsonUtility — emit literal JSON.
                    byte[] buffer = Encoding.UTF8.GetBytes("{\"success\":true}");

                    response.ContentType = "application/json";
                    response.ContentLength64 = buffer.Length;
                    response.StatusCode = 200;
                    response.OutputStream.Write(buffer, 0, buffer.Length);
                }
            }
            catch (Exception e)
            {
                Debug.LogError($"[UnityBridge] Error handling settings: {e.Message}");
                SendError(response, 500, $"Internal error: {e.Message}");
            }
            finally
            {
                response.Close();
            }
        }

        private static bool? TryReadBoolField(string json, string fieldName)
        {
            if (string.IsNullOrEmpty(json)) return null;
            string pattern = "\"" + System.Text.RegularExpressions.Regex.Escape(fieldName) + "\"\\s*:\\s*(true|false)";
            var match = System.Text.RegularExpressions.Regex.Match(
                json, pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (!match.Success) return null;
            return string.Equals(match.Groups[1].Value, "true", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>
        /// Send error response. Serialization stays on the calling thread; the write is
        /// offloaded when OffloadSerializationEnabled is true (see SendJson).
        /// </summary>
        private static void SendError(HttpListenerResponse response, int statusCode, string message)
        {
            var errorObj = new { error = message };
            string json = JsonUtility.ToJson(errorObj);
            byte[] buffer = Encoding.UTF8.GetBytes(json);

            response.ContentType = "application/json";
            response.ContentLength64 = buffer.Length;
            response.StatusCode = statusCode;

            WriteAndClose(response, buffer);
        }

        /// <summary>UTC time of the last request received by the bridge, or DateTime.MinValue if none.</summary>
        public static DateTime LastRequestTime => _lastRequestTime;

        /// <summary>
        /// Check if a client is currently connected (has made a request recently)
        /// </summary>
        public static bool IsConnected()
        {
            if (!_isRunning)
                return false;
            
            if (_lastRequestTime == DateTime.MinValue)
                return false; // Never received a request
            
            double secondsSinceLastRequest = (DateTime.Now - _lastRequestTime).TotalSeconds;
            return secondsSinceLastRequest < ConnectionTimeoutSeconds;
        }

        /// <summary>
        /// Menu item: Open the GladeKit MCP status window.
        /// Kept for backwards compatibility — redirects to the new EditorWindow.
        /// </summary>
        [MenuItem("Window/GladeKit/Check Status")]
        public static void CheckServerStatus()
        {
            GladeKitMCPWindow.ShowWindow();
        }
    }
}
