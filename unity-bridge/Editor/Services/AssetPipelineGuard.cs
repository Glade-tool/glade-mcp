using System;
using System.Collections.Generic;
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

        // Provider → allowed download hostnames (matched case-insensitively).
        // When a new provider is added to the cloud / MCP orchestrator, add its
        // host(s) here too — the bridge refuses to download from any host not
        // in this map even when _resolvedUrl arrives pre-filled. This is the
        // defense against a client that bypasses cloud / MCP preprocessing and
        // sends a forged URL directly to localhost:8765.
        private static readonly Dictionary<string, HashSet<string>> _allowedHostsByProvider =
            new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase)
            {
                {
                    "kenney",
                    new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "kenney.nl", "www.kenney.nl" }
                },
            };

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

        /// <summary>
        /// True iff <paramref name="resolvedUrl"/> is an https URL whose host is
        /// in the allowlist for the provider implied by <paramref name="candidateId"/>
        /// (the prefix before the first '/'). The cloud and MCP preprocessors
        /// resolve URLs from a trusted catalog; this is a third-layer check so
        /// that even a client bypassing both preprocessors can't smuggle in an
        /// arbitrary download URL.
        /// </summary>
        public static bool IsResolvedUrlHostAllowed(string candidateId, string resolvedUrl)
        {
            if (string.IsNullOrEmpty(candidateId) || string.IsNullOrEmpty(resolvedUrl))
                return false;

            int slash = candidateId.IndexOf('/');
            if (slash <= 0) return false;
            string provider = candidateId.Substring(0, slash);

            if (!_allowedHostsByProvider.TryGetValue(provider, out var allowedHosts))
                return false;

            if (!Uri.TryCreate(resolvedUrl, UriKind.Absolute, out var uri))
                return false;
            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                return false;

            return allowedHosts.Contains(uri.Host);
        }

        /// <summary>
        /// The configured allowlist of hostnames for <paramref name="provider"/>,
        /// or an empty enumerable if the provider is unknown. Exposed for the
        /// /api/health endpoint and diagnostics — never used to make a security
        /// decision (use <see cref="IsResolvedUrlHostAllowed"/> for that).
        /// </summary>
        public static IEnumerable<string> AllowedHostsForProvider(string provider)
        {
            if (string.IsNullOrEmpty(provider)) return Array.Empty<string>();
            return _allowedHostsByProvider.TryGetValue(provider, out var hosts)
                ? (IEnumerable<string>)hosts
                : Array.Empty<string>();
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
