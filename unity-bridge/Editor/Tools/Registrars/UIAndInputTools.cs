#if GLADE_UGUI
using GladeAgenticAI.Core.Tools.Implementations.UI;
#endif
#if GLADE_INPUT_SYSTEM
using GladeAgenticAI.Core.Tools.Implementations.Input;
#endif
#if ENABLE_LEGACY_INPUT_MANAGER
using GladeAgenticAI.Core.Tools.Implementations.InputLegacy;
#endif

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterUIAndInputTools()
        {
#if GLADE_UGUI
            // UI (UGUI)
            Register(new CreateCanvasTool());
            Register(new ImportTMPEssentialResourcesTool());
            Register(new CreateEventSystemTool());
            Register(new CheckUiElementExistsTool());
            Register(new SetCanvasGroupPropertiesTool());
            Register(new SetLayoutGroupPropertiesTool());
            Register(new ListUiHierarchyTool());
            Register(new FindUiElementsByTypeTool());
            Register(new GetUiElementInfoTool());
            Register(new GetUiEventHandlersTool());
            Register(new SetUiEventTool());
            Register(new RemoveUiEventTool());
            Register(new CreateUiElementTool());
            Register(new SetUiPropertiesTool());
#endif

#if GLADE_INPUT_SYSTEM
            // New Input System
            Register(new CreateInputActionAssetTool());
            Register(new SetInputActionBindingsTool());
            Register(new AssignInputActionsTool());
#endif

#if ENABLE_LEGACY_INPUT_MANAGER
            // Legacy Input Manager
            Register(new ListLegacyInputAxesTool());
            Register(new EnsureLegacyInputAxesTool());
#endif
        }
    }
}
