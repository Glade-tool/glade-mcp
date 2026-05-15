using System.Collections.Generic;
using NUnit.Framework;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Regression coverage for the invocation site of
    /// <c>AssetPipelineGuard.DescribeUrlHostRejection</c> on Meshy PBR
    /// texture URLs. Without the per-URL host check in
    /// <c>EnumerateAllowedMeshyTextureUrls</c>, a Meshy CDN host rotation
    /// (or a forged <c>_resolvedTextureUrls</c> from a client that bypasses
    /// its own asset_pipeline preprocessor) would silently drop every
    /// texture with only a <c>Debug.LogWarning</c> — the import would
    /// "succeed" while the model lands untextured.
    ///
    /// The guard's own correctness is covered in
    /// <c>AssetPipelineGuard_UrlAllowlist</c>; this suite covers the
    /// *invocation site* — that the texture-queue builder actually calls
    /// the guard, skips rejections, and preserves allowed URLs in
    /// material-index order.
    /// </summary>
    public class ImportAssetTool_TextureUrlAllowlist
    {
        // ── Happy path ──────────────────────────────────────────────────────────

        [Test]
        public void AllowsMeshyHostedTextures_OnMeshyCandidate()
        {
            // Apex meshy.ai is in the exact-match list; assets.meshy.ai matches
            // the ".meshy.ai" suffix rule. Both must come through.
            string texJson = "[{\"base_color\":\"https://assets.meshy.ai/abc/baseColor.png\","
                + "\"metallic\":\"https://meshy.ai/cdn/metal.png\","
                + "\"normal\":\"https://assets.meshy.ai/abc/normal.png\","
                + "\"roughness\":\"https://assets.meshy.ai/abc/rough.png\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(4, urls.Count);
            // Insertion order must follow the spec table — base_color, metallic,
            // normal, roughness — so multi-mat alignment downstream is stable.
            CollectionAssert.AreEqual(
                new[] { "base_color", "metallic", "normal", "roughness" },
                ExtractKeys(urls));
            // matIndex must be 0 for a single-material entry.
            foreach (var u in urls) Assert.AreEqual(0, u.MatIndex);
        }

        // ── The attack the third layer exists to stop ───────────────────────────

        [Test]
        public void RejectsForgedHost_KeepsAllowedHosts()
        {
            // Mixed bag: one forged URL alongside legitimate ones. The forged
            // URL must drop out; the others must come through unchanged. This
            // is the *exact* failure mode the regression test guards against
            // — a forged _resolvedTextureUrls smuggled through to the bridge.
            string texJson = "[{\"base_color\":\"https://evil.example.com/payload.png\","
                + "\"normal\":\"https://assets.meshy.ai/abc/normal.png\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(1, urls.Count, "Forged host must be filtered.");
            Assert.AreEqual("normal", urls[0].UrlKey);
            StringAssert.Contains("meshy.ai", urls[0].Url);
        }

        [Test]
        public void RejectsAllUrls_WhenEntirePbrSetIsForged()
        {
            // The worst-case host-rotation failure: every URL belongs to a
            // host we don't trust. The function must return empty, not raise.
            // The downstream importer will then proceed without textures — the
            // model lands untextured but the import doesn't crash. (Per-bug
            // observability is via the Debug.LogWarning for each skip; this
            // test asserts the data-path behavior.)
            string texJson = "[{\"base_color\":\"https://evil.example.com/a.png\","
                + "\"metallic\":\"https://kenney.nl.evil.com/b.png\","
                + "\"normal\":\"http://meshy.ai/c.png\"}]";  // http downgrade

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(0, urls.Count);
        }

        [Test]
        public void RejectsTexturesFromForgedSubdomain()
        {
            // ".meshy.ai" suffix match is anchored on the leading dot —
            // "meshy.ai.evil.com" must not be accepted as a meshy host.
            string texJson = "[{\"base_color\":\"https://meshy.ai.evil.com/payload.png\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(0, urls.Count);
        }

        // ── Provider gating ─────────────────────────────────────────────────────

        [Test]
        public void NonMeshyProvider_ReturnsEmpty()
        {
            // The helper is Meshy-specific by design. Future generative providers
            // plug in here. Until then, anything else must return empty.
            string texJson = "[{\"base_color\":\"https://assets.meshy.ai/a.png\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "kenney/tiny-town", "kenney", texJson);

            Assert.AreEqual(0, urls.Count);
        }

        [Test]
        public void EmptyProvider_ReturnsEmpty()
        {
            string texJson = "[{\"base_color\":\"https://assets.meshy.ai/a.png\"}]";
            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "", texJson);
            Assert.AreEqual(0, urls.Count);
        }

        // ── Multi-material support ──────────────────────────────────────────────

        [Test]
        public void PreservesMatIndex_AcrossMultipleEntries()
        {
            // Two PBR sets — one base_color each. The matIndex on the returned
            // url must match the entry's position so downstream filename
            // generation produces meshy_baseColor.png vs meshy_baseColor_1.png.
            string texJson = "["
                + "{\"base_color\":\"https://assets.meshy.ai/a.png\"},"
                + "{\"base_color\":\"https://assets.meshy.ai/b.png\"}"
                + "]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(2, urls.Count);
            Assert.AreEqual(0, urls[0].MatIndex);
            Assert.AreEqual(1, urls[1].MatIndex);
            StringAssert.Contains("/a.png", urls[0].Url);
            StringAssert.Contains("/b.png", urls[1].Url);
        }

        // ── Defensive parsing ───────────────────────────────────────────────────

        [Test]
        public void MalformedJson_ReturnsEmpty()
        {
            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", "not valid json {[");
            Assert.AreEqual(0, urls.Count);
        }

        [Test]
        public void NullJson_ReturnsEmpty()
        {
            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", null);
            Assert.AreEqual(0, urls.Count);
        }

        [Test]
        public void EmptyJsonArray_ReturnsEmpty()
        {
            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", "[]");
            Assert.AreEqual(0, urls.Count);
        }

        [Test]
        public void EntryWithEmptyUrls_SkipsEmptiesKeepsRest()
        {
            // Meshy occasionally returns "" for a map it didn't generate.
            // Empty strings must be skipped without being mistaken for forged
            // hosts (that would log a misleading rejection).
            string texJson = "[{\"base_color\":\"https://assets.meshy.ai/a.png\","
                + "\"metallic\":\"\","
                + "\"normal\":\"https://assets.meshy.ai/n.png\","
                + "\"roughness\":\"\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);

            Assert.AreEqual(2, urls.Count);
            CollectionAssert.AreEqual(new[] { "base_color", "normal" }, ExtractKeys(urls));
        }

        [Test]
        public void EntryMissingPbrKeys_ReturnsEmpty()
        {
            // The PBR keys themselves are optional individually — but an entry
            // with NONE of them present yields zero URLs (don't invent ones).
            string texJson = "[{\"unrelated_field\":\"foo\"}]";
            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "meshy/refined-task-1", "meshy", texJson);
            Assert.AreEqual(0, urls.Count);
        }

        // ── Bad candidate id falls through to guard's rejection ─────────────────

        [Test]
        public void MissingProviderSlash_RejectsAllUrls()
        {
            // candidateId without a "<provider>/" prefix can't resolve to an
            // allowlist; guard returns rejection on every URL, helper drops
            // them all. This matches the "fail closed" stance documented in
            // AssetPipelineGuard.
            string texJson = "[{\"base_color\":\"https://assets.meshy.ai/a.png\"}]";

            var urls = ImportAssetTool.EnumerateAllowedMeshyTextureUrls(
                "no-slash-here", "meshy", texJson);

            Assert.AreEqual(0, urls.Count);
        }

        // ── helpers ─────────────────────────────────────────────────────────────

        private static List<string> ExtractKeys(List<ImportAssetTool.MeshyTextureUrl> urls)
        {
            var keys = new List<string>(urls.Count);
            foreach (var u in urls) keys.Add(u.UrlKey);
            return keys;
        }
    }
}
