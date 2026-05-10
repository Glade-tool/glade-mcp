using System;
using UnityEditor;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Toggle gate for the asset pipeline (find_asset, import_asset,
    /// list_imported_assets). Default ON for new users; teams/studios working in
    /// existing projects can turn it off so the agent never downloads external
    /// assets.
    ///
    /// Defense in depth — even if the cloud sent a request despite the schemas
    /// being filtered out, every asset-pipeline tool checks this guard and
    /// returns a clear error when disabled.
    ///
    /// EditorPrefs key:  GladeAI.AssetPipelineEnabled (default true)
    /// HTTP toggle:      POST /api/settings { "assetPipelineEnabled": bool }
    /// </summary>
    public static class AssetPipelineGuard
    {
        private const string PrefKey = "GladeAI.AssetPipelineEnabled";

        public static bool IsEnabled
        {
            get { return EditorPrefs.GetBool(PrefKey, true); }
        }

        public static void SetEnabled(bool enabled)
        {
            EditorPrefs.SetBool(PrefKey, enabled);
        }

        /// <summary>
        /// Returns an error JSON if the pipeline is disabled; otherwise null.
        /// Tools should call this at the top of Execute() and short-circuit
        /// when an error is returned.
        /// </summary>
        public static string RejectIfDisabled()
        {
            if (IsEnabled) return null;
            return ToolUtilsErrorString(
                "Asset pipeline is disabled. Enable 'Asset Pipeline' in GladeKit settings " +
                "(or POST { \"assetPipelineEnabled\": true } to /api/settings) to allow " +
                "downloads of external assets.");
        }

        private static string ToolUtilsErrorString(string message)
        {
            // Avoid a hard dependency on ToolUtils at module load time (this
            // class lives in Services, not Tools). Build the error envelope
            // directly — same shape as ToolUtils.CreateErrorResponse.
            string escaped = message
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\n", "\\n")
                .Replace("\r", "\\r");
            return "{\"success\":false,\"error\":\"" + escaped + "\"}";
        }
    }
}
