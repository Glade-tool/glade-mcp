using NUnit.Framework;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Coverage for <see cref="BridgeDiagnostics"/> — the in-memory ring
    /// buffer that backs the status window's "Bridge Diagnostics" panel.
    ///
    /// Pins three contracts the status window relies on:
    ///   - newest-first snapshot order, so the user reads the most recent
    ///     event at the top of the panel
    ///   - oldest-drop behavior when the cap is reached, so a noisy session
    ///     never grows the buffer unbounded
    ///   - empty/null message inputs are dropped silently rather than
    ///     poisoning the buffer with blank rows
    /// </summary>
    public class BridgeDiagnostics_RingBuffer
    {
        [SetUp]
        public void ResetBuffer()
        {
            // BridgeDiagnostics is process-static, so tests share state with
            // anything else that ran in the test session. Clear before each
            // test so assertions about Count and ordering are deterministic.
            BridgeDiagnostics.Clear();
        }

        [Test]
        public void Record_AppendsEntry_AndCountReflectsIt()
        {
            BridgeDiagnostics.Error("compile_scripts", "ReadTimeout");
            Assert.AreEqual(1, BridgeDiagnostics.Count);

            var snap = BridgeDiagnostics.SnapshotNewestFirst();
            Assert.AreEqual(1, snap.Count);
            Assert.AreEqual("compile_scripts", snap[0].Source);
            Assert.AreEqual("ReadTimeout", snap[0].Message);
            Assert.AreEqual(BridgeDiagnostics.Severity.Error, snap[0].Level);
        }

        [Test]
        public void Snapshot_ReturnsNewestFirst()
        {
            BridgeDiagnostics.Info("StartServer", "first");
            BridgeDiagnostics.Warn("compile_scripts", "second");
            BridgeDiagnostics.Error("HandleRequest", "third");

            var snap = BridgeDiagnostics.SnapshotNewestFirst();

            Assert.AreEqual(3, snap.Count);
            // Status window renders index 0 at the top — most recent first.
            Assert.AreEqual("third", snap[0].Message);
            Assert.AreEqual("second", snap[1].Message);
            Assert.AreEqual("first", snap[2].Message);
        }

        [Test]
        public void RingBuffer_DropsOldestPastCap()
        {
            // Fill past the cap by 5 — oldest 5 should fall off.
            for (int i = 0; i < BridgeDiagnostics.MaxEntries + 5; i++)
            {
                BridgeDiagnostics.Info("test", $"msg-{i}");
            }

            Assert.AreEqual(BridgeDiagnostics.MaxEntries, BridgeDiagnostics.Count,
                "ring buffer must not exceed its cap");

            var snap = BridgeDiagnostics.SnapshotNewestFirst();
            int lastIndex = BridgeDiagnostics.MaxEntries + 4;
            Assert.AreEqual($"msg-{lastIndex}", snap[0].Message,
                "newest message must survive the drop");
            // Oldest surviving message should be msg-5 (msg-0..4 dropped).
            Assert.AreEqual("msg-5", snap[snap.Count - 1].Message,
                "exactly the oldest 5 entries must be evicted");
        }

        [Test]
        public void EmptyOrNullMessage_IsDropped()
        {
            BridgeDiagnostics.Error("source", "");
            BridgeDiagnostics.Error("source", null);
            Assert.AreEqual(0, BridgeDiagnostics.Count,
                "blank/null messages would clutter the diagnostics panel with empty rows");
        }

        [Test]
        public void NullSource_NormalisesToBridge()
        {
            // Defensive: callers in the bridge use string literals everywhere,
            // but RuntimeLogStream-style callers might end up passing null
            // from a higher-level dispatcher. Don't crash and don't render a
            // bare "null" header.
            BridgeDiagnostics.Warn(null, "anonymous fault");
            var snap = BridgeDiagnostics.SnapshotNewestFirst();
            Assert.AreEqual(1, snap.Count);
            Assert.AreEqual("bridge", snap[0].Source);
        }

        [Test]
        public void SeverityCounts_TalliesEachLevelIndependently()
        {
            BridgeDiagnostics.Error("a", "e1");
            BridgeDiagnostics.Error("b", "e2");
            BridgeDiagnostics.Warn("c", "w1");
            BridgeDiagnostics.Info("d", "i1");
            BridgeDiagnostics.Info("e", "i2");
            BridgeDiagnostics.Info("f", "i3");

            var (errors, warnings, infos) = BridgeDiagnostics.SeverityCounts();
            Assert.AreEqual(2, errors);
            Assert.AreEqual(1, warnings);
            Assert.AreEqual(3, infos);
        }

        [Test]
        public void Clear_EmptiesBuffer()
        {
            BridgeDiagnostics.Error("a", "e1");
            BridgeDiagnostics.Warn("b", "w1");
            Assert.AreEqual(2, BridgeDiagnostics.Count);

            BridgeDiagnostics.Clear();
            Assert.AreEqual(0, BridgeDiagnostics.Count);
            Assert.AreEqual(0, BridgeDiagnostics.SnapshotNewestFirst().Count);
        }
    }
}
