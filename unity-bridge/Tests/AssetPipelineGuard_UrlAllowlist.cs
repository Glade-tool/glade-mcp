using NUnit.Framework;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Bridge-side hardening: even when a client bypasses its own
    /// asset_pipeline preprocessor and sends import_asset directly to
    /// localhost:8765 with a forged _resolvedUrl, the bridge must refuse to
    /// download from a host that isn't in the per-provider allowlist.
    ///
    /// Client-side preprocessors strip+overwrite _resolvedUrl already (the
    /// MCP server's coverage lives in mcp-server/tests/). This suite covers
    /// the *third* layer: AssetPipelineGuard.IsResolvedUrlHostAllowed.
    public class AssetPipelineGuard_UrlAllowlist
    {
        // ── Happy path ──────────────────────────────────────────────────────────

        [Test]
        public void Allows_KenneyHttpsUrl_OnKenneyCandidate()
        {
            Assert.IsTrue(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "https://kenney.nl/media/pages/assets/tiny-town/abc-1234/kenney_tiny-town.zip"));
        }

        [Test]
        public void Allows_KenneyWwwHttpsUrl_OnKenneyCandidate()
        {
            Assert.IsTrue(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "https://www.kenney.nl/media/pages/assets/tiny-town/abc-1234/kenney_tiny-town.zip"));
        }

        [Test]
        public void Allows_KenneyHttpsUrl_CaseInsensitiveHost()
        {
            Assert.IsTrue(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "https://KENNEY.NL/media/pages/assets/x.zip"));
        }

        // ── The attack the third layer exists to stop ───────────────────────────

        [Test]
        public void Rejects_ForgedEvilHost_OnKenneyCandidate()
        {
            // Threat: a client bypasses its own asset_pipeline preprocessor
            // and sends import_asset directly to the bridge with an arbitrary
            // _resolvedUrl. Bridge must refuse.
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "https://evil.example.com/malware.zip"));
        }

        [Test]
        public void Rejects_KenneyLookalikeSubdomain()
        {
            // kenney.nl.evil.com is NOT kenney.nl — Uri.Host returns the full
            // host string and Contains() is exact-match (case-insensitive).
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "https://kenney.nl.evil.com/payload.zip"));
        }

        [Test]
        public void Rejects_HttpScheme_EvenOnAllowedHost()
        {
            // Downgrade attack guard: HTTP is rejected even when the host is
            // in the allowlist. Provider download URLs are HTTPS by policy.
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "http://kenney.nl/media/pages/assets/x.zip"));
        }

        [Test]
        public void Rejects_FileScheme_EvenOnAllowedHost()
        {
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "file:///etc/passwd"));
        }

        // ── Provider routing ────────────────────────────────────────────────────

        [Test]
        public void Rejects_UnknownProviderPrefix()
        {
            // Adding a new provider to the orchestrator without registering its
            // hosts here must fail closed — better to refuse the call than
            // accept blindly.
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "opengameart/nonexistent",
                "https://kenney.nl/some.zip"));
        }

        [Test]
        public void Rejects_MalformedCandidateId_NoProviderSlash()
        {
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "no-slash-here",
                "https://kenney.nl/some.zip"));
        }

        [Test]
        public void Rejects_CandidateIdStartingWithSlash()
        {
            // "/foo" has no provider name before the slash — fail closed.
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "/foo",
                "https://kenney.nl/some.zip"));
        }

        // ── Input validation ────────────────────────────────────────────────────

        [Test]
        public void Rejects_NullCandidateId()
        {
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                null,
                "https://kenney.nl/some.zip"));
        }

        [Test]
        public void Rejects_NullResolvedUrl()
        {
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                null));
        }

        [Test]
        public void Rejects_EmptyResolvedUrl()
        {
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                ""));
        }

        [Test]
        public void Rejects_NonAbsoluteResolvedUrl()
        {
            // "kenney.nl/x.zip" is relative — Uri.TryCreate with Absolute fails.
            Assert.IsFalse(AssetPipelineGuard.IsResolvedUrlHostAllowed(
                "kenney/tiny-town",
                "kenney.nl/x.zip"));
        }

        // ── Allowlist diagnostic surface ────────────────────────────────────────

        [Test]
        public void AllowedHostsForProvider_KnownProvider_ReturnsHosts()
        {
            var hosts = new System.Collections.Generic.HashSet<string>(
                AssetPipelineGuard.AllowedHostsForProvider("kenney"));
            Assert.IsTrue(hosts.Contains("kenney.nl"));
            Assert.IsTrue(hosts.Contains("www.kenney.nl"));
        }

        [Test]
        public void AllowedHostsForProvider_UnknownProvider_ReturnsEmpty()
        {
            var hosts = new System.Collections.Generic.List<string>(
                AssetPipelineGuard.AllowedHostsForProvider("opengameart"));
            Assert.AreEqual(0, hosts.Count);
        }

        [Test]
        public void AllowedHostsForProvider_NullOrEmpty_ReturnsEmpty()
        {
            var fromNull = new System.Collections.Generic.List<string>(
                AssetPipelineGuard.AllowedHostsForProvider(null));
            var fromEmpty = new System.Collections.Generic.List<string>(
                AssetPipelineGuard.AllowedHostsForProvider(""));
            Assert.AreEqual(0, fromNull.Count);
            Assert.AreEqual(0, fromEmpty.Count);
        }
    }
}
