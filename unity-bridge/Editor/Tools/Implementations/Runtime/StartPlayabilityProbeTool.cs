using System.Collections.Generic;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Runtime
{
    /// <summary>
    /// Phase 1 of the Automated Playability Probe: arm the run and enter Play
    /// mode. A controller-driving <c>ProbeDriver</c> spawns automatically after
    /// the scene loads (see ProbeDriver.AutoStart), holds forward, presses jump,
    /// samples the player's position, then writes a result and exits Play.
    /// Phase 2 (<c>get_playability_probe_result</c>) polls for that result.
    ///
    /// Two-phase, not one blocking call, because the bridge runs on Unity's
    /// main thread: a single tool can't block for ~5s of real-time simulation
    /// (it would freeze the physics it's trying to measure) and EnterPlaymode
    /// triggers a domain reload that wipes static state mid-run. State lives in
    /// <see cref="PlayabilityProbeStore"/> (SessionState — survives the reload).
    ///
    /// Eval/automation tool: it hijacks the editor into Play mode, so it is
    /// deliberately NOT exposed in the agent tool schema. Only the eval harness
    /// calls it, directly via /api/tools/execute (the same path reset_eval_state
    /// uses).
    ///
    /// Args (all optional):
    ///   targetName      string  player GameObject to measure   (default "Player")
    ///   holdSeconds     float   seconds to hold forward         (default 5)
    ///   jumpAtSeconds   float   when to press jump              (default 2)
    ///   watchdogSeconds float   hard cap before forced exit     (default 8)
    /// </summary>
    public class StartPlayabilityProbeTool : ITool
    {
        public string Name => "start_playability_probe";

        public string Execute(Dictionary<string, object> args)
        {
#if !GLADE_INPUT_SYSTEM
            // No new Input System package: the probe drives controllers via a
            // virtual Keyboard device, which requires it. Report not_applicable
            // (a terminal status) rather than silently passing or failing.
            string naEnvelope = ToolUtils.CreateSuccessResponse(
                "Playability probe not applicable: new Input System not installed",
                new Dictionary<string, object>
                {
                    ["status"] = "not_applicable",
                    ["error"] = "com.unity.inputsystem not present",
                    ["straightness"] = null,
                    ["pathLength"] = null,
                    ["jumpDy"] = null,
                    ["threw"] = false,
                });
            PlayabilityProbeStore.SetResult(naEnvelope);
            return ToolUtils.CreateSuccessResponse(
                "Playability probe not applicable (no Input System)",
                new Dictionary<string, object> { ["started"] = false, ["status"] = "not_applicable" });
#else
            if (EditorApplication.isPlaying || EditorApplication.isPlayingOrWillChangePlaymode)
            {
                return ToolUtils.CreateErrorResponse(
                    "Cannot start playability probe: editor is already in (or entering) Play mode");
            }

            var probeParams = new Dictionary<string, object>
            {
                ["targetName"] = ToolUtils.GetStringArg(args, "targetName", "Player"),
                ["holdSeconds"] = ToolUtils.GetFloatArg(args, "holdSeconds", 5f),
                ["jumpAtSeconds"] = ToolUtils.GetFloatArg(args, "jumpAtSeconds", 2f),
                ["watchdogSeconds"] = ToolUtils.GetFloatArg(args, "watchdogSeconds", 8f),
            };

            PlayabilityProbeStore.Arm(ToolUtils.SerializeDictToJson(probeParams));

            // Enter Play mode. This returns immediately; the actual play-enter +
            // domain reload happen asynchronously, after which ProbeDriver picks
            // up the armed run. The harness polls get_playability_probe_result.
            EditorApplication.isPlaying = true;

            return ToolUtils.CreateSuccessResponse(
                "Playability probe started — entering Play mode",
                new Dictionary<string, object>
                {
                    ["started"] = true,
                    ["status"] = "running",
                    ["targetName"] = probeParams["targetName"],
                });
#endif
        }
    }
}
