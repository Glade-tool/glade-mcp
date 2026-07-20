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
    /// This enters Play mode, which is modal, so it is used narrowly: the eval
    /// harness calls the movement mode directly via /api/tools/execute, and the
    /// play-verify gate uses the boot-only mode to confirm a gameplay change
    /// runs without throwing before reporting completion.
    ///
    /// Two modes:
    ///   - movement (default): finds the target, holds forward, presses jump,
    ///     and reports movement metrics (straightness, pathLength, jumpDy)
    ///     alongside `threw`. Used by the eval harness.
    ///   - boot-only (<c>bootOnly:true</c>): does NOT look for a target or drive
    ///     input. It just enters Play, lets the scene run for <c>holdSeconds</c>,
    ///     and reports whether anything was logged as an error (<c>threw</c> +
    ///     the captured <c>errors</c> lines). This is the runtime-correctness
    ///     check for an arbitrary gameplay change, where "did the player walk
    ///     forward" is meaningless but "did Start/Update throw" is the point.
    ///
    /// Args (all optional):
    ///   bootOnly        bool    boot-and-watch, no target/input (default false)
    ///   targetName      string  player GameObject to measure   (default "Player")
    ///   holdSeconds     float   seconds to run before sampling  (default 5)
    ///   jumpAtSeconds   float   when to press jump (movement)   (default 2)
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
                    // Shape parity with the boot-only success envelope so a
                    // caller can read result["errors"] unconditionally.
                    ["errors"] = new List<string>(),
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

            bool bootOnly = ToolUtils.GetBoolArg(args, "bootOnly", false);
            var probeParams = new Dictionary<string, object>
            {
                ["bootOnly"] = bootOnly,
                ["targetName"] = ToolUtils.GetStringArg(args, "targetName", "Player"),
                // Boot-only just needs enough frames for Start/Update to run and
                // throw; a short window keeps the modal Play-mode enter brief.
                ["holdSeconds"] = ToolUtils.GetFloatArg(args, "holdSeconds", bootOnly ? 3f : 5f),
                ["jumpAtSeconds"] = ToolUtils.GetFloatArg(args, "jumpAtSeconds", 2f),
                ["watchdogSeconds"] = ToolUtils.GetFloatArg(args, "watchdogSeconds", bootOnly ? 5f : 8f),
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
