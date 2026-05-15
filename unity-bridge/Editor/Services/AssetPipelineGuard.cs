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
    /// Defense in depth — even if a client sent a request despite the schemas
    /// being filtered out at the preprocessor layer, every asset-pipeline tool
    /// checks this guard and returns a clear error when disabled.
    ///
    /// EditorPrefs key:  GladeAI.AssetPipelineEnabled (default true)
    /// HTTP toggle:      POST /api/settings { "assetPipelineEnabled": bool }
    /// </summary>
    public static class AssetPipelineGuard
    {
        private const string PrefKey = "GladeAI.AssetPipelineEnabled";

        // Provider → allowed download hosts (exact matches + suffix matches).
        // Exact matches are the safest tier — e.g. "kenney.nl" matches only
        // that one host. Suffix matches like ".meshy.ai" trust the entire
        // subdomain tree of a vendor we already trust at the apex; use them
        // when the vendor rotates CDN hostnames between regions or releases.
        // Defense in depth: even if the client-side preprocessor is bypassed
        // or a forged _resolvedUrl slips past the upper layers, the bridge
        // still refuses to download from anything not listed below.
        private struct AllowedHosts
        {
            public HashSet<string> Exact;
            public List<string> Suffixes; // each begins with '.', e.g. ".meshy.ai"
        }

        private static readonly Dictionary<string, AllowedHosts> _allowedHostsByProvider =
            new Dictionary<string, AllowedHosts>(StringComparer.OrdinalIgnoreCase)
            {
                {
                    "kenney",
                    new AllowedHosts
                    {
                        Exact = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "kenney.nl", "www.kenney.nl" },
                        Suffixes = new List<string>(),
                    }
                },
                {
                    // Meshy generative 3D. The refined GLB URL is generated
                    // server-side and may come from any of Meshy's CDN /
                    // signed-URL hosts — which rotate between releases. We
                    // trust the entire meshy.ai subdomain tree at the apex
                    // (we already trust Meshy to generate our user's assets
                    // with their API key); plus, signed download URLs are
                    // commonly served from S3 / R2 endpoints owned by Meshy.
                    "meshy",
                    new AllowedHosts
                    {
                        Exact = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
                        {
                            "meshy.ai",
                        },
                        Suffixes = new List<string>
                        {
                            ".meshy.ai",
                        },
                    }
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
        /// (the prefix before the first '/'). The asset_pipeline preprocessor on
        /// the calling client resolves URLs from a trusted catalog; this is a
        /// third-layer check so that even a client bypassing its own
        /// preprocessor can't smuggle in an arbitrary download URL.
        /// </summary>
        public static bool IsResolvedUrlHostAllowed(string candidateId, string resolvedUrl)
        {
            return DescribeUrlHostRejection(candidateId, resolvedUrl) == null;
        }

        /// <summary>
        /// Returns null if the URL is allowed; otherwise returns a human-readable
        /// description of why it was rejected (including the actual host so the
        /// upstream error message can tell the user what to fix). This is the
        /// authoritative check — <see cref="IsResolvedUrlHostAllowed"/> is a
        /// thin convenience wrapper.
        /// </summary>
        public static string DescribeUrlHostRejection(string candidateId, string resolvedUrl)
        {
            if (string.IsNullOrEmpty(candidateId))
                return "candidateId is empty";
            if (string.IsNullOrEmpty(resolvedUrl))
                return "resolvedUrl is empty";

            int slash = candidateId.IndexOf('/');
            if (slash <= 0)
                return $"candidateId \"{candidateId}\" is missing a provider prefix";
            string provider = candidateId.Substring(0, slash);

            if (!_allowedHostsByProvider.TryGetValue(provider, out var allowed))
                return $"provider \"{provider}\" is not in the allowlist (unknown provider)";

            if (!Uri.TryCreate(resolvedUrl, UriKind.Absolute, out var uri))
                return $"resolvedUrl is not a valid absolute URL ({Truncate(resolvedUrl, 80)})";
            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                return $"resolvedUrl is not HTTPS (got scheme \"{uri.Scheme}\")";

            string host = uri.Host;
            if (allowed.Exact != null && allowed.Exact.Contains(host))
                return null;
            if (allowed.Suffixes != null)
            {
                foreach (var suffix in allowed.Suffixes)
                {
                    if (host.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                        return null;
                }
            }

            string allowedDesc = DescribeAllowed(allowed);
            return $"host \"{host}\" is not in the allowlist for provider \"{provider}\". Allowed: {allowedDesc}";
        }

        private static string DescribeAllowed(AllowedHosts allowed)
        {
            var parts = new List<string>();
            if (allowed.Exact != null)
            {
                foreach (var h in allowed.Exact) parts.Add(h);
            }
            if (allowed.Suffixes != null)
            {
                foreach (var s in allowed.Suffixes) parts.Add("*" + s);
            }
            return parts.Count == 0 ? "(none)" : string.Join(", ", parts);
        }

        private static string Truncate(string s, int n)
        {
            if (string.IsNullOrEmpty(s)) return s;
            return s.Length <= n ? s : s.Substring(0, n) + "…";
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
            if (!_allowedHostsByProvider.TryGetValue(provider, out var allowed))
                return Array.Empty<string>();
            var result = new List<string>();
            if (allowed.Exact != null) result.AddRange(allowed.Exact);
            if (allowed.Suffixes != null) foreach (var s in allowed.Suffixes) result.Add("*" + s);
            return result;
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
