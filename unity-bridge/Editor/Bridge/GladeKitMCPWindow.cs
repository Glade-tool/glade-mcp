using System;
using System.Collections.Generic;
using GladeAgenticAI.Services;
using UnityEditor;
using UnityEngine;

namespace GladeAgenticAI.Bridge
{
    /// <summary>
    /// Editor window for monitoring GladeKit MCP bridge status.
    /// Window > GladeKit MCP
    ///
    /// The MCP server is a stdio process launched by the AI client (Cursor, Claude Code, etc.),
    /// not by Unity. This window monitors the bridge that the MCP server connects to.
    /// </summary>
    public class GladeKitMCPWindow : EditorWindow
    {
        private GUIStyle _headerStyle;
        private GUIStyle _helpBoxStyle;
        private GUIStyle _timelineStyle;
        private GUIStyle _diagnosticsLineStyle;
        private bool _stylesInitialized;
        private bool _showSetup;
        private bool _showActivityTimeline = true;
        private bool _showDiagnostics = true;
        private Vector2 _scrollPos;

        [MenuItem("Window/GladeKit MCP")]
        public static void ShowWindow()
        {
            var window = GetWindow<GladeKitMCPWindow>("GladeKit MCP");
            window.minSize = new Vector2(360, 300);
        }

        private void OnEnable()
        {
            EditorApplication.update += RepaintPeriodic;
        }

        private void OnDisable()
        {
            EditorApplication.update -= RepaintPeriodic;
        }

        private float _lastRepaintTime;
        private void RepaintPeriodic()
        {
            if (EditorApplication.timeSinceStartup - _lastRepaintTime > 2.0)
            {
                _lastRepaintTime = (float)EditorApplication.timeSinceStartup;
                Repaint();
            }
        }

        private void InitStyles()
        {
            if (_stylesInitialized) return;
            _headerStyle = new GUIStyle(EditorStyles.boldLabel) { fontSize = 14 };
            _timelineStyle = new GUIStyle(EditorStyles.miniLabel)
            {
                wordWrap = true,
                richText = true,
            };
            _diagnosticsLineStyle = new GUIStyle(EditorStyles.miniLabel)
            {
                wordWrap = true,
                richText = true,
            };
            _stylesInitialized = true;
        }

        private void OnGUI()
        {
            InitStyles();

            _scrollPos = EditorGUILayout.BeginScrollView(_scrollPos);

            EditorGUILayout.Space(8);
            EditorGUILayout.LabelField("GladeKit MCP", _headerStyle);
            EditorGUILayout.Space(4);

            DrawBridgeStatus();
            EditorGUILayout.Space(8);
            DrawClientStatus();
            EditorGUILayout.Space(8);
            DrawToolStats();
            EditorGUILayout.Space(8);
            DrawSessionActivity();
            EditorGUILayout.Space(8);
            DrawDiagnostics();
            EditorGUILayout.Space(12);
            DrawSetupHelp();

            EditorGUILayout.EndScrollView();
        }

        private void DrawBridgeStatus()
        {
            EditorGUILayout.LabelField("Unity Bridge", EditorStyles.boldLabel);

            bool running = UnityBridgeServer.IsRunning;

            using (new EditorGUILayout.HorizontalScope())
            {
                DrawStatusDot(running);
                EditorGUILayout.LabelField(
                    running ? "Running on localhost:8765" : "Not running",
                    GUILayout.Width(220));

                if (running)
                {
                    // Restart drains in-flight async handles and queued requests
                    // via StopServer() before rebinding — see UnityBridgeServer
                    // for the cleanup contract.
                    if (GUILayout.Button("Restart", GUILayout.Width(60)))
                        UnityBridgeServer.RestartServer();
                    if (GUILayout.Button("Stop", GUILayout.Width(50)))
                        UnityBridgeServer.StopServer();
                }
                else
                {
                    if (GUILayout.Button("Start", GUILayout.Width(50)))
                        UnityBridgeServer.StartServer();
                }
            }
        }

