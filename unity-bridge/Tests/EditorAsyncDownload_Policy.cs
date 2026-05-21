using System.Collections.Generic;
using NUnit.Framework;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Pure-NUnit coverage for the abort policy in
    /// <c>EditorAsyncDownload</c>. The Unity-bound dependencies
    /// (<c>UnityWebRequest</c>, the wall-clock, the on-disk byte counter)
    /// sit behind <c>IDownloadOperation</c> / <c>IDownloadClock</c> /
    /// <c>IDownloadSizer</c> so the state-machine math — deadline strictly
    /// after <c>TickCount</c>, size strictly greater than the cap,
    /// abort-then-stick-to-aborted — is testable without spinning up an
    /// Editor or hitting the network.
    ///
    /// The sibling suite <c>ImportAssetTool_AsyncHandle</c> covers the
    /// validation short-circuits at the <c>BeginExecute</c> layer; this
    /// suite picks up where that one stops, against the helper class the
    /// state machine actually drives during a real download.
    /// </summary>
    public class EditorAsyncDownload_Policy
    {
        private const int TimeoutSeconds = 30;
        private const long MaxBytes = 100_000_000; // 100 MB

        // ── Happy path ──────────────────────────────────────────────────────────

        [Test]
        public void IsDone_TrueOnceOperationCompletes_NoErrorReported()
        {
            var op = new FakeOperation();
            var clock = new FakeClock(start: 1_000);
            var sizer = new FakeSizer();
            using var dl = new EditorAsyncDownload(op, clock, sizer, "dest.zip", TimeoutSeconds, MaxBytes);

            Assert.IsFalse(dl.IsDone, "Fresh operation should not be done.");

            op.IsDone = true;
            sizer.Set("dest.zip", 12_345);

            Assert.IsTrue(dl.IsDone);
            Assert.IsNull(dl.Error, "Success completion must not surface an error.");
            Assert.AreEqual(12_345, dl.FinalSize, "FinalSize should reflect the on-disk byte count at completion.");
        }

        [Test]
        public void Error_PropagatesUnderlyingHttpFailureMessage()
        {
            var op = new FakeOperation { IsDone = true, ResultError = "Cannot resolve host (HTTP 0)" };
            var dl = NewDownload(op, new FakeClock(start: 0), new FakeSizer());

            Assert.IsTrue(dl.IsDone);
            Assert.AreEqual("Cannot resolve host (HTTP 0)", dl.Error);
        }

        [Test]
        public void Error_PrefersDeadlineMessageOverUnderlyingOperationError()
        {
            // Once our own guard fires, callers expect the timeout reason
            // rather than whatever the now-aborted UnityWebRequest reports.
            var op = new FakeOperation { ResultError = "Request aborted (HTTP 0)" };
            var clock = new FakeClock(start: 1_000);
            var sizer = new FakeSizer();
            var dl = NewDownload(op, clock, sizer);

            clock.Advance((TimeoutSeconds * 1000) + 1);

            Assert.IsTrue(dl.IsDone);
            StringAssert.Contains("exceeded timeout", dl.Error);
        }

        // ── Deadline ────────────────────────────────────────────────────────────

        [Test]
        public void Deadline_FiresWhenClockAdvancesPastTimeout_BeforeOperationDone()
        {
            var op = new FakeOperation();
            var clock = new FakeClock(start: 5_000);
            var sizer = new FakeSizer();
            var dl = NewDownload(op, clock, sizer);

            // Just before the deadline — still in flight.
            clock.Advance((TimeoutSeconds * 1000) - 1);
            Assert.IsFalse(dl.IsDone, "Operation should remain in flight one tick before the deadline.");

            // One past the deadline — the guard fires.
            clock.Advance(2);
            Assert.IsTrue(dl.IsDone);
            StringAssert.Contains("exceeded timeout", dl.Error);
            Assert.AreEqual(1, op.AbortCallCount, "Deadline trip must abort the underlying request exactly once.");
        }

        [Test]
        public void Deadline_DoesNotFireWhenOperationCompletesFirst()
        {
            var op = new FakeOperation();
            var clock = new FakeClock(start: 0);
            var sizer = new FakeSizer();
            var dl = NewDownload(op, clock, sizer);

            op.IsDone = true;

            Assert.IsTrue(dl.IsDone);
            Assert.IsNull(dl.Error);

            // Advance well past the deadline after success — must remain a success.
            clock.Advance((TimeoutSeconds * 1000) + 10_000);
            Assert.IsTrue(dl.IsDone);
            Assert.IsNull(dl.Error, "Late tick advance after success must not retroactively flip to timeout.");
            Assert.AreEqual(0, op.AbortCallCount);
        }

        // ── Size cap ────────────────────────────────────────────────────────────

        [Test]
        public void SizeCap_FiresWhenBytesOnDiskExceedMax_AfterPartialBytesArrive()
        {
            var op = new FakeOperation();
            var clock = new FakeClock(start: 0);
            var sizer = new FakeSizer();
            var dl = NewDownload(op, clock, sizer);

            // Mid-stream — well under cap.
            sizer.Set("dest.zip", MaxBytes / 2);
            Assert.IsFalse(dl.IsDone);

            // Cross the cap — guard fires.
            sizer.Set("dest.zip", MaxBytes + 1);
            Assert.IsTrue(dl.IsDone);
            StringAssert.Contains("exceeds cap", dl.Error);
            Assert.AreEqual(1, op.AbortCallCount, "Cap trip must abort the underlying request exactly once.");
        }

        [Test]
        public void SizeCap_BoundaryIsStrictlyGreater_ExactCapIsAllowed()
        {
            var op = new FakeOperation();
            var sizer = new FakeSizer();
            sizer.Set("dest.zip", MaxBytes); // exact cap — must NOT trip.
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            Assert.IsFalse(dl.IsDone, "Exactly at cap must remain in flight; cap is strict (>) not loose (>=).");
            Assert.IsNull(dl.Error);
            Assert.AreEqual(0, op.AbortCallCount);
        }

        [Test]
        public void SizeCap_DoesNotFireWhenSizerCannotMeasure()
        {
            // Filesystem race or missing file → sizer returns -1; must be
            // treated as "unknown so far," not as "exceeds cap."
            var op = new FakeOperation();
            var sizer = new FakeSizer();
            sizer.SetMissing("dest.zip");
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            Assert.IsFalse(dl.IsDone, "Missing-file size (-1) must not trigger the cap guard.");
            Assert.IsNull(dl.Error);
            Assert.AreEqual(0, op.AbortCallCount);
        }

        // ── Progress / Content-Length ───────────────────────────────────────────

        [Test]
        public void Progress_NullWhenContentLengthHeaderMissing()
        {
            var op = new FakeOperation();
            var sizer = new FakeSizer();
            sizer.Set("dest.zip", 50_000);
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            Assert.IsNull(dl.Progress, "Without a Content-Length header, percent progress is undefined.");
        }

        [Test]
        public void Progress_NullWhenContentLengthIsNonNumeric()
        {
            var op = new FakeOperation();
            op.SetHeader("Content-Length", "chunked");
            var sizer = new FakeSizer();
            sizer.Set("dest.zip", 50_000);
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            Assert.IsNull(dl.Progress);
            Assert.AreEqual(-1, dl.ContentLength);
        }

        [Test]
        public void Progress_ComputesFractionAndClamps_OncePartialBytesAreOnDisk()
        {
            var op = new FakeOperation();
            op.SetHeader("Content-Length", "200000");
            var sizer = new FakeSizer();
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            sizer.Set("dest.zip", 0);
            Assert.AreEqual(0f, dl.Progress);

            sizer.Set("dest.zip", 50_000);
            Assert.AreEqual(0.25f, dl.Progress);

            sizer.Set("dest.zip", 200_000);
            Assert.AreEqual(1f, dl.Progress);

            // Defensive: if the on-disk size briefly exceeds the announced
            // Content-Length (compressed-transfer edge cases on some CDNs),
            // Progress clamps to 1 rather than reporting >100%.
            sizer.Set("dest.zip", 250_000);
            Assert.AreEqual(1f, dl.Progress);
        }

        [Test]
        public void BytesDownloaded_TracksSizerLive()
        {
            var op = new FakeOperation();
            var sizer = new FakeSizer();
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            sizer.Set("dest.zip", 0);
            Assert.AreEqual(0, dl.BytesDownloaded);

            sizer.Set("dest.zip", 4096);
            Assert.AreEqual(4096, dl.BytesDownloaded);
        }

        // ── FinalSize ───────────────────────────────────────────────────────────

        [Test]
        public void FinalSize_IsNegativeOneWhileInFlight_ThenStickyAtCompletion()
        {
            var op = new FakeOperation();
            var sizer = new FakeSizer();
            var dl = NewDownload(op, new FakeClock(start: 0), sizer);

            sizer.Set("dest.zip", 1_000);
            Assert.AreEqual(-1, dl.FinalSize, "FinalSize should not commit until the operation is done.");

            op.IsDone = true;
            sizer.Set("dest.zip", 9_876);
            Assert.AreEqual(9_876, dl.FinalSize);

            // Later changes to on-disk size (post-import file mutations etc.)
            // must NOT mutate the snapshot taken at completion.
            sizer.Set("dest.zip", 1_234_567);
            Assert.AreEqual(9_876, dl.FinalSize, "FinalSize must be sticky after the first completion read.");
        }

        // ── Lifecycle ───────────────────────────────────────────────────────────

        [Test]
        public void Dispose_IsIdempotent_AndAbortIsNotInvokedOnDispose()
        {
            var op = new FakeOperation();
            var dl = NewDownload(op, new FakeClock(start: 0), new FakeSizer());

            dl.Dispose();
            dl.Dispose();

            Assert.AreEqual(1, op.DisposeCallCount, "Dispose must call through to the underlying op exactly once.");
            Assert.AreEqual(0, op.AbortCallCount, "Dispose should not be confused with Abort — the request may have finished successfully.");
        }

        [Test]
        public void Abort_FiresOnceEvenAcrossRepeatedPolls()
        {
            var op = new FakeOperation();
            var clock = new FakeClock(start: 0);
            var dl = NewDownload(op, clock, new FakeSizer());

            clock.Advance((TimeoutSeconds * 1000) + 1);
            Assert.IsTrue(dl.IsDone);
            Assert.IsTrue(dl.IsDone);
            Assert.IsTrue(dl.IsDone);

            Assert.AreEqual(1, op.AbortCallCount,
                "After the first abort the helper must stay in the 'already aborted' branch — no follow-up aborts on every poll.");
        }

        [Test]
        public void Abort_SwallowsExceptionsFromUnderlyingOperation()
        {
            // The real UnityWebRequest can throw on Abort() if it has already
            // been torn down — the wrapper must never let that propagate to
            // the polling loop and crash the import state machine.
            var op = new FakeOperation { ThrowOnAbort = true };
            var clock = new FakeClock(start: 0);
            var dl = NewDownload(op, clock, new FakeSizer());

            clock.Advance((TimeoutSeconds * 1000) + 1);
            Assert.DoesNotThrow(() => { var _ = dl.IsDone; });
            StringAssert.Contains("exceeded timeout", dl.Error);
        }

        // ── Helpers ─────────────────────────────────────────────────────────────

        private static EditorAsyncDownload NewDownload(FakeOperation op, FakeClock clock, FakeSizer sizer)
        {
            return new EditorAsyncDownload(op, clock, sizer, "dest.zip", TimeoutSeconds, MaxBytes);
        }

        private sealed class FakeOperation : IDownloadOperation
        {
            private readonly Dictionary<string, string> _headers = new Dictionary<string, string>();
            public bool IsDone { get; set; }
            public string ResultError { get; set; }
            public int AbortCallCount { get; private set; }
            public int DisposeCallCount { get; private set; }
            public bool ThrowOnAbort { get; set; }

            public void SetHeader(string name, string value) => _headers[name] = value;

            public string GetResponseHeader(string name) =>
                _headers.TryGetValue(name, out string v) ? v : null;

            public void Abort()
            {
                AbortCallCount++;
                if (ThrowOnAbort) throw new System.InvalidOperationException("simulated teardown race");
            }

            public void Dispose() => DisposeCallCount++;
        }

        private sealed class FakeClock : IDownloadClock
        {
            public FakeClock(int start) { TickCount = start; }
            public int TickCount { get; private set; }
            public void Advance(int ms) { TickCount += ms; }
        }

        private sealed class FakeSizer : IDownloadSizer
        {
            private readonly Dictionary<string, long> _sizes = new Dictionary<string, long>();
            private readonly HashSet<string> _missing = new HashSet<string>();

            public void Set(string path, long bytes)
            {
                _sizes[path] = bytes;
                _missing.Remove(path);
            }

            public void SetMissing(string path)
            {
                _sizes.Remove(path);
                _missing.Add(path);
            }

            public long GetSize(string path)
            {
                if (_missing.Contains(path)) return -1;
                return _sizes.TryGetValue(path, out long v) ? v : -1;
            }
        }
    }
}
