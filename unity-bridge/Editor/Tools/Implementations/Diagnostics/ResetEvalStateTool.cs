using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Diagnostics
{
    /// <summary>
    /// Per-trial state reset for evaluation harnesses. Wipes the active
    /// scene back to a known baseline (Main Camera + Directional Light
    /// only), deletes a caller-specified glob of scripts under
    /// Assets/Scripts/, and clears the SessionTracker timeline.
    ///
    /// Motivation: evaluation harnesses that run the same prompt against
    /// a Unity project across multiple trials leak state between trials
    /// by default — scripts created by trial 1 are still on disk when
    /// trial 2 starts, so the agent finds them and reuses them instead
    /// of scaffolding fresh. Without per-trial reset, the eval ends up
    /// measuring "what the model does given existing artifacts" rather
    /// than "can the model do the work from scratch." This tool is the
    /// reusable primitive for keeping trials independent.
    ///
    /// Safety
    /// ------
    /// - Script deletion ONLY operates under Assets/Scripts/. Globs that
    ///   target other directories are rejected with a structured reason.
    ///   This prevents accidental destruction of project assets like
    ///   Materials/, Scenes/, Prefabs/, etc.
    /// - Globs use a simple filename pattern: * matches anything except
    ///   directory separators. Multiple patterns are comma-separated.
    ///   ** (recursive glob) is not supported.
    /// - Each resolved path is run through DemoAssetsGuard before
    ///   deletion, so any demo content the user opted to keep is safe.
    /// - Scene reset preserves a whitelist of root GameObject names:
    ///   Main Camera, Directional Light. Everything else at the scene
    ///   root level is destroyed.
    /// - All three sub-actions (script glob delete / scene reset /
    ///   session clear) are independently opt-in. Defaults are
    ///   conservative: clearScene=true (cheapest reset), clearSession=true
    ///   (just an in-memory flag), scriptsGlob="" (no script deletion).
    /// - Intended for eval/automation use, not interactive sessions.
    ///   AI clients that run this against a user's working scene without
    ///   the user's explicit instruction would destroy unsaved work.
    /// </summary>
    public class ResetEvalStateTool : ITool
    {
        public string Name => "reset_eval_state";

        private const string ScriptsRoot = "Assets/Scripts/";

        // Root GameObject names preserved by the scene reset. Anything else
        // at scene-root level is destroyed.
        private static readonly HashSet<string> PreservedRootNames = new HashSet<string>(StringComparer.Ordinal)
        {
            "Main Camera",
            "Directional Light",
        };

        public string Execute(Dictionary<string, object> args)
        {
            bool clearScene = ToolUtils.GetBoolArg(args, "clearScene", true);
            bool clearSession = ToolUtils.GetBoolArg(args, "clearSession", true);
            string scriptsGlob = args.ContainsKey("scriptsGlob") && args["scriptsGlob"] != null
                ? args["scriptsGlob"].ToString().Trim()
                : string.Empty;

            var destroyedGameObjects = new List<string>();
            var deletedScripts = new List<string>();
            var refusedScripts = new List<Dictionary<string, object>>();

            // ── Scene reset ──────────────────────────────────────────────
            // Preserve ONE GameObject per whitelisted name (first occurrence
            // wins). Without this, repeated trials that create new "Main
            // Camera" objects via create_camera would accumulate — name
            // matching alone is "keep ALL with this name" which defeats
            // the point of a clean baseline.
            if (clearScene)
            {
                var activeScene = SceneManager.GetActiveScene();
                var preservedSeen = new HashSet<string>(StringComparer.Ordinal);
                foreach (var root in activeScene.GetRootGameObjects())
                {
                    if (root == null) continue;
                    if (PreservedRootNames.Contains(root.name) && !preservedSeen.Contains(root.name))
                    {
                        preservedSeen.Add(root.name);
                        continue;
                    }
                    destroyedGameObjects.Add(root.name);
                    UnityEngine.Object.DestroyImmediate(root);
                }
                // Mark scene dirty so the test runner / user knows state changed,
                // but do NOT auto-save — leaving that to the caller is safer.
                EditorSceneManager.MarkSceneDirty(activeScene);
            }

            // ── Script glob delete ───────────────────────────────────────
            if (!string.IsNullOrEmpty(scriptsGlob))
            {
                var resolved = ResolveScriptsGlob(scriptsGlob, out var globErrors);
                foreach (var error in globErrors)
                {
                    refusedScripts.Add(new Dictionary<string, object>
                    {
                        ["pattern"] = error.Item1,
                        ["reason"] = error.Item2,
                    });
                }

                foreach (var path in resolved)
                {
                    if (!DemoAssetsGuard.AllowUseOfDemoAssetPath(path))
                    {
                        refusedScripts.Add(new Dictionary<string, object>
                        {
                            ["path"] = path,
                            ["reason"] = "demoAssetGuard",
                        });
                        continue;
                    }
                    if (AssetDatabase.DeleteAsset(path))
                    {
                        deletedScripts.Add(path);
                    }
                    else
                    {
                        refusedScripts.Add(new Dictionary<string, object>
                        {
                            ["path"] = path,
                            ["reason"] = "deleteAssetFailed",
                        });
                    }
                }

                if (deletedScripts.Count > 0)
                {
                    AssetDatabase.Refresh();
                }
            }

            // ── Session timeline reset ───────────────────────────────────
            int priorMutations = SessionTracker.MutationCount;
            if (clearSession)
            {
                SessionTracker.Reset();
            }

            var extras = new Dictionary<string, object>
            {
                ["sceneCleared"] = clearScene,
                ["destroyedRootGameObjects"] = destroyedGameObjects,
                ["destroyedCount"] = destroyedGameObjects.Count,
                ["scriptsDeleted"] = deletedScripts,
                ["scriptsDeletedCount"] = deletedScripts.Count,
                ["scriptsRefused"] = refusedScripts,
                ["sessionCleared"] = clearSession,
                ["priorSessionMutations"] = priorMutations,
            };

            string summary = $"Reset: {destroyedGameObjects.Count} root GameObject(s) destroyed, "
                + $"{deletedScripts.Count} script(s) deleted, session cleared={clearSession}";
            return ToolUtils.CreateSuccessResponse(summary, extras);
        }

        /// <summary>
        /// Expand a comma-separated glob string into concrete asset paths.
        /// Each pattern must start with "Assets/Scripts/" — patterns that
        /// target other directories are returned as errors, not resolved.
        /// Glob syntax is filename-only: "*" matches zero-or-more characters
        /// excluding path separators. Subdirectory globs (e.g. **) are not
        /// supported and treated as literal.
        /// </summary>
        private static List<string> ResolveScriptsGlob(
            string globString,
            out List<Tuple<string, string>> errors)
        {
            errors = new List<Tuple<string, string>>();
            var resolved = new List<string>();
            var patterns = globString.Split(',');
            foreach (var rawPattern in patterns)
            {
                var pattern = rawPattern.Trim().Replace('\\', '/');
                if (string.IsNullOrEmpty(pattern)) continue;

                if (!pattern.StartsWith(ScriptsRoot, StringComparison.Ordinal))
                {
                    errors.Add(Tuple.Create(pattern, $"outsideScriptsRoot (must start with {ScriptsRoot})"));
                    continue;
                }

                // Split into directory + filename pattern.
                int lastSlash = pattern.LastIndexOf('/');
                string dir = pattern.Substring(0, lastSlash);
                string filenamePattern = pattern.Substring(lastSlash + 1);

                if (filenamePattern.Contains("/"))
                {
                    errors.Add(Tuple.Create(pattern, "subdirectoryGlobNotSupported"));
                    continue;
                }

                if (!Directory.Exists(dir))
                {
                    // Empty result, not an error — the directory might simply
                    // be empty after a prior reset.
                    continue;
                }

                string[] matches;
                try
                {
                    matches = Directory.GetFiles(dir, filenamePattern, SearchOption.TopDirectoryOnly);
                }
                catch (Exception ex)
                {
                    errors.Add(Tuple.Create(pattern, "globResolveFailed: " + ex.Message));
                    continue;
                }

                foreach (var match in matches)
                {
                    // Skip .meta files — AssetDatabase.DeleteAsset handles
                    // those alongside the primary asset.
                    if (match.EndsWith(".meta", StringComparison.Ordinal)) continue;
                    // Normalize separators.
                    resolved.Add(match.Replace('\\', '/'));
                }
            }
            // Deduplicate without changing order.
            return resolved.Distinct().ToList();
        }
    }
}
