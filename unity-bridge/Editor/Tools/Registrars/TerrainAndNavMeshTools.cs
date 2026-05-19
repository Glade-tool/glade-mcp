using GladeAgenticAI.Core.Tools.Implementations.Terrain;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterTerrainAndNavMeshTools()
        {
            // Terrain
            Register(new CreateTerrainTool());
            Register(new SetTerrainPropertiesTool());

            // NavMesh agent (always available — Unity ships AI Navigation built-in for runtime)
#if GLADE_AI_NAVIGATION
            Register(new CreateNavMeshSurfaceTool());
            Register(new BakeNavMeshTool());
#endif
            Register(new SetNavMeshAgentTool());
            Register(new CalculateNavMeshPathTool());
            Register(new SampleNavMeshPositionTool());

#if GLADE_AI_NAVIGATION
            Register(new CreateNavMeshObstacleTool());
            Register(new SetNavMeshObstaclePropertiesTool());
            Register(new CreateNavMeshLinkTool());
            Register(new SetNavMeshLinkPropertiesTool());
            Register(new SetNavMeshSurfaceAdvancedTool());
#endif
            Register(new SetNavMeshAgentAdvancedTool());
            Register(new SetNavMeshAgentAreaMaskTool());
            Register(new GetNavMeshAreasTool());
            Register(new SetNavMeshAreaCostTool());
#if GLADE_AI_NAVIGATION
            Register(new ClearNavMeshTool());
            Register(new GetNavMeshInfoTool());
            Register(new GetNavMeshBoundsTool());
#endif
        }
    }
}