        private void DrawClientStatus()
        {
            EditorGUILayout.LabelField("AI Client", EditorStyles.boldLabel);

            bool connected = UnityBridgeServer.IsConnected();

            using (new EditorGUILayout.HorizontalScope())
            {
                DrawStatusDot(connected);
                if (connected)
                {
                    EditorGUILayout.LabelField("Connected");
                }
                else if (UnityBridgeServer.LastRequestTime != DateTime.MinValue)
                {
                    double ago = (DateTime.Now - UnityBridgeServer.LastRequestTime).TotalSeconds;
                    if (ago < 60)
                        EditorGUILayout.LabelField($"Last seen {ago:F0}s ago");
                    else if (ago < 3600)
                        EditorGUILayout.LabelField($"Last seen {ago / 60:F0}m ago");
                    else
                        EditorGUILayout.LabelField("Disconnected");
                }
                else
                {
                    EditorGUILayout.LabelField("No client connected yet");
                }
            }
        }

        private void DrawToolStats()
        {
            EditorGUILayout.LabelField("Session Stats", EditorStyles.boldLabel);

            int callCount = UnityBridgeServer.ToolCallCount;
            string lastTool = UnityBridgeServer.LastToolCalled ?? "\u2014";

            EditorGUILayout.LabelField($"Tool calls:  {callCount}");
            EditorGUILayout.LabelField($"Last tool:   {lastTool}");
        }

        private void DrawSessionActivity()
        {
            using (new EditorGUILayout.HorizontalScope())
            {
                EditorGUILayout.LabelField("Session Activity", EditorStyles.boldLabel);
                GUILayout.FlexibleSpace();
                if (GUILayout.Button("Clear", EditorStyles.miniButton, GUILayout.Width(50)))
                {
                    if (EditorUtility.DisplayDialog("Clear Session Summary",
                        "Reset the session mutation log?", "Clear", "Cancel"))
                    {
                        SessionTracker.Reset();
                    }
                }
            }

            var summary = SessionTracker.BuildSummary(maxTimelineReturn: 25);

            int mutations = summary.TryGetValue("mutations", out var m) && m is int mi ? mi : 0;
            int successCount = summary.TryGetValue("successCount", out var s) && s is int si ? si : 0;
            int errorCount = summary.TryGetValue("errorCount", out var e) && e is int ei ? ei : 0;
            int elapsedSeconds = summary.TryGetValue("elapsedSeconds", out var el) && el is int eli ? eli : 0;

            EditorGUILayout.LabelField(
                $"Mutations: {mutations}    OK: {successCount}    Errors: {errorCount}    Uptime: {FormatElapsed(elapsedSeconds)}");

            if (mutations == 0)
            {
                EditorGUILayout.HelpBox("No mutations yet this session.", MessageType.None);
                return;
            }

            // Per-category breakdown
            if (summary.TryGetValue("byCategory", out var bcObj) &&
                bcObj is Dictionary<string, object> byCategory && byCategory.Count > 0)
            {
                EditorGUILayout.Space(2);
                foreach (var kvp in byCategory)
                {
                    if (!(kvp.Value is Dictionary<string, object> bucket)) continue;
                    int created  = bucket.TryGetValue("created", out var c) && c is int ci ? ci : 0;
                    int modified = bucket.TryGetValue("modified", out var md) && md is int mdi ? mdi : 0;
                    int destroyed = bucket.TryGetValue("destroyed", out var d) && d is int di ? di : 0;
                    var parts = new List<string>(3);
                    if (created > 0) parts.Add($"+{created}");
                    if (modified > 0) parts.Add($"~{modified}");
                    if (destroyed > 0) parts.Add($"-{destroyed}");
                    string countLabel = parts.Count > 0 ? string.Join(" ", parts) : "—";
                    EditorGUILayout.LabelField($"  {kvp.Key,-14} {countLabel}");
                }
            }

            EditorGUILayout.Space(4);
            _showActivityTimeline = EditorGUILayout.Foldout(
                _showActivityTimeline,
                $"Recent ({Mathf.Min(mutations, 25)})",
                true);

            if (!_showActivityTimeline) return;

            if (!summary.TryGetValue("timeline", out var tlObj) ||
                !(tlObj is List<Dictionary<string, object>> timeline))
            {
                return;
            }

            foreach (var entry in timeline)
            {
                string tool   = entry.TryGetValue("tool", out var t) ? t as string ?? "?" : "?";
                string action = entry.TryGetValue("action", out var a) ? a as string ?? "" : "";
                string target = entry.TryGetValue("target", out var tg) ? tg as string ?? "" : "";
                bool success  = entry.TryGetValue("success", out var su) && su is bool sub && sub;

                string glyph = action == "create" ? "+" : action == "destroy" ? "-" : "~";
                string status = success ? "" : " <color=#cc5555>(error)</color>";
                string targetSuffix = string.IsNullOrEmpty(target) ? "" : $"  →  {target}";
                EditorGUILayout.LabelField($"{glyph} {tool}{targetSuffix}{status}", _timelineStyle);
            }
        }

