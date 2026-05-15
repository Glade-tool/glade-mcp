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
    /// </summary>
    internal sealed class EditorAsyncDownload : IDisposable
    {
        private readonly UnityWebRequest _request;
        private readonly UnityWebRequestAsyncOperation _op;
        private readonly long _deadlineTicks;
        private readonly long _maxBytes;
        private readonly string _destPath;
        private bool _aborted;
        private bool _disposed;
        private string _error;
        private long _finalSize = -1;

        public EditorAsyncDownload(string url, string destPath, int timeoutSeconds, long maxBytes)
        {
            _destPath = destPath;
            _maxBytes = maxBytes;
            _deadlineTicks = Environment.TickCount + (timeoutSeconds * 1000);

            _request = UnityWebRequest.Get(url);
            _request.downloadHandler = new DownloadHandlerFile(destPath) { removeFileOnAbort = true };
            _request.timeout = timeoutSeconds;
            _op = _request.SendWebRequest();
        }

        public bool IsDone
        {
            get
            {
                if (_aborted) return true;
                if (_op.isDone) return true;

                if (Environment.TickCount > _deadlineTicks)
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
                string header = _request.GetResponseHeader("Content-Length");
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

        public long FinalSize
        {
            get
            {
                if (_finalSize >= 0) return _finalSize;
                if (!_op.isDone && !_aborted) return -1;
                _finalSize = SafeFileSize();
                return _finalSize;
            }
        }

        private long SafeFileSize()
        {
            try { return new FileInfo(_destPath).Length; }
            catch { return -1; }
        }

        private void AbortInternal()
        {
            if (_aborted) return;
            _aborted = true;
            try { _request.Abort(); } catch { /* may already be torn down */ }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            try { _request.Dispose(); } catch { /* ignore */ }
        }
    }
}
