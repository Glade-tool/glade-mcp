using System;
using System.Collections.Generic;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Executes Unity tools via the ITool registry system.
    /// All tools are implemented as ITool classes and registered in ToolRegistry.
    /// This class handles tool routing, argument parsing, and security validation.
    /// </summary>
    public static class ToolExecutor
    {
        private static ToolRegistry _registry;

        private static void EnsureRegistry()
        {
            if (_registry == null)
                _registry = new ToolRegistry();
        }

        /// <summary>
        /// Allows external assemblies (e.g. GladeKit.Bridge.SRP) to register tools at load time.
        /// </summary>
        public static void RegisterExternal(ITool tool)
        {
            EnsureRegistry();
            _registry.Register(tool);
        }

        /// <summary>Returns an error JSON string if the path is under demo assets and demo assets are disabled; otherwise null.</summary>
        private static string RejectIfDemoPathDisallowed(string path)
        {
            if (string.IsNullOrEmpty(path)) return null;
            if (DemoAssetsGuard.AllowUseOfDemoAssetPath(path)) return null;
            return "{\"error\":\"Demo assets are disabled in Settings. Enable 'Reference demo assets' to use bundled demo content (Assets/DemoAssets or Packages/com.gladekit.agenticai/DemoAssets).\"}";
        }

        private static readonly string[] AssetPathArgKeys = new[]
        {
            "assetPath", "prefabPath", "scenePath", "materialPath", "controllerPath", "clipPath",
            "sourcePath", "destinationPath", "scriptPath", "texturePath", "skyboxMaterial", "profilePath",
            "avatarMaskPath", "maskPath", "meshPath", "dataPath", "terrainDataPath", "spritePath", "folderPath"
        };

        /// <summary>Checks all path-like arguments in args; returns error JSON if any is a disallowed demo path.</summary>
        private static string RejectIfAnyArgPathIsDemoDisallowed(Dictionary<string, object> args)
        {
            if (args == null) return null;
            foreach (string key in AssetPathArgKeys)
            {
                if (!args.TryGetValue(key, out var val) || val == null) continue;
                string path = val.ToString();
                if (string.IsNullOrWhiteSpace(path)) continue;
                // Accept Asset-relative inputs by prepending "Assets/", but preserve
                // "Packages/..." UPM AssetDatabase paths verbatim — DemoAssets can live
                // in a deployed UPM package (Packages/com.gladekit.agenticai/DemoAssets/).
                bool rooted = path.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase)
                              || path.StartsWith("Packages/", StringComparison.OrdinalIgnoreCase);
                if (!rooted)
                    path = "Assets/" + path.TrimStart('/');
                var err = RejectIfDemoPathDisallowed(path);
                if (err != null) return err;
            }
            return null;
        }

        public static string ExecuteTool(string toolName, string argumentsJson)
        {
            try
            {
                EnsureRegistry();
                var args = ToolUtils.ParseJsonToDict(argumentsJson);
                var demoErr = RejectIfAnyArgPathIsDemoDisallowed(args);
                if (demoErr != null) return demoErr;

                var tool = _registry.GetTool(toolName);
                if (tool != null)
                    return tool.Execute(args);

                return ToolUtils.CreateErrorResponse($"Error with tool: {toolName}. Tool was blocked from executing or null.");
            }
            catch (Exception e)
            {
                return ToolUtils.CreateErrorResponse($"Execution failed: {e.Message}");
            }
        }

        /// <summary>
        /// Try to begin an async tool invocation. Returns a populated
        /// <see cref="AsyncBeginResult"/> if the resolved tool implements
        /// <see cref="IAsyncTool"/>; returns null if the tool isn't async or
        /// doesn't exist (caller should fall through to <see cref="ExecuteTool"/>
        /// for the sync path).
        ///
        /// <para>
        /// Demo-path rejection and arg parsing happen here exactly as in
        /// <see cref="ExecuteTool"/> — when a demo path is blocked, the
        /// returned result has <c>Handle</c> = null and <c>ImmediateResult</c>
        /// populated with the same error envelope sync callers would see.
        /// This keeps the security gate in one place.
        /// </para>
        /// </summary>
        public static AsyncBeginResult TryBeginAsync(string toolName, string argumentsJson)
        {
            EnsureRegistry();
            var tool = _registry.GetTool(toolName);
            if (!(tool is IAsyncTool asyncTool)) return null;

            try
            {
                var args = ToolUtils.ParseJsonToDict(argumentsJson);
                var demoErr = RejectIfAnyArgPathIsDemoDisallowed(args);
                if (demoErr != null) return new AsyncBeginResult { ImmediateResult = demoErr };

                var handle = asyncTool.BeginExecute(args);
                return new AsyncBeginResult { Handle = handle };
            }
            catch (Exception e)
            {
                return new AsyncBeginResult
                {
                    ImmediateResult = ToolUtils.CreateErrorResponse($"Execution failed: {e.Message}")
                };
            }
        }

        public sealed class AsyncBeginResult
        {
            /// <summary>Non-null when the tool started async work; bridge should poll.</summary>
            public IAsyncToolHandle Handle;

            /// <summary>
            /// Non-null when validation rejected the call before async work began
            /// (demo-path block, arg parse failure). Bridge should send this as
            /// the response immediately, no polling needed.
            /// </summary>
            public string ImmediateResult;
        }
    }
}