        private static string FormatElapsed(int seconds)
        {
            if (seconds < 60) return $"{seconds}s";
            if (seconds < 3600) return $"{seconds / 60}m {seconds % 60}s";
            return $"{seconds / 3600}h {(seconds % 3600) / 60}m";
        }

        /// <summary>
        /// Render the bridge diagnostics panel — last ~50 server-lifecycle and
        /// fault events captured by <see cref="BridgeDiagnostics"/>. Intended
        /// to make ReadTimeout / wedged-bridge incidents self-diagnosing
        /// without forcing the user to scrape the Console.
        /// </summary>
        private void DrawDiagnostics()
        {
            using (new EditorGUILayout.HorizontalScope())
            {
                EditorGUILayout.LabelField("Bridge Diagnostics", EditorStyles.boldLabel);
                GUILayout.FlexibleSpace();
                if (GUILayout.Button("Clear", EditorStyles.miniButton, GUILayout.Width(50)))
                {
                    if (EditorUtility.DisplayDialog("Clear Bridge Diagnostics",
                        "Drop all recorded bridge events?", "Clear", "Cancel"))
                    {
                        BridgeDiagnostics.Clear();
                    }
                }
            }

            var (errors, warnings, infos) = BridgeDiagnostics.SeverityCounts();
            EditorGUILayout.LabelField(
                $"Errors: {errors}    Warnings: {warnings}    Info: {infos}");

            var entries = BridgeDiagnostics.SnapshotNewestFirst();

            if (entries.Count == 0)
            {
                EditorGUILayout.HelpBox(
                    "No bridge events yet. Restart events, request errors, and tool faults will appear here.",
                    MessageType.None);
                return;
            }

            EditorGUILayout.Space(2);
            _showDiagnostics = EditorGUILayout.Foldout(
                _showDiagnostics,
                $"Recent ({entries.Count})",
                true);

            if (!_showDiagnostics) return;

            DateTime nowUtc = DateTime.UtcNow;
            foreach (var entry in entries)
            {
                string color = SeverityHex(entry.Level);
                string glyph = SeverityGlyph(entry.Level);
                string ago = FormatAgo(nowUtc - entry.Timestamp);
                string localTime = entry.Timestamp.ToLocalTime().ToString("HH:mm:ss");
                string message = entry.Message ?? "";
                if (message.Length > 240) message = message.Substring(0, 237) + "...";
                EditorGUILayout.LabelField(
                    $"<color={color}>{glyph} {localTime} ({ago})  {entry.Source}: {message}</color>",
                    _diagnosticsLineStyle);
            }
        }

