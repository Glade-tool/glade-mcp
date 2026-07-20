#if GLADE_INPUT_SYSTEM
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.InputSystem.LowLevel;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Editor-side driver for the Automated Playability Probe.
    ///
    /// IMPORTANT — why this is a static EditorApplication.update driver and NOT
    /// a MonoBehaviour: this code lives in the Editor-only bridge assembly, and
    /// Unity forbids attaching an editor-assembly MonoBehaviour to a GameObject
    /// at runtime ("Can't add script behaviour ... it is an editor script").
    /// So we drive the probe from <see cref="EditorApplication.update"/>, which
    /// ticks during Play mode on the editor side: it queues synthetic input,
    /// samples the player's position, and ends the run — all without a runtime
    /// component. The controller under test (a normal Assets/Scripts MonoBehaviour)
    /// runs its own Update in Play mode as usual; we only observe + inject.
    ///
    /// Headless robustness: the probe sets <c>Application.runInBackground = true</c>
    /// so the Play loop keeps advancing when the Unity window is not focused —
    /// otherwise an automated probe stalls the moment focus leaves the editor
    /// (Play simulation freezes with Run-In-Background off).
    ///
    /// Pipeline:
    /// <code>
    ///   EnterPlaymode (RuntimeInitializeOnLoad) ──armed?──> hook EditorApplication.update
    ///        │  each editor tick (runInBackground keeps it ticking unfocused)
    ///        ▼
    ///   queue "W held" (+ "Space" on one frame at jumpAt) -> virtual Keyboard
    ///   sample target.position
    ///        │  at holdSeconds (wall clock)
    ///        ▼
    ///   straightness + pathLength + jumpDy + threw -> SetResult; unhook; exit Play
    /// </code>
    ///
    /// Preconditions (the eval scene owns these): target reads the new Input
    /// System (<c>Keyboard.current</c>), a floor exists so the controller can
    /// ground, a camera exists for camera-relative movement. A player that falls
    /// through the void scores path≈0 / jump≈0 — itself a correct "not playable".
    /// </summary>
    public static class ProbeDriver
    {
        private static bool _running;
        private static bool _initialized;
        private static string _setupError;

        private static string _targetName = "Player";
        private static float _holdSeconds = 5f;
        private static float _jumpAtSeconds = 2f;
        private static float _watchdogSeconds = 8f;

        // Boot-only: enter Play and watch the log stream for holdSeconds without
        // finding a target or driving input. The runtime-correctness check for an
        // arbitrary gameplay change (see StartPlayabilityProbeTool for the two
        // modes) — reports `threw` + captured error lines, no movement metrics.
        private static bool _bootOnly;
        // Runtime-log cursor snapshotted at the START of the play session (before
        // any Awake/Start runs), so error lines logged DURING this run can be read
        // back at finish (get_playability_probe_result surfaces them as `errors`).
        // Snapshotted in SnapshotLogBaseline (BeforeSceneLoad) rather than in
        // Initialize (first Tick): a NullReference thrown in Awake/Start — the most
        // important class to catch — fires before the first editor-update tick, so
        // an Initialize-time snapshot would sit PAST it and silently drop it.
        private static long _logCursorAtStart;
        private static bool _logBaselineSnapped;

        // Hold Space this long (wall seconds) so the InputSystem samples a frame
        // with Space down and fires wasPressedThisFrame. EditorApplication.update
        // ticks ~1000x/sec, far faster than the input update, so a one-tick press
        // gets coalesced away — the hold window guarantees the edge is seen.
        private const float JumpHoldSeconds = 0.2f;

        private static Transform _target;
        private static Keyboard _virtualKeyboard;
        private static readonly List<Vector3> _samples = new List<Vector3>();
        private static double _startTime;
        private static bool _spaceHeld;
        private static bool _jumpDone;
        private static int _jumpStartIndex;

        /// <summary>
        /// Fires once per Play-enter. Starts the editor-update probe only when a
        /// run is armed, so normal Play sessions are untouched. This method runs
        /// fine from the Editor assembly (it's a method, not a component) — the
        /// MonoBehaviour restriction only applies to AddComponent.
        /// </summary>
        /// <summary>
        /// Snapshot the runtime-log baseline as early as possible in the play
        /// session — before scene objects Awake/Start — so an exception thrown in
        /// those first callbacks is captured, not skipped. Runs on every play-enter
        /// (RuntimeInitializeOnLoadMethod fires each time); only acts when a probe
        /// is armed so normal Play sessions are untouched.
        ///
        /// Empty ring → baseline -1 (GetEventsSinceCursor is strict-greater-than,
        /// and a fresh domain-reloaded session starts at cursor 0, so -1 is needed
        /// to include that first event). Non-empty ring (Domain Reload disabled, so
        /// prior-session errors persist) → the latest cursor, to exclude them.
        /// </summary>
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        private static void SnapshotLogBaseline()
        {
            if (!PlayabilityProbeStore.IsArmed) return;
            _logCursorAtStart = RuntimeLogStream.CurrentSize == 0
                ? -1
                : RuntimeLogStream.LatestCursor();
            _logBaselineSnapped = true;
        }

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void AutoStart()
        {
            if (!PlayabilityProbeStore.IsArmed) return;
            if (_running) return;

            _running = true;
            _initialized = false;
            _setupError = null;
            Application.runInBackground = true;
            EditorApplication.update += Tick;
        }

        private static void Tick()
        {
            if (!_running) return;
            if (!EditorApplication.isPlaying) { Cleanup(); return; }

            if (!_initialized)
            {
                Initialize();
                if (_setupError != null) { Finish("error", _setupError); return; }
            }

            double elapsed = EditorApplication.timeSinceStartup - _startTime;

            // Boot-only: no target, no input — just let the scene run and end the
            // window. threw + captured error lines are gathered in FinishRun.
            if (_bootOnly)
            {
                if (elapsed >= _holdSeconds || elapsed >= _watchdogSeconds)
                {
                    FinishRun();
                }
                return;
            }

            // Drive input by CHANGE, not every tick. W is queued once at init
            // and stays held. Space is pressed for a JumpHoldSeconds window so
            // the input update actually samples a Space-down frame (a one-tick
            // press at ~1000Hz gets coalesced before the edge is ever seen).
            bool wantSpace = !_jumpDone
                && elapsed >= _jumpAtSeconds
                && elapsed < _jumpAtSeconds + JumpHoldSeconds;
            if (elapsed >= _jumpAtSeconds + JumpHoldSeconds) _jumpDone = true;

            if (wantSpace != _spaceHeld && _virtualKeyboard != null)
            {
                if (wantSpace) _jumpStartIndex = _samples.Count; // rise measured from press
                var keys = wantSpace ? new[] { Key.W, Key.Space } : new[] { Key.W };
                InputSystem.QueueStateEvent(_virtualKeyboard, new KeyboardState(keys));
                _spaceHeld = wantSpace;
            }

            if (_target != null) _samples.Add(_target.position);

            if (elapsed >= _holdSeconds || elapsed >= _watchdogSeconds)
            {
                FinishRun();
            }
        }

        private static void Initialize()
        {
            ParseParams(PlayabilityProbeStore.ReadParams());
            // The baseline is normally snapshotted in SnapshotLogBaseline
            // (BeforeSceneLoad). Fall back here only if that hook somehow didn't
            // run — better a slightly-late baseline than an uninitialized 0 that
            // would drop the first captured error.
            if (!_logBaselineSnapped)
            {
                _logCursorAtStart = RuntimeLogStream.CurrentSize == 0
                    ? -1
                    : RuntimeLogStream.LatestCursor();
            }
            _samples.Clear();
            _spaceHeld = false;
            _jumpDone = false;
            _jumpStartIndex = -1;

            // Boot-only skips target lookup + input device entirely: it only
            // watches for runtime errors, so a missing "Player" is not a setup
            // error here (a spawner/score script has no player to drive).
            if (_bootOnly)
            {
                _target = null;
                _startTime = EditorApplication.timeSinceStartup;
                _initialized = true;
                return;
            }

            var go = GameObject.Find(_targetName);
            if (go == null)
            {
                _setupError = $"target '{_targetName}' not found in scene";
                _initialized = true;
                return;
            }
            _target = go.transform;

            // A virtual Keyboard makes Keyboard.current resolve to our device,
            // so a controller reading Keyboard.current.wKey/spaceKey responds to
            // the events we queue. Works for the bundled template AND any LLM-
            // generated controller using the same idiom.
            _virtualKeyboard = InputSystem.AddDevice<Keyboard>();
            // Press-and-hold W from the first frame (held state persists until
            // changed). Space is added later for its window in Tick.
            InputSystem.QueueStateEvent(_virtualKeyboard, new KeyboardState(Key.W));
            _samples.Add(_target.position);
            _startTime = EditorApplication.timeSinceStartup;
            _initialized = true;
        }

        private static void FinishRun()
        {
            var errorLines = CollectErrorLines();
            // Derive `threw` from the SAME cursor window as the captured lines,
            // not from TotalEventsObserved: that counter increments on a lagged
            // main-thread delayCall and is not cursor-scoped, so a pre-existing
            // console error whose callback drains after the run's start snapshot
            // would inflate it and mark a clean run dirty (with no line to show).
            // CollectErrorLines only sees errors logged strictly after the run
            // began, so its count is the run-scoped truth.
            bool threw = errorLines.Count > 0;

            if (_bootOnly)
            {
                // No target/input in boot-only, so no movement metrics — the
                // runtime-error signal is the whole point.
                Finish("done", null, null, null, null, threw, _samples.Count, errorLines);
                return;
            }

            float straightness = PlayabilityMetrics.Straightness(_samples);
            float pathLength = PlayabilityMetrics.PlanarPathLength(_samples);
            int jumpIndex = _jumpStartIndex >= 0 ? _jumpStartIndex : 0;
            float jumpDy = PlayabilityMetrics.MaxJumpRise(_samples, jumpIndex);
            Finish("done", null, straightness, pathLength, jumpDy, threw, _samples.Count, errorLines);
        }

        /// <summary>
        /// Read back the runtime-error messages logged since the run started
        /// (deduped, length-capped). Best-effort: the gate treats `threw` as the
        /// summary and these as the detail lines it echoes to the model/user.
        /// </summary>
        private static List<string> CollectErrorLines()
        {
            var lines = new List<string>();
            var events = RuntimeLogStream.GetEventsSinceCursor(_logCursorAtStart, 20);
            foreach (var evt in events)
            {
                string msg = (evt.Message ?? string.Empty).Trim();
                if (msg.Length == 0) continue;
                if (msg.Length > 300) msg = msg.Substring(0, 300);
                if (!lines.Contains(msg)) lines.Add(msg);
            }
            return lines;
        }

        private static void Finish(
            string status,
            string error,
            float? straightness = null,
            float? pathLength = null,
            float? jumpDy = null,
            bool threw = false,
            int samples = 0,
            List<string> errorLines = null)
        {
            var extras = new Dictionary<string, object>
            {
                ["status"] = status,
                ["straightness"] = straightness.HasValue ? (object)straightness.Value : null,
                ["pathLength"] = pathLength.HasValue ? (object)pathLength.Value : null,
                ["jumpDy"] = jumpDy.HasValue ? (object)jumpDy.Value : null,
                ["threw"] = threw,
                ["errors"] = errorLines ?? new List<string>(),
                ["error"] = error,
                ["sampleCount"] = samples,
            };
            PlayabilityProbeStore.SetResult(
                ToolUtils.CreateSuccessResponse("Playability probe complete", extras));

            Cleanup();
            // Result is in SessionState, which survives the play-exit reload.
            EditorApplication.isPlaying = false;
        }

        private static void Cleanup()
        {
            EditorApplication.update -= Tick;
            if (_virtualKeyboard != null)
            {
                InputSystem.RemoveDevice(_virtualKeyboard);
                _virtualKeyboard = null;
            }
            _running = false;
            // Reset so the next armed session re-snapshots its own baseline
            // (matters when Domain Reload is disabled and statics persist).
            _logBaselineSnapped = false;
        }

        private static void ParseParams(string json)
        {
            if (string.IsNullOrEmpty(json)) return;
            try
            {
                var dto = JsonUtility.FromJson<ProbeParams>(json);
                if (dto != null)
                {
                    _bootOnly = dto.bootOnly;
                    if (!string.IsNullOrEmpty(dto.targetName)) _targetName = dto.targetName;
                    if (dto.holdSeconds > 0f) _holdSeconds = dto.holdSeconds;
                    if (dto.jumpAtSeconds > 0f) _jumpAtSeconds = dto.jumpAtSeconds;
                    if (dto.watchdogSeconds > 0f) _watchdogSeconds = dto.watchdogSeconds;
                }
            }
            catch
            {
                // Keep defaults on any parse trouble — the probe should still run.
            }
        }

        [System.Serializable]
        private class ProbeParams
        {
            public bool bootOnly;
            public string targetName;
            public float holdSeconds;
            public float jumpAtSeconds;
            public float watchdogSeconds;
        }
    }
}
#endif
