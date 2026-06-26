using GladeAgenticAI.Core.Tools.Implementations.Camera;
using GladeAgenticAI.Core.Tools.Implementations.Diagnostics;
using GladeAgenticAI.Core.Tools.Implementations.Profiler;
using GladeAgenticAI.Core.Tools.Implementations.Runtime;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterRuntimeAndDiagnosticsTools()
        {
            // Profiler
            Register(new StartProfilerTool());
            Register(new StopProfilerTool());
            Register(new GetFrameTimingTool());
            Register(new GetMemoryStatsTool());
            Register(new GetGcAllocationsTool());
            Register(new GetProfilerCountersTool());
            Register(new EnableFrameDebuggerTool());
            Register(new GetFrameDebuggerEventsTool());

            // Runtime (Live Loop autonomous fix-on-error)
            Register(new StartRuntimeObservationTool());
            Register(new StopRuntimeObservationTool());
            Register(new GetRuntimeEventsTool());
            Register(new GetPlayModeStateTool());
            Register(new ApplyQueuedFixTool());

            // Diagnostics — eval/automation tooling
            Register(new ResetEvalStateTool());

            // Vision — capture the rendered game view so the assistant can see
            // what it built (read-only; edit-mode safe via camera render).
            Register(new LookAtGameViewTool());

            // Playability probe — eval-only, two-phase arm+poll. Bridge-
            // registered but NOT in the agent schema (it enters Play mode;
            // the harness drives it directly via /api/tools/execute).
            Register(new StartPlayabilityProbeTool());
            Register(new GetPlayabilityProbeResultTool());
        }
    }
}
