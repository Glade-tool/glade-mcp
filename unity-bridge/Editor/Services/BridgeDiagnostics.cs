using System;
using System.Collections.Generic;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Editor-only ring buffer of bridge-level lifecycle and error events
    /// (server start / stop / restart, HTTP request faults, tool execution
    /// faults, slow-tool flags). Distinct from <see cref="RuntimeLogStream"/>,
    /// which captures Unity application <c>Error</c> / <c>Exception</c> log
    /// entries — this buffer is fed by the bridge itself so users can see
    /// what the bridge has been doing without scraping the Console.
    ///
    /// Kept deliberately small (50 entries) — the status window renders the
    /// whole buffer and the goal is "last few things that happened", not a
    /// full audit log. Records carry a UTC <c>DateTime</c> so the window can
    /// render an absolute timestamp the user can correlate with their own
    /// actions.
    ///
    /// Threading: <see cref="Record"/> is callable from any thread (the HTTP
    /// listener and tool executors both call it). All mutations take
    /// <see cref="_lock"/>; readers snapshot under the same lock.
    ///
    /// Scope: in-memory only. Reset on Editor domain reload — intentional.
    /// Persisting bridge faults across reloads would just surface noise from
    /// the previous session that the user can't act on anymore.
    /// </summary>
    public static class BridgeDiagnostics
    {
        public const int MaxEntries = 50;

        public enum Severity
        {
            Info,
            Warning,
            Error,
        }

        public sealed class Entry
        {
            public DateTime Timestamp;   // UTC
            public Severity Level;
            public string Source;        // e.g. "compile_scripts", "HandleRequest", "StartServer"
            public string Message;
        }

        private static readonly object _lock = new object();
        private static readonly LinkedList<Entry> _ring = new LinkedList<Entry>();

        /// <summary>Append an entry. Drops the oldest when the buffer is full.</summary>
        public static void Record(Severity level, string source, string message)
        {
            if (string.IsNullOrEmpty(message)) return;
            var entry = new Entry
            {
                Timestamp = DateTime.UtcNow,
                Level = level,
                Source = string.IsNullOrEmpty(source) ? "bridge" : source,
                Message = message,
            };
            lock (_lock)
            {
                _ring.AddLast(entry);
                while (_ring.Count > MaxEntries)
                {
                    _ring.RemoveFirst();
                }
            }
        }

        public static void Info(string source, string message) => Record(Severity.Info, source, message);
        public static void Warn(string source, string message) => Record(Severity.Warning, source, message);
        public static void Error(string source, string message) => Record(Severity.Error, source, message);

        /// <summary>
        /// Snapshot the buffer newest-first. Safe to call while other threads
        /// are appending — returns a fresh list, no shared state escapes.
        /// </summary>
        public static List<Entry> SnapshotNewestFirst()
        {
            lock (_lock)
            {
                var copy = new List<Entry>(_ring.Count);
                // LinkedList iterates oldest → newest; reverse for the UI.
                for (var node = _ring.Last; node != null; node = node.Previous)
                {
                    copy.Add(node.Value);
                }
                return copy;
            }
        }

        /// <summary>Drop every recorded entry. Used by the status window's "Clear" button.</summary>
        public static void Clear()
        {
            lock (_lock)
            {
                _ring.Clear();
            }
        }

        public static int Count
        {
            get { lock (_lock) { return _ring.Count; } }
        }

        /// <summary>
        /// Severity counts across the current buffer — convenience for the
        /// status window's summary line ("Errors: 2  Warnings: 1").
        /// </summary>
        public static (int errors, int warnings, int infos) SeverityCounts()
        {
            int e = 0, w = 0, i = 0;
            lock (_lock)
            {
                foreach (var entry in _ring)
                {
                    switch (entry.Level)
                    {
                        case Severity.Error: e++; break;
                        case Severity.Warning: w++; break;
                        case Severity.Info: i++; break;
                    }
                }
            }
            return (e, w, i);
        }
    }
}
