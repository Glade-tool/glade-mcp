using GladeAgenticAI.Core.Tools.Implementations.Components;
using GladeAgenticAI.Core.Tools.Implementations.Hierarchy;
using GladeAgenticAI.Core.Tools.Implementations.Prefabs;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterComponentAndPrefabTools()
        {
            // Components
            Register(new AddComponentTool());
            Register(new RemoveComponentTool());
            Register(new SetComponentPropertyTool());
            Register(new SetScriptComponentPropertyTool());
            Register(new SetObjectReferenceTool());

            // Prefabs
            Register(new CreatePrefabTool());
            Register(new InstantiatePrefabTool());
            Register(new SetPrefabTransformTool());
            Register(new GetPrefabInfoTool());
            Register(new SetPrefabPropertyTool());
            Register(new AddPrefabComponentTool());
            Register(new RemovePrefabComponentTool());
            Register(new SetPrefabGameObjectPropertyTool());
            Register(new RenamePrefabObjectTool());
            Register(new AddPrefabChildTool());
            Register(new RemovePrefabChildTool());
            Register(new SetPrefabParentTool());
            Register(new DuplicatePrefabObjectTool());

            // Hierarchy
            Register(new FindGameObjectsTool());
            Register(new SnapToGroundTool());
            Register(new AlignObjectsTool());
            Register(new DistributeObjectsTool());
            Register(new GroupObjectsTool());
            Register(new GetSceneHierarchyTool());
            Register(new GetGameObjectComponentsTool());
            Register(new GetComponentInspectorPropertiesTool());
            Register(new CreateGroupTool());
            Register(new SetTransformBatchTool());
            Register(new DestroyGameObjectBatchTool());
        }
    }
}
