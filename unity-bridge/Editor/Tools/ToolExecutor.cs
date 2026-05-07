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
    }
}
