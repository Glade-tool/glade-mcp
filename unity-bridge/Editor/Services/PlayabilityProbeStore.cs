using UnityEditor;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// State store for the two-phase playability probe.
    ///
    /// The probe is inherently asynchronous and spans a domain reload:
    /// <c>start_playability_probe</c> arms the run and enters Play mode (which
    /// triggers a domain reload), then <c>ProbeDriver</c> runs ~5s of real-time
    /// simulation before writing its result, and the harness polls
    /// <c>get_playability_probe_result</c> until a terminal status appears.
    ///
    /// That lifecycle rules out static fields: <see cref="PlayModeObserver"/>
    /// and <see cref="RuntimeLogStream"/> both reset on domain reload by design,
    /// so a static result would be wiped mid-probe. <see cref="SessionState"/>
    /// is Unity's session-scoped key/value store: it SURVIVES domain reloads
    /// within one Editor session and clears on Editor restart — exactly the
    /// scope a single probe run needs.
    ///
    /// State machine:
    /// <code>
    ///   (idle) --Arm()--> [armed, running] --SetResult()--> [result, terminal]
    ///      ^                                                      |
    ///      +---------------------- Clear() ----------------------+
    /// </code>
    /// "Terminal" status (done | error | not_applicable) lives inside the
    /// stored result envelope; the Get tool returns that envelope verbatim.
    /// </summary>
    public static class PlayabilityProbeStore
    {
        private const string KeyArmed = "GladeKit.PlayabilityProbe.Armed";
        private const string KeyParams = "GladeKit.PlayabilityProbe.Params";
        private const string KeyResult = "GladeKit.PlayabilityProbe.Result";

        /// <summary>Arms a probe run with the given JSON params and clears any
        /// prior result. After Arm, <see cref="IsArmed"/> is true and
        /// <see cref="HasResult"/> is false (status = running).</summary>
        public static void Arm(string paramsJson)
        {
            SessionState.SetString(KeyParams, paramsJson ?? "{}");
            SessionState.EraseString(KeyResult);
            SessionState.SetBool(KeyArmed, true);
        }

        /// <summary>True between Arm() and SetResult() — the probe is running.</summary>
        public static bool IsArmed => SessionState.GetBool(KeyArmed, false);

        /// <summary>The JSON params passed to Arm(). Defaults to "{}".</summary>
        public static string ReadParams() => SessionState.GetString(KeyParams, "{}");

        /// <summary>True once a terminal result has been written.</summary>
        public static bool HasResult =>
            !string.IsNullOrEmpty(SessionState.GetString(KeyResult, string.Empty));

        /// <summary>The stored result envelope (the full JSON string the Get
        /// tool returns verbatim). Empty string if no result yet.</summary>
        public static string ReadResult() => SessionState.GetString(KeyResult, string.Empty);

        /// <summary>Records the terminal result envelope and disarms the probe.
        /// <paramref name="resultEnvelopeJson"/> is the complete tool-response
        /// JSON (including a terminal "status" field) that the Get tool will
        /// return verbatim.</summary>
        public static void SetResult(string resultEnvelopeJson)
        {
            SessionState.SetString(KeyResult, resultEnvelopeJson ?? string.Empty);
            SessionState.SetBool(KeyArmed, false);
        }

        /// <summary>Wipes all probe state back to idle. Called by Clear flows
        /// and as defensive cleanup.</summary>
        public static void Clear()
        {
            SessionState.EraseBool(KeyArmed);
            SessionState.EraseString(KeyParams);
            SessionState.EraseString(KeyResult);
        }
    }
}
