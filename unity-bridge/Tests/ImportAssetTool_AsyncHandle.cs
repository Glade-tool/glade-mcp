using System.Collections.Generic;
using NUnit.Framework;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Bridge-side coverage for the async-tool dispatch path on
    /// <see cref="ImportAssetTool"/>. These tests exercise the validation
    /// short-circuits in <c>BeginExecute</c> — every failure mode returns a
    /// pre-completed handle whose first <c>PollResult</c> yields the error
    /// envelope without any network work. The actual download state machine
    /// is exercised by live integration testing under a real Unity Editor;
    /// pure-NUnit tests can't safely poll <see cref="UnityWebRequest"/>.
    /// </summary>
    public class ImportAssetTool_AsyncHandle
    {
        private bool _previousEnabled;
        private ImportAssetTool _tool;

        [SetUp]
        public void EnableAssetPipeline()
        {
            // Pipeline toggle is persisted via EditorPrefs; snapshot + restore
            // so this suite never alters a developer's saved preference.
            _previousEnabled = AssetPipelineGuard.IsEnabled;
            AssetPipelineGuard.SetEnabled(true);
            _tool = new ImportAssetTool();
        }

        [TearDown]
        public void RestoreAssetPipelineToggle()
        {
            AssetPipelineGuard.SetEnabled(_previousEnabled);
        }

        // ── Validation short-circuits ───────────────────────────────────────

        [Test]
        public void NullArgs_ReturnsArgsRequired_OnFirstPoll()
        {
            var handle = _tool.BeginExecute(null);
            string result = handle.PollResult();
            Assert.IsNotNull(result, "Failed handle must yield envelope on first poll, not return null.");
            StringAssert.Contains("args required", result);
        }

        [Test]
        public void MissingCandidateId_ReturnsValidationError()
        {
            var args = new Dictionary<string, object>
            {
                { "licenseAcknowledged", true },
                { "assetType", "sprite_2d" },
                { "_resolvedUrl", "https://kenney.nl/x.zip" },
            };
            var handle = _tool.BeginExecute(args);
            StringAssert.Contains("candidateId is required", handle.PollResult());
        }

        [Test]
        public void LicenseNotAcknowledged_ReturnsLicenseGateError()
        {
            var args = new Dictionary<string, object>
            {
                { "candidateId", "kenney/tiny-town" },
                { "licenseAcknowledged", false },
                { "assetType", "sprite_2d" },
                { "_resolvedUrl", "https://kenney.nl/x.zip" },
            };
            var handle = _tool.BeginExecute(args);
            StringAssert.Contains("licenseAcknowledged must be true", handle.PollResult());
        }

        [Test]
        public void MissingAssetType_ReturnsValidationError()
        {
            var args = new Dictionary<string, object>
            {
                { "candidateId", "kenney/tiny-town" },
                { "licenseAcknowledged", true },
                { "_resolvedUrl", "https://kenney.nl/x.zip" },
            };
            var handle = _tool.BeginExecute(args);
            StringAssert.Contains("assetType is required", handle.PollResult());
        }

        [Test]
        public void TargetPathOutsideAssets_ReturnsValidationError()
        {
            var args = new Dictionary<string, object>
            {
                { "candidateId", "kenney/tiny-town" },
                { "licenseAcknowledged", true },
                { "assetType", "sprite_2d" },
                { "targetPath", "../Outside/Sprites/tiny-town/" },
                { "_resolvedUrl", "https://kenney.nl/x.zip" },
            };
            var handle = _tool.BeginExecute(args);
            StringAssert.Contains("targetPath must start with 'Assets/'", handle.PollResult());
        }

        [Test]
        public void MissingResolvedUrl_ReturnsPreprocessorMissingError()
        {
            var args = new Dictionary<string, object>
            {
                { "candidateId", "kenney/tiny-town" },
                { "licenseAcknowledged", true },
                { "assetType", "sprite_2d" },
            };
            var handle = _tool.BeginExecute(args);
            string result = handle.PollResult();
            StringAssert.Contains("Resolved download URL missing", result);
            StringAssert.Contains("asset_pipeline preprocessor did not run", result);
        }

        [Test]
        public void ForgedHost_OnKenneyCandidate_ReturnsHostRejection()
        {
            // The third-layer defense — even if a client's own asset_pipeline
            // preprocessor was bypassed, the bridge refuses to download from
            // an unallowed host. Covered functionally by AssetPipelineGuard's
            // own suite; this asserts BeginExecute integrates with the guard
            // BEFORE any network work starts.
            var args = new Dictionary<string, object>
            {
                { "candidateId", "kenney/tiny-town" },
                { "licenseAcknowledged", true },
                { "assetType", "sprite_2d" },
                { "_resolvedUrl", "https://evil.example.com/malware.zip" },
            };
            var handle = _tool.BeginExecute(args);
            string result = handle.PollResult();
            StringAssert.Contains("Bridge refused the download", result);
            StringAssert.Contains("evil.example.com", result);
        }

        [Test]
        public void PipelineDisabled_ShortCircuitsBeforeValidation()
        {
            AssetPipelineGuard.SetEnabled(false);
            try
            {
                var handle = _tool.BeginExecute(new Dictionary<string, object>());
                string result = handle.PollResult();
                // RejectIfDisabled returns an envelope mentioning the toggle —
                // the exact text comes from AssetPipelineGuard but should
                // mention the disabled state somewhere.
                StringAssert.Contains("disabled", result.ToLowerInvariant());
            }
            finally
            {
                AssetPipelineGuard.SetEnabled(true);
            }
        }

        // ── Handle contract ──────────────────────────────────────────────────

        [Test]
        public void FailedHandle_RepeatedPolls_ReturnSameResult()
        {
            // Sticky final result — once PollResult yields a non-null
            // envelope, subsequent polls must return the SAME envelope (the
            // bridge dispatcher relies on this for idempotent re-polling).
            var handle = _tool.BeginExecute(null);
            string first = handle.PollResult();
            string second = handle.PollResult();
            string third = handle.PollResult();
            Assert.AreEqual(first, second);
            Assert.AreEqual(second, third);
        }

        [Test]
        public void FailedHandle_Phase_IsDone()
        {
            var handle = _tool.BeginExecute(null);
            // First-poll surfaces the error and the handle is now in its
            // terminal state.
            handle.PollResult();
            Assert.AreEqual("done", handle.Phase);
        }

        [Test]
        public void FailedHandle_Progress_IsNull()
        {
            var handle = _tool.BeginExecute(null);
            handle.PollResult();
            Assert.IsNull(handle.Progress);
        }

        [Test]
        public void FailedHandle_Dispose_SafeToCallMultipleTimes()
        {
            var handle = _tool.BeginExecute(null);
            handle.PollResult();
            Assert.DoesNotThrow(() => handle.Dispose());
            Assert.DoesNotThrow(() => handle.Dispose());
        }

        // ── ToolExecutor integration ─────────────────────────────────────────

        [Test]
        public void TryBeginAsync_ImportAsset_ReturnsHandle()
        {
            // Sanity: ImportAssetTool is wired up as an IAsyncTool through the
            // registry, so TryBeginAsync finds it and produces a handle. Uses
            // invalid args so the handle short-circuits to a Failed state on
            // first poll — no network, no Unity asset work.
            var args = "{}";
            var begin = ToolExecutor.TryBeginAsync("import_asset", args);
            Assert.IsNotNull(begin, "ImportAssetTool must dispatch via the async path.");
            Assert.IsNotNull(begin.Handle, "Handle should be populated for valid async-tool routing.");
            Assert.IsNull(begin.ImmediateResult, "No demo-path block; ImmediateResult should be null.");
            StringAssert.Contains("args required", begin.Handle.PollResult());
            begin.Handle.Dispose();
        }

        [Test]
        public void TryBeginAsync_SyncTool_ReturnsNull()
        {
            // A purely-sync tool must NOT route via the async path. Picking
            // "get_scene_hierarchy" as a canonical read-only sync tool —
            // it's been ITool-only since pre-asset-pipeline.
            var begin = ToolExecutor.TryBeginAsync("get_scene_hierarchy", "{}");
            Assert.IsNull(begin, "Sync tools must fall through to ExecuteTool.");
        }
    }
}
