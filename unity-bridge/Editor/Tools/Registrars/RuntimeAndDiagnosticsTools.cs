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
        }
    }
}
