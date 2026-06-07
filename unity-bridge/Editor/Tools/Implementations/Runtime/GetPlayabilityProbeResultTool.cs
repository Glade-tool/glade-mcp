using System.Collections.Generic;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Runtime
{
    /// <summary>
    /// Phase 2 of the Automated Playability Probe: poll for the result. Read-
    /// only. Returns one of three shapes:
    ///
    ///   - terminal: the verbatim envelope ProbeDriver wrote, with
    ///     status = done | error | not_applicable and the metrics
    ///     (straightness, pathLength, jumpDy, threw).
    ///   - running: the probe is armed but ProbeDriver hasn't finished yet.
    ///   - error "no probe armed": nothing was started (defensive — the harness
    ///     always arms before polling).
    ///
    /// The harness (run_playability_probe) calls this on a poll loop until it
    /// sees a terminal status or its own deadline elapses.
    ///
    /// Eval/automation tool — not exposed in the agent schema (see
    /// StartPlayabilityProbeTool for why).
    /// </summary>
    public class GetPlayabilityProbeResultTool : ITool
    {
        public string Name => "get_playability_probe_result";

        public string Execute(Dictionary<string, object> args)
        {
            if (PlayabilityProbeStore.HasResult)
            {
                // Verbatim terminal envelope written by ProbeDriver.
                return PlayabilityProbeStore.ReadResult();
            }

            if (PlayabilityProbeStore.IsArmed)
            {
                return ToolUtils.CreateSuccessResponse(
                    "Playability probe running",
                    new Dictionary<string, object> { ["status"] = "running" });
            }

            return ToolUtils.CreateSuccessResponse(
                "No playability probe armed",
                new Dictionary<string, object>
                {
                    ["status"] = "error",
                    ["error"] = "no probe armed",
                });
        }
    }
}
