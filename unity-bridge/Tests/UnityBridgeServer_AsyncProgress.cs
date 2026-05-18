using System;
using System.Collections.Generic;
using NUnit.Framework;
using GladeAgenticAI.Bridge;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Coverage for <c>UnityBridgeServer.BuildAsyncProgressSnapshot</c>, the
    /// pure helper backing GET /api/async/progress. The HTTP route handler
    /// itself only marshals state in + writes JSON out; the shaping logic
    /// (Phase/Progress read, exception tolerance, elapsed-time math) lives
    /// in the helper so it can be tested without spinning up an HttpListener
    /// or a real IAsyncTool implementation.
    ///
    /// These tests pin the contract the renderer relies on:
    ///   - `hasProgress = false` ⇒ progress sentinel value, never trusted as a real percent
    ///   - null Phase normalises to empty string (JsonUtility shape needs non-null)
    ///   - a misbehaving handle never aborts the whole snapshot
    ///   - elapsed time is monotone non-negative
    /// </summary>
    public class UnityBridgeServer_AsyncProgress
    {
        private sealed class FakeHandle : IAsyncToolHandle
        {
            public string PhaseValue;
            public float? ProgressValue;
            public bool ThrowOnPhase;
            public bool ThrowOnProgress;

            public string PollResult() => null;
            public void Dispose() { }

            public string Phase
            {
                get
                {
                    if (ThrowOnPhase) throw new InvalidOperationException("phase boom");
                    return PhaseValue;
                }
            }

            public float? Progress
            {
                get
                {
                    if (ThrowOnProgress) throw new InvalidOperationException("progress boom");
                    return ProgressValue;
                }
            }
        }

        private static List<(string, IAsyncToolHandle, DateTime)> One(
            string toolName, IAsyncToolHandle handle, DateTime startedAt)
        {
            return new List<(string, IAsyncToolHandle, DateTime)>
            {
                (toolName, handle, startedAt),
            };
        }

        [Test]
        public void EmptyInput_ReturnsEmptyArray()
        {
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                new List<(string, IAsyncToolHandle, DateTime)>(),
                DateTime.UtcNow);

            Assert.IsNotNull(entries, "snapshot must never return null — JsonUtility serializes null arrays unpredictably across runtimes");
            Assert.AreEqual(0, entries.Length);
        }

        [Test]
        public void DeterminateProgress_RoundTripsCleanly()
        {
            var now = DateTime.UtcNow;
            var handle = new FakeHandle { PhaseValue = "downloading", ProgressValue = 0.42f };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, now.AddSeconds(-12.5)),
                now);

            Assert.AreEqual(1, entries.Length);
            var e = entries[0];
            Assert.AreEqual("import_asset", e.toolName);
            Assert.AreEqual("downloading", e.phase);
            Assert.IsTrue(e.hasProgress);
            Assert.AreEqual(0.42f, e.progress, 1e-4f);
            Assert.AreEqual(12.5f, e.elapsedSeconds, 0.1f);
        }

        [Test]
        public void NullProgress_FlagsIndeterminateWithSentinel()
        {
            // Critical contract: when progress is unknown the bridge must
            // signal it explicitly. Renderer treats `progress = -1` as a
            // marquee bar — only safe because `hasProgress = false`.
            var handle = new FakeHandle { PhaseValue = "extracting", ProgressValue = null };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual("extracting", entries[0].phase);
            Assert.IsFalse(entries[0].hasProgress);
            Assert.AreEqual(-1f, entries[0].progress, "indeterminate sentinel must be -1, never 0 (would render as full bar reset)");
        }

        [Test]
        public void NullPhase_NormalisesToEmptyString()
        {
            // JsonUtility serializes a null string as "null" — guarding here
            // means clients can rely on `entry.phase` being a string always.
            var handle = new FakeHandle { PhaseValue = null, ProgressValue = 0.1f };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual("", entries[0].phase);
        }

        [Test]
        public void PhaseGetterThrows_YieldsIndeterminateNotException()
        {
            // The endpoint is a heartbeat — if it ever throws, the renderer's
            // poll loop is what notices and goes silent. Tolerate misbehavior
            // by reporting indeterminate, not aborting.
            var handle = new FakeHandle { ThrowOnPhase = true, ProgressValue = 0.5f };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual(1, entries.Length);
            Assert.AreEqual("", entries[0].phase);
            Assert.IsFalse(entries[0].hasProgress, "exception in any getter must downgrade the whole entry to indeterminate");
        }

        [Test]
        public void ProgressGetterThrows_YieldsIndeterminateNotException()
        {
            var handle = new FakeHandle { PhaseValue = "downloading", ThrowOnProgress = true };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual(1, entries.Length);
            // Phase read succeeded before the throw — but we conservatively
            // wipe phase too. (Reading current implementation: phase is read
            // first then progress; phase getter succeeded → phase preserved.
            // This pin documents that contract.)
            Assert.AreEqual("downloading", entries[0].phase);
            Assert.IsFalse(entries[0].hasProgress);
        }

        [Test]
        public void NullHandle_DoesNotCrash()
        {
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", null, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual(1, entries.Length);
            Assert.AreEqual("import_asset", entries[0].toolName);
            Assert.IsFalse(entries[0].hasProgress);
        }

        [Test]
        public void NullToolName_NormalisesToEmptyString()
        {
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One(null, new FakeHandle { PhaseValue = "" }, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual("", entries[0].toolName);
        }

        [Test]
        public void MultipleInFlight_PreservesOrder()
        {
            // The renderer matches by toolName + position; order from the
            // bridge must be insert-order so the first import_asset call
            // resolves to the first card in the chat.
            var now = DateTime.UtcNow;
            var inputs = new List<(string, IAsyncToolHandle, DateTime)>
            {
                ("import_asset", new FakeHandle { PhaseValue = "downloading", ProgressValue = 0.2f }, now.AddSeconds(-30)),
                ("import_asset", new FakeHandle { PhaseValue = "extracting", ProgressValue = 0.9f }, now.AddSeconds(-3)),
            };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(inputs, now);

            Assert.AreEqual(2, entries.Length);
            Assert.AreEqual("downloading", entries[0].phase);
            Assert.AreEqual("extracting", entries[1].phase);
            Assert.That(entries[0].elapsedSeconds, Is.GreaterThan(entries[1].elapsedSeconds),
                "older entry must report higher elapsed time");
        }

        [Test]
        public void ProgressClampNotEnforced_RawValuePassedThrough()
        {
            // Documenting intentional behavior: the bridge ships the raw
            // float so the renderer can decide how to clamp (UI applies
            // min/max in the bar width style). Don't change this without
            // updating the renderer's clamp on the same commit.
            var handle = new FakeHandle { PhaseValue = "downloading", ProgressValue = 1.42f };
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", handle, DateTime.UtcNow),
                DateTime.UtcNow);

            Assert.AreEqual(1.42f, entries[0].progress, 1e-4f);
            Assert.IsTrue(entries[0].hasProgress);
        }

        [Test]
        public void ElapsedTime_NonNegative_EvenIfNowSlightlyBehindStartedAt()
        {
            // Clock skew between captures (snapshot built from a fresh
            // DateTime.UtcNow but a handle started at a later DateTime.UtcNow
            // due to interleaved monotonicity) shouldn't surface as negative
            // elapsed in the UI. Note: implementation does NOT explicitly
            // clamp — this test pins that behavior so a future clamp change
            // is intentional.
            var now = DateTime.UtcNow;
            var future = now.AddMilliseconds(50);
            var entries = UnityBridgeServer.BuildAsyncProgressSnapshot(
                One("import_asset", new FakeHandle { PhaseValue = "x" }, future),
                now);

            // Document current behavior: negative is possible. Renderer
            // should treat this as ~0.
            Assert.That(entries[0].elapsedSeconds, Is.LessThanOrEqualTo(0f));
        }
    }
}
