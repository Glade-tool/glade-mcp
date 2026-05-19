using System;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Sidecar (<c>.gladekit-asset.json</c>) JSON-correctness coverage.
    ///
    /// <para>
    /// The sidecar's previous hand-rolled <c>StringBuilder</c> builder
    /// silently corrupted on a candidate id containing a literal <c>"</c>;
    /// the v0.2 switch to <see cref="JsonUtility.ToJson"/> shifted that
    /// responsibility to Unity's serializer. These tests pin the contract
    /// so a future refactor (or a switch to a different serializer) can't
    /// regress escape handling without tripping a red light.
    /// </para>
    ///
    /// <para>
    /// We test via the filesystem-free internal helper
    /// <c>BuildSidecarJson</c> rather than <c>WriteSidecar</c> — sidecar
    /// JSON is a pure function of its inputs, so testing the bytes
    /// directly is cheaper and more deterministic than round-tripping a
    /// temp directory.
    /// </para>
    /// </summary>
    public class ImportAssetTool_SidecarJson
    {
        // ── Public mirror of the (private nested) sidecar schema ──────────
        // JsonUtility can deserialize into ANY type with matching public
        // fields — we don't have to lift the production type's accessibility
        // to verify the round-trip. Keeping the mirror in the test file
        // means schema drift between prod and test forces an explicit
        // test update, which is the desired failure mode.

        [Serializable]
        public class SidecarMirror
        {
            public int schema_version;
            public string candidate_id = "";
            public string provider = "";
            public string license = "";
            public string attribution_text = "";
            public string source_url = "";
            public string imported_at = "";
            public string asset_type = "";
            public string target_path = "";
            public List<string> imported_files = new List<string>();
            public List<string> texture_files = new List<string>();
            public List<string> material_files = new List<string>();
            public SidecarProviderMirror provider_metadata = new SidecarProviderMirror();
        }

        [Serializable]
        public class SidecarProviderMirror
        {
            public string refined_task_id = "";
            public string model_format = "";
        }

        private static SidecarMirror Parse(string json)
        {
            return JsonUtility.FromJson<SidecarMirror>(json);
        }

        private static string BuildKenneyJson(
            string candidateId = "kenney/platformer-pack-redux",
            string license = "CC0-1.0",
            string attribution = "",
            string sourceUrl = "https://kenney.nl/x.zip",
            string assetType = "sprite_2d",
            List<string> importedFiles = null)
        {
            return ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Sprites/test/",
                candidateId: candidateId,
                license: license,
                attribution: attribution,
                sourceUrl: sourceUrl,
                assetType: assetType,
                fileExtension: ".zip",
                importedFiles: importedFiles ?? new List<string> { "Assets/Sprites/test/asset.png" },
                importedAt: "2026-05-18T12:00:00Z");
        }

        // ── Happy path: shape + schema_version stable ─────────────────────

        [Test]
        public void HappyPath_ProducesValidJson_WithExpectedFields()
        {
            string json = BuildKenneyJson();
            SidecarMirror parsed = Parse(json);

            Assert.IsNotNull(parsed, "JsonUtility.FromJson returned null — output is malformed.");
            Assert.AreEqual(2, parsed.schema_version, "schema_version must stay at 2 until an explicit migration.");
            Assert.AreEqual("kenney/platformer-pack-redux", parsed.candidate_id);
            Assert.AreEqual("kenney", parsed.provider);
            Assert.AreEqual("CC0-1.0", parsed.license);
            Assert.AreEqual("sprite_2d", parsed.asset_type);
            Assert.AreEqual("2026-05-18T12:00:00Z", parsed.imported_at);
            CollectionAssert.AreEqual(new[] { "Assets/Sprites/test/asset.png" }, parsed.imported_files);
        }

        // ── String-escape correctness — the bug we shipped to fix ─────────

        [Test]
        public void CandidateIdContainingDoubleQuote_RoundTripsCleanly()
        {
            string nasty = "meshy/abc\"def";
            string json = BuildKenneyJson(candidateId: nasty);

            // The raw JSON MUST contain the escape sequence — if it doesn't,
            // re-parsing might succeed by accident on some parsers but the
            // file would be unparseable by strict ones.
            StringAssert.Contains("\\\"", json, "Quote in candidate_id must be backslash-escaped.");
            Assert.AreEqual(nasty, Parse(json).candidate_id);
        }

        [Test]
        public void CandidateIdContainingBackslash_RoundTripsCleanly()
        {
            // Windows-style path-ish characters inside an id can't be
            // sanitized out (an id is opaque to the bridge) — they must
            // serialize as \\ and survive a round trip.
            string nasty = "meshy/abc\\def";
            string json = BuildKenneyJson(candidateId: nasty);

            StringAssert.Contains("\\\\", json, "Backslash in candidate_id must be doubled.");
            Assert.AreEqual(nasty, Parse(json).candidate_id);
        }

        [Test]
        public void AttributionTextWithNewlinesAndTabs_PreservesControlEscapes()
        {
            string attribution = "Line 1\nLine 2\tindented\rwith \"quotes\".";
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Sprites/test/",
                candidateId: "kenney/x",
                license: "CC-BY-4.0",
                attribution: attribution,
                sourceUrl: "https://kenney.nl/x.zip",
                assetType: "sprite_2d",
                fileExtension: ".zip",
                importedFiles: new List<string>(),
                importedAt: "2026-05-18T12:00:00Z");

            // Control chars MUST be JSON-escape sequences, not raw bytes,
            // otherwise jq / any RFC-compliant parser will reject the file.
            StringAssert.Contains("\\n", json);
            StringAssert.Contains("\\t", json);
            StringAssert.Contains("\\r", json);
            // Round trip restores the original.
            Assert.AreEqual(attribution, Parse(json).attribution_text);
        }

        [Test]
        public void AttributionTextWithUnicode_PreservesCharactersIntact()
        {
            // Kenney attributions occasionally contain non-ASCII names; future
            // providers (Japanese SFX libraries, etc.) will too. JsonUtility
            // passes BMP characters through as UTF-8 — we just need to verify
            // they survive the round trip rather than getting mojibake-d.
            string attribution = "Made by 山田太郎 — © 2026 — café";
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Sprites/test/",
                candidateId: "kenney/x",
                license: "CC0-1.0",
                attribution: attribution,
                sourceUrl: "https://kenney.nl/x.zip",
                assetType: "sprite_2d",
                fileExtension: ".zip",
                importedFiles: new List<string>(),
                importedAt: "2026-05-18T12:00:00Z");

            Assert.AreEqual(attribution, Parse(json).attribution_text);
        }

        [Test]
        public void ImportedFilesWithSpecialChars_RoundTripIndividually()
        {
            // Asset paths CAN contain odd glyphs in real Unity projects —
            // localized folder names, em dashes, parens. Each list entry
            // must escape independently; a regression that re-introduced
            // hand-rolled concat would silently break list parsing.
            var paths = new List<string>
            {
                "Assets/Audio/SFX/\"explosion\".wav",
                "Assets/Imported/中国/笔记.png",
                "Assets/Imported/a\\b\\c.txt",
                "Assets/Imported/em—dash.mat",
            };
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Imported/x/",
                candidateId: "meshy/abc",
                license: "MESHY_USER_OWNED",
                attribution: "",
                sourceUrl: "",
                assetType: "model_3d",
                fileExtension: ".fbx",
                importedFiles: paths,
                importedAt: "2026-05-18T12:00:00Z");

            CollectionAssert.AreEqual(paths, Parse(json).imported_files);
        }

        // ── Schema partitioning: texture_files / material_files derived ──

        [Test]
        public void ImportedFiles_PartitionedIntoTextureAndMaterialBuckets()
        {
            var files = new List<string>
            {
                "Assets/Models/x/model.fbx",
                "Assets/Models/x/base_color.png",
                "Assets/Models/x/metallic.jpg",
                "Assets/Models/x/x.mat",
                "Assets/Models/x/normal.tga",
            };
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Models/x/",
                candidateId: "meshy/abc",
                license: "MESHY_USER_OWNED",
                attribution: "",
                sourceUrl: "",
                assetType: "model_3d",
                fileExtension: ".fbx",
                importedFiles: files,
                importedAt: "2026-05-18T12:00:00Z");

            SidecarMirror parsed = Parse(json);
            CollectionAssert.AreEquivalent(
                new[] {
                    "Assets/Models/x/base_color.png",
                    "Assets/Models/x/metallic.jpg",
                    "Assets/Models/x/normal.tga",
                },
                parsed.texture_files);
            CollectionAssert.AreEqual(new[] { "Assets/Models/x/x.mat" }, parsed.material_files);
            // Original list must remain unmodified (texture / material lists
            // are additive views, not partitions removing entries).
            CollectionAssert.AreEqual(files, parsed.imported_files);
        }

        // ── Provider metadata: Meshy-only fields ─────────────────────────

        [Test]
        public void MeshyCandidate_PopulatesProviderMetadata()
        {
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Models/x/",
                candidateId: "meshy/refined-12345",
                license: "MESHY_USER_OWNED",
                attribution: "",
                sourceUrl: "https://assets.meshy.ai/x/model.fbx",
                assetType: "model_3d",
                fileExtension: ".fbx",
                importedFiles: new List<string> { "Assets/Models/x/model.fbx" },
                importedAt: "2026-05-18T12:00:00Z");

            SidecarMirror parsed = Parse(json);
            Assert.AreEqual("refined-12345", parsed.provider_metadata.refined_task_id);
            Assert.AreEqual("fbx", parsed.provider_metadata.model_format);
        }

        [Test]
        public void KenneyCandidate_LeavesProviderMetadataEmpty()
        {
            string json = BuildKenneyJson();
            SidecarMirror parsed = Parse(json);
            Assert.AreEqual("", parsed.provider_metadata.refined_task_id);
            Assert.AreEqual("", parsed.provider_metadata.model_format);
        }

        // ── Null-tolerance ───────────────────────────────────────────────

        [Test]
        public void NullArguments_NormalizedToEmptyStrings()
        {
            // The handler upstream guards against nulls but the helper must
            // still be defensive — it's reachable from cross-tool refactors.
            string json = ImportAssetTool.BuildSidecarJson(
                targetPath: "Assets/Sprites/x/",
                candidateId: null,
                license: null,
                attribution: null,
                sourceUrl: null,
                assetType: null,
                fileExtension: null,
                importedFiles: null,
                importedAt: null);

            SidecarMirror parsed = Parse(json);
            Assert.AreEqual("", parsed.candidate_id);
            Assert.AreEqual("UNKNOWN", parsed.license, "Null license must default to UNKNOWN, not empty.");
            Assert.AreEqual("", parsed.attribution_text);
            Assert.AreEqual("", parsed.source_url);
            Assert.AreEqual("", parsed.imported_at);
            Assert.AreEqual("", parsed.asset_type);
            Assert.IsNotNull(parsed.imported_files);
            Assert.AreEqual(0, parsed.imported_files.Count);
        }
    }
}
