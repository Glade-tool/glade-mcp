using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using UnityEditor;
using UnityEngine;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Per-domain mutation log for the current Unity Editor session.
    ///
    /// Records every successful tool dispatch so the AI (or the user, via the
    /// status window or any client UI) can ask "what just changed?" and get a
    /// grouped, human-readable answer. Complements ErrorTracker which only
    /// captures failures.
    ///
    /// Scope: in-memory only. Reset on Editor domain reload — intentional:
    /// "session" means the Unity process session, not a human workday.
    /// </summary>
    [InitializeOnLoad]
    public static class SessionTracker
    {
        private const int MaxTimelineEntries = 500;

        public class MutationRecord
        {
            public string Tool;
            public string Action;    // create | modify | destroy | other
            public string Category;  // gameObjects | scripts | materials | components | assets | scenes | animation | physics | ui | lighting | audio | misc
            public string Target;    // gameObjectPath / scriptPath / materialPath / etc.
            public string Summary;   // one-line human-readable
            public long TimestampMs; // unix epoch
            public bool Success;
        }

        private static readonly object _lock = new object();
        private static readonly List<MutationRecord> _timeline = new List<MutationRecord>();
        private static readonly DateTime _sessionStart = DateTime.UtcNow;
        private static int _totalToolCalls;
        private static int _successCount;
        private static int _errorCount;

        // Read-only tool names — skip from the mutation log. Source of truth
        // is Python-side READ_ONLY_TOOLS, duplicated here to keep the bridge
        // self-contained (no HTTP dependency for classification).
        private static readonly HashSet<string> ReadOnlyTools = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "think", "request_user_input",
            "get_scene_hierarchy", "get_gameobject_info", "get_gameobject_components",
            "get_component_inspector_properties", "get_selection", "list_children",
            "find_game_objects", "find_scripts", "search_scripts", "search_project_scripts",
            "get_script_content", "list_assets", "check_asset_exists", "get_prefab_info",
            "list_materials", "list_ui_hierarchy", "get_ui_element_info",
            "get_animation_clip_curves", "get_animation_clip_info", "get_animation_events",
            "get_animator_controller_info", "get_animator_layer_info", "get_animator_parameter_info",
            "get_animator_state_info", "get_animator_transition_info", "get_blend_tree_info",
            "get_ik_target_info", "get_ik_weight", "get_sprite_animation_info",
            "get_unity_console_logs", "get_render_settings", "get_rigidbody_properties",
            "get_collider_properties", "get_character_controller_properties",
            "get_collision_matrix", "get_input_system_info", "get_texture_import_settings",
            "get_model_import_settings", "get_audio_import_settings", "get_sprite_import_settings",
            "raycast", "raycast_all", "linecast", "overlap_sphere", "overlap_box",
            "boxcast", "spherecast", "start_profiler", "stop_profiler", "get_frame_timing",
            "get_memory_stats", "get_gc_allocations", "get_profiler_counters",
            "enable_frame_debugger", "get_frame_debugger_events", "get_session_summary",
        };

        static SessionTracker()
        {
            // Reset on domain reload is implicit (static fields re-init). Nothing to wire.
        }

        /// <summary>
        /// Record a tool dispatch. Call AFTER the tool executes; pass the raw
        /// result JSON so we can mine success/error and useful target paths.
        /// </summary>
        public static void Record(string toolName, string argsJson, string resultJson)
        {
            if (string.IsNullOrEmpty(toolName)) return;

            lock (_lock)
            {
                _totalToolCalls++;
            }

            if (ReadOnlyTools.Contains(toolName)) return;

            bool success = LooksLikeSuccess(resultJson);
            var record = new MutationRecord
            {
                Tool = toolName,
                Action = ClassifyAction(toolName),
                Category = ClassifyCategory(toolName),
                Target = ExtractTarget(resultJson, argsJson),
                Summary = ExtractSummary(toolName, resultJson),
                TimestampMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds,
                Success = success,
            };

            lock (_lock)
            {
                if (success) _successCount++;
                else _errorCount++;

                _timeline.Add(record);
                if (_timeline.Count > MaxTimelineEntries)
                {
                    _timeline.RemoveRange(0, _timeline.Count - MaxTimelineEntries);
                }
            }
        }

        /// <summary>
        /// Build a grouped summary of mutations recorded this session.
        /// </summary>
        public static Dictionary<string, object> BuildSummary(int maxTimelineReturn = 50)
        {
            List<MutationRecord> snapshot;
            int totalCalls, successes, errors;
            lock (_lock)
            {
                snapshot = new List<MutationRecord>(_timeline);
                totalCalls = _totalToolCalls;
                successes = _successCount;
                errors = _errorCount;
            }

            var byCategory = new Dictionary<string, Dictionary<string, object>>();
            foreach (var r in snapshot)
            {
                if (!r.Success) continue;
                if (!byCategory.TryGetValue(r.Category, out var bucket))
                {
                    bucket = new Dictionary<string, object>
                    {
                        ["created"] = 0,
                        ["modified"] = 0,
                        ["destroyed"] = 0,
                        ["targets"] = new List<string>(),
                    };
                    byCategory[r.Category] = bucket;
                }
                string key;
                if (r.Action == "create") key = "created";
                else if (r.Action == "destroy") key = "destroyed";
                else key = "modified";
                bucket[key] = (int)bucket[key] + 1;
                if (!string.IsNullOrEmpty(r.Target))
                {
                    var targets = (List<string>)bucket["targets"];
                    if (!targets.Contains(r.Target) && targets.Count < 25)
                    {
                        targets.Add(r.Target);
                    }
                }
            }

            // Most-recent-first, capped — keep the full list in memory but only return a window.
            // ToolUtils.SerializeDictToJson handles List<Dictionary<string,object>> natively,
            // so we build the timeline as that concrete type rather than List<object>.
            var recentFirst = snapshot.AsEnumerable().Reverse().Take(maxTimelineReturn).ToList();
            var timeline = new List<Dictionary<string, object>>(recentFirst.Count);
            foreach (var r in recentFirst)
            {
                timeline.Add(new Dictionary<string, object>
                {
                    ["tMs"] = (int)(r.TimestampMs & int.MaxValue),
                    ["tIso"] = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddMilliseconds(r.TimestampMs).ToString("o"),
                    ["tool"] = r.Tool,
                    ["action"] = r.Action,
                    ["category"] = r.Category,
                    ["target"] = r.Target ?? "",
                    ["summary"] = r.Summary ?? "",
                    ["success"] = r.Success,
                });
            }

            // SerializeDictToJson handles Dictionary<string, Dictionary<string, object>>
            // only when the outer value is typed as Dictionary<string, object>. Copy
            // into the looser shape so categories serialize as nested JSON objects.
            var byCategoryOut = new Dictionary<string, object>();
            foreach (var kvp in byCategory)
            {
                byCategoryOut[kvp.Key] = kvp.Value;
            }

            // int, not long — SerializeDictToJson's type switch does not recognize long.
            int elapsedSeconds = (int)(DateTime.UtcNow - _sessionStart).TotalSeconds;

            return new Dictionary<string, object>
            {
                ["sessionStartedAt"] = _sessionStart.ToString("o"),
                ["elapsedSeconds"] = elapsedSeconds,
                ["toolCalls"] = totalCalls,
                ["mutations"] = snapshot.Count,
                ["successCount"] = successes,
                ["errorCount"] = errors,
                ["byCategory"] = byCategoryOut,
                ["timeline"] = timeline,
                ["timelineTruncated"] = snapshot.Count > maxTimelineReturn,
            };
        }

        /// <summary>
        /// Was this script path created by a successful create_script call
        /// earlier in the current Unity session? Used by ModifyScriptTool
        /// as a session-aware safety check that gates modify_script against
        /// pre-existing project scripts — protects user code against AI
        /// clients that misread "scaffold a new system" prompts as
        /// "extend an existing one" prompts.
        ///
        /// Path comparison is case-insensitive and tolerates the "Assets/"
        /// prefix being present or absent on either side (callers may use
        /// either convention).
        ///
        /// Returns false for the empty/null path. Returns false if the
        /// session timeline has been Reset() since the create_script call.
        /// </summary>
        public static bool WasScriptCreatedThisSession(string scriptPath)
        {
            if (string.IsNullOrEmpty(scriptPath)) return false;
            string normalized = NormalizeScriptPath(scriptPath);
            lock (_lock)
            {
                for (int i = _timeline.Count - 1; i >= 0; i--)
                {
                    var record = _timeline[i];
                    if (!record.Success) continue;
                    if (!string.Equals(record.Tool, "create_script", StringComparison.OrdinalIgnoreCase)) continue;
                    string target = NormalizeScriptPath(record.Target ?? string.Empty);
                    if (string.Equals(target, normalized, StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
                return false;
            }
        }

        private static string NormalizeScriptPath(string path)
        {
            if (string.IsNullOrEmpty(path)) return string.Empty;
            string trimmed = path.Replace('\\', '/');
            return trimmed.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase)
                ? trimmed
                : "Assets/" + trimmed;
        }

        /// <summary>
        /// Reset the session log. Called only via menu item or test setup.
        /// </summary>
        public static void Reset()
        {
            lock (_lock)
            {
                _timeline.Clear();
                _totalToolCalls = 0;
                _successCount = 0;
                _errorCount = 0;
            }
        }

        public static int TotalToolCalls { get { lock (_lock) return _totalToolCalls; } }
        public static int MutationCount { get { lock (_lock) return _timeline.Count; } }

        // ── Classification ───────────────────────────────────────────────────

        private static readonly string[] CreatePrefixes = { "create_", "add_", "instantiate_", "duplicate_", "import_", "bake_" };
        private static readonly string[] DestroyPrefixes = { "destroy_", "delete_", "remove_", "clear_" };

        private static string ClassifyAction(string tool)
        {
            foreach (var p in CreatePrefixes)
                if (tool.StartsWith(p, StringComparison.OrdinalIgnoreCase)) return "create";
            foreach (var p in DestroyPrefixes)
                if (tool.StartsWith(p, StringComparison.OrdinalIgnoreCase)) return "destroy";
            return "modify";
        }

        private static string ClassifyCategory(string tool)
        {
            string t = tool.ToLowerInvariant();
            if (t.Contains("script") || t.Contains("compile")) return "scripts";
            if (t.Contains("material") || t.Contains("shader")) return "materials";
            if (t.Contains("prefab")) return "prefabs";
            if (t.Contains("animator") || t.Contains("animation") || t.Contains("blend_tree") || t.Contains("ik_")) return "animation";
            if (t.Contains("rigidbody") || t.Contains("collider") || t.Contains("physics") || t.Contains("character_controller")) return "physics";
            if (t.Contains("canvas") || t.Contains("ui_element") || t.Contains("event_system") || t.Contains("ui_properties")) return "ui";
            if (t.Contains("camera")) return "camera";
            if (t.Contains("light") || t.Contains("render_settings")) return "lighting";
            if (t.Contains("audio") || t.Contains("clip")) return "audio";
            if (t.Contains("terrain") || t.Contains("navmesh")) return "terrain-nav";
            if (t.Contains("scene") || t.Contains("build_scenes")) return "scenes";
            if (t.Contains("asset") || t.Contains("folder") || t.Contains("refresh")) return "assets";
            if (t.Contains("component")) return "components";
            if (t.Contains("object") || t.Contains("transform") || t.Contains("primitive") || t.Contains("layer") || t.Contains("tag") || t.Contains("parent") || t.Contains("selection") || t.Contains("align") || t.Contains("snap") || t.Contains("group")) return "gameObjects";
            return "misc";
        }

        // ── Lightweight JSON field probes (no full parser) ───────────────────
        //
        // Keeps the session tracker zero-dep. We only ever read a handful of
        // well-known fields that tools consistently emit via CreateSuccessResponse.
        //
        private static readonly string[] TargetFields = {
            "gameObjectPath", "scriptPath", "materialPath", "prefabPath",
            "controllerPath", "clipPath", "scenePath", "assetPath",
            "folderPath", "lightPath", "animatorPath",
        };

        private static string ExtractTarget(string resultJson, string argsJson)
        {
            if (!string.IsNullOrEmpty(resultJson))
            {
                foreach (var key in TargetFields)
                {
                    string val = ProbeJsonField(resultJson, key);
                    if (!string.IsNullOrEmpty(val)) return val;
                }
            }
            if (!string.IsNullOrEmpty(argsJson))
            {
                foreach (var key in TargetFields)
                {
                    string val = ProbeJsonField(argsJson, key);
                    if (!string.IsNullOrEmpty(val)) return val;
                }
            }
            return "";
        }

        private static string ExtractSummary(string tool, string resultJson)
        {
            string msg = ProbeJsonField(resultJson, "message");
            if (string.IsNullOrEmpty(msg))
            {
                msg = ProbeJsonField(resultJson, "error");
                if (!string.IsNullOrEmpty(msg)) msg = "Error: " + msg;
            }
            if (string.IsNullOrEmpty(msg)) msg = tool.Replace('_', ' ');
            if (msg.Length > 160) msg = msg.Substring(0, 160) + "...";
            return msg;
        }

        private static bool LooksLikeSuccess(string resultJson)
        {
            if (string.IsNullOrEmpty(resultJson)) return false;
            // Signals in order of specificity.
            if (resultJson.IndexOf("\"success\":true", StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (resultJson.IndexOf("\"success\":false", StringComparison.OrdinalIgnoreCase) >= 0) return false;
            // Fallback: absence of an "error" field counts as success (tools that
            // skip the standard envelope still lean positive if they returned).
            return resultJson.IndexOf("\"error\":", StringComparison.OrdinalIgnoreCase) < 0;
        }

        /// <summary>
        /// Dumb single-field probe. Handles "key":"value" and "key":value for
        /// simple scalar types. Not a JSON parser — covers the 95% of cases
        /// where the result envelope emits flat fields.
        /// </summary>
        private static string ProbeJsonField(string json, string key)
        {
            if (string.IsNullOrEmpty(json) || string.IsNullOrEmpty(key)) return null;
            string needle = "\"" + key + "\"";
            int idx = json.IndexOf(needle, StringComparison.OrdinalIgnoreCase);
            if (idx < 0) return null;
            int colon = json.IndexOf(':', idx + needle.Length);
            if (colon < 0) return null;
            int i = colon + 1;
            while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
            if (i >= json.Length) return null;
            if (json[i] == '"')
            {
                var sb = new StringBuilder();
                i++;
                while (i < json.Length)
                {
                    char c = json[i];
                    if (c == '\\' && i + 1 < json.Length)
                    {
                        char n = json[i + 1];
                        sb.Append(n == 'n' ? '\n' : n == 't' ? '\t' : n);
                        i += 2;
                        continue;
                    }
                    if (c == '"') break;
                    sb.Append(c);
                    i++;
                }
                return sb.ToString();
            }
            // Non-string scalar — bail; targets are always strings in practice.
            return null;
        }

        [MenuItem("Window/GladeKit/Clear Session Summary")]
        private static void ClearSessionSummary()
        {
            if (EditorUtility.DisplayDialog("Clear Session Summary",
                "Reset the session mutation log? This clears the in-memory record of what tools changed this session.",
                "Clear", "Cancel"))
            {
                Reset();
                Debug.Log("[SessionTracker] Session log cleared");
            }
        }
    }
}
