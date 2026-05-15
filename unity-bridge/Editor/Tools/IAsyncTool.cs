using System.Collections.Generic;

namespace GladeAgenticAI.Core.Tools
{
    /// <summary>
    /// Tools that yield back to the Unity Editor between phases — typically
    /// because they wait on network I/O or long file ops — implement this in
    /// addition to <see cref="ITool"/>. The bridge calls <c>BeginExecute</c>
    /// on the main thread, then polls the returned handle on each
    /// <c>EditorApplication.update</c> tick until <c>PollResult</c> returns
    /// non-null. Between polls the editor's frame loop runs normally, so the
    /// UI stays responsive even for a multi-second download.
    ///
    /// Callers that don't know about this protocol — most notably
    /// <c>batch_execute</c> — still hit <see cref="ITool.Execute"/> and get
    /// the legacy sync behavior. Implementers should make <c>Execute</c>
    /// either run the async pipeline to completion with a blocking poll loop
    /// (simpler, preserves batch behavior at the cost of an editor freeze on
    /// that path) or return an error envelope directing the user to the
    /// single-call path.
    /// </summary>
    public interface IAsyncTool : ITool
    {
        IAsyncToolHandle BeginExecute(Dictionary<string, object> args);
    }

    public interface IAsyncToolHandle
    {
        /// <summary>
        /// Advance the in-flight work and return the final JSON envelope when
        /// done, or null while still working. MUST be cheap — called every
        /// editor tick (60+ Hz). Implementations should poll an
        /// <c>AsyncOperation.isDone</c> flag or check a thread-safe
        /// completion bool rather than doing any blocking work.
        /// </summary>
        string PollResult();

        /// <summary>Short label for the current phase (e.g. "downloading"). Free-form.</summary>
        string Phase { get; }

        /// <summary>Fraction 0..1 if known, null if indeterminate.</summary>
        float? Progress { get; }

        /// <summary>
        /// Free any resources (web requests, file handles). Called once after
        /// <c>PollResult</c> returns non-null OR on timeout abort by the
        /// bridge. Safe to call multiple times.
        /// </summary>
        void Dispose();
    }
}