        private static string SeverityHex(BridgeDiagnostics.Severity level)
        {
            switch (level)
            {
                case BridgeDiagnostics.Severity.Error: return "#d05656";
                case BridgeDiagnostics.Severity.Warning: return "#d0a050";
                default: return "#9a9a9a";
            }
        }

        private static string SeverityGlyph(BridgeDiagnostics.Severity level)
        {
            switch (level)
            {
                case BridgeDiagnostics.Severity.Error: return "x";
                case BridgeDiagnostics.Severity.Warning: return "!";
                default: return "i";
            }
        }

        private static string FormatAgo(TimeSpan delta)
        {
            double s = delta.TotalSeconds;
            if (s < 0) s = 0;
            if (s < 60) return $"{(int)s}s ago";
            if (s < 3600) return $"{(int)(s / 60)}m ago";
            if (s < 86400) return $"{(int)(s / 3600)}h ago";
            return $"{(int)(s / 86400)}d ago";
        }

        private void DrawSetupHelp()
        {
            _showSetup = EditorGUILayout.Foldout(_showSetup, "Setup Instructions", true);
            if (!_showSetup) return;

            EditorGUILayout.HelpBox(
                "The MCP server is launched by your AI client, not Unity.\n\n" +
                "Add this to your client's MCP config:\n\n" +
                "{\n" +
                "  \"mcpServers\": {\n" +
                "    \"gladekit-unity\": {\n" +
                "      \"command\": \"uvx\",\n" +
                "      \"args\": [\"gladekit-mcp\"]\n" +
                "    }\n" +
                "  }\n" +
                "}\n\n" +
                "Requires uv: https://docs.astral.sh/uv\n\n" +
                "Config locations:\n" +
                "  Unity AI Gateway: Edit > Project Settings > AI > MCP Servers\n" +
                "  Cursor: Settings > MCP > Add server\n" +
                "  Claude Desktop: claude_desktop_config.json\n" +
                "  Windsurf: ~/.codeium/windsurf/mcp_config.json\n" +
                "  VS Code: .vscode/mcp.json\n" +
                "  Claude Code: .mcp.json (auto-detected)",
                MessageType.Info);

            EditorGUILayout.Space(4);
            using (new EditorGUILayout.HorizontalScope())
            {
                if (GUILayout.Button("Copy MCP Config"))
                {
                    string config =
                        "{\n" +
                        "  \"mcpServers\": {\n" +
                        "    \"gladekit-unity\": {\n" +
                        "      \"command\": \"uvx\",\n" +
                        "      \"args\": [\"gladekit-mcp\"]\n" +
                        "    }\n" +
                        "  }\n" +
                        "}";
                    EditorGUIUtility.systemCopyBuffer = config;
                    Debug.Log("[GladeKit MCP] Config copied to clipboard.");
                }

                if (GUILayout.Button("Copy Unity AI Gateway Config"))
                {
                    string config =
                        "{\n" +
                        "  \"enabled\": true,\n" +
                        "  \"path\": \"\",\n" +
                        "  \"mcpServers\": {\n" +
                        "    \"gladekit-unity\": {\n" +
                        "      \"type\": \"stdio\",\n" +
                        "      \"command\": \"uvx\",\n" +
                        "      \"args\": [\"gladekit-mcp\"]\n" +
                        "    }\n" +
                        "  }\n" +
                        "}";
                    EditorGUIUtility.systemCopyBuffer = config;
                    Debug.Log("[GladeKit MCP] Unity AI Gateway config copied to clipboard. Paste into Edit > Project Settings > AI > MCP Servers config file.");
                }
            }
        }

        private void DrawStatusDot(bool active)
        {
            var rect = GUILayoutUtility.GetRect(12, 12, GUILayout.Width(12));
            rect.y += 2;
            EditorGUI.DrawRect(new Rect(rect.x + 2, rect.y + 2, 8, 8),
                active ? new Color(0.2f, 0.8f, 0.2f) : new Color(0.5f, 0.5f, 0.5f));
        }
    }
}
