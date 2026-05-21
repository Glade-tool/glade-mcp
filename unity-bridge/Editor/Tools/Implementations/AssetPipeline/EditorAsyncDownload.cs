using System;
using System.IO;
using UnityEngine;
using UnityEngine.Networking;

namespace GladeAgenticAI.Core.Tools.Implementations.AssetPipeline
{
    /// <summary>
    /// Non-blocking single-URL download helper.
    ///
    /// <para>
    /// Starts a <see cref="UnityWebRequest"/> streaming directly to disk via
    /// <see cref="DownloadHandlerFile"/>; the caller then polls
    /// <see cref="IsDone"/> each editor tick. No <c>Thread.Sleep</c>, no
    /// main-thread block — between polls the editor's update loop runs
    /// normally and the UI stays responsive. Replaces the legacy tight-loop
    /// pattern in <c>ImportAssetTool.DownloadToFile</c> that froze the
    /// Editor for the full duration of large Kenney / Meshy downloads.
    /// </para>
    ///
    /// <para>
    /// Two abort conditions are checked lazily inside <see cref="IsDone"/>:
    /// a wall-clock deadline (UnityWebRequest's own <c>timeout</c> doesn't
    /// always fire on stalled CDN responses, so we belt-and-suspenders it)
    /// and a hard byte cap (so a runaway 5 GB response is killed before it
    /// fills the disk). Both flip <see cref="IsDone"/> to <c>true</c> with
    /// <see cref="Error"/> populated, which is the shape the caller already
    /// expects from a failed download.
    /// </para>
    ///
    /// <para>
    /// The three Unity-bound seams (the in-flight web request, the
    /// monotonic clock, and the on-disk byte counter) are abstracted behind
    /// <see cref="IDownloadOperation"/> / <see cref="IDownloadClock"/> /
    /// <see cref="IDownloadSizer"/> so the abort policy can be unit-tested
    /// without touching the network or the filesystem.
    /// </para>
    /// </summary>
    internal sealed class EditorAsyncDownload : IDisposable
    {
        private readonly IDownloadOperation _op;
        private readonly IDownloadClock _clock;
        private readonly IDownloadSizer _sizer;
        private readonly long _deadlineTicks;
        private readonly long _maxBytes;
        private readonly string _destPath;
        private bool _aborted;
        private bool _disposed;
        private string _error;
        private long _finalSize = -1;

        public EditorAsyncDownload(string url, string destPath, int timeoutSeconds, long maxBytes)
            : this(
                new UnityWebRequestOperation(url, destPath, timeoutSeconds),
                RealTimeDownloadClock.Instance,
                FileSystemDownloadSizer.Instance,
                destPath,
                timeoutSeconds,
                maxBytes)
        {
        }

        internal EditorAsyncDownload(
            IDownloadOperation operation,
            IDownloadClock clock,
            IDownloadSizer sizer,
            string destPath,
            int timeoutSeconds,
            long maxBytes)
        {
            _op = operation;
            _clock = clock;
            _sizer = sizer;
            _destPath = destPath;
            _maxBytes = maxBytes;
            _deadlineTicks = clock.TickCount + (timeoutSeconds * 1000);
        }

        public bool IsDone
        {
            get
            {
                if (_aborted) return true;
                if (_op.IsDone) return true;

                if (_clock.TickCount > _deadlineTicks)
                {
                    _error = $"Download exceeded timeout";
                    AbortInternal();
                    return true;
                }

                long sofar = SafeFileSize();
                if (sofar > _maxBytes)
                {
                    _error = $"Download size {sofar}+ exceeds cap of {_maxBytes} bytes";
                    AbortInternal();
                    return true;
                }

                return false;
            }
        }

        public long BytesDownloaded => SafeFileSize();

        public long ContentLength
        {
            get
            {
                string header = _op.GetResponseHeader("Content-Length");
                if (long.TryParse(header, out long parsed)) return parsed;
                return -1;
            }
        }

        public float? Progress
        {
            get
            {
                long total = ContentLength;
                if (total <= 0) return null;
                long sofar = SafeFileSize();
                if (sofar < 0) return null;
                return Mathf.Clamp01((float)sofar / total);
            }
        }

        /// <summary>
        /// Non-null iff the download failed — either via the deadline /
        /// cap guards above, or via UnityWebRequest's own success check.
        /// Only meaningful after <see cref="IsDone"/> is true.
        /// </summary>
        public string Error
        {
            get
            {
                if (!string.IsNullOrEmpty(_error)) return _error;
                return _op.ResultError;
            }
        }

        public long FinalSize
        {
            get
            {
                if (_finalSize >= 0) return _finalSize;
                if (!_op.IsDone && !_aborted) return -1;
                _finalSize = SafeFileSize();
                return _finalSize;
            }
        }

        private long SafeFileSize() => _sizer.GetSize(_destPath);

        private void AbortInternal()
        {
            if (_aborted) return;
            _aborted = true;
            try { _op.Abort(); } catch { /* may already be torn down */ }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _op.Dispose(); } catch { /* ignore */ }
        }
    }

    /// <summary>
    /// Minimal surface area on top of an in-flight HTTP download — only the
    /// signals <see cref="EditorAsyncDownload"/> actually consumes.
    /// </summary>
    internal interface IDownloadOperation : IDisposable
    {
        bool IsDone { get; }

        /// <summary>
        /// Null while the request is in progress or succeeded; populated
        /// once the request finishes with a network/HTTP error.
        /// </summary>
        string ResultError { get; }

        string GetResponseHeader(string name);
        void Abort();
    }

    internal interface IDownloadClock
    {
        int TickCount { get; }
    }

    internal interface IDownloadSizer
    {
        long GetSize(string path);
    }

    internal sealed class RealTimeDownloadClock : IDownloadClock
    {
        public static readonly RealTimeDownloadClock Instance = new RealTimeDownloadClock();
        public int TickCount => Environment.TickCount;
    }

    internal sealed class FileSystemDownloadSizer : IDownloadSizer
    {
        public static readonly FileSystemDownloadSizer Instance = new FileSystemDownloadSizer();

        public long GetSize(string path)
        {
            try { return new FileInfo(path).Length; }
            catch { return -1; }
        }
    }

    internal sealed class UnityWebRequestOperation : IDownloadOperation
    {
        private readonly UnityWebRequest _request;

        public UnityWebRequestOperation(string url, string destPath, int timeoutSeconds)
        {
            _request = UnityWebRequest.Get(url);
            _request.downloadHandler = new DownloadHandlerFile(destPath) { removeFileOnAbort = true };
            _request.timeout = timeoutSeconds;
            _request.SendWebRequest();
        }

        public bool IsDone => _request.isDone;

        public string ResultError
        {
            get
            {
#if UNITY_2020_2_OR_NEWER
                if (_request.result != UnityWebRequest.Result.Success && _request.result != UnityWebRequest.Result.InProgress)
                    return $"{_request.error} (HTTP {_request.responseCode})";
#else
                if (_request.isHttpError || _request.isNetworkError)
                    return $"{_request.error} (HTTP {_request.responseCode})";
#endif
                return null;
            }
        }

        public string GetResponseHeader(string name) => _request.GetResponseHeader(name);

        public void Abort()
        {
            try { _request.Abort(); } catch { /* may already be torn down */ }
        }

        public void Dispose()
        {
            try { _request.Dispose(); } catch { /* ignore */ }
        }
    }
}
