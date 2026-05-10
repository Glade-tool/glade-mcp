using System.Collections.Generic;
using System.Linq;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Assets;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;
using GladeAgenticAI.Core.Tools.Implementations.Scene;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Core.Tools.Implementations.Selection;
using GladeAgenticAI.Core.Tools.Implementations.Transform;
using GladeAgenticAI.Core.Tools.Implementations.Utility;
using GladeAgenticAI.Core.Tools.Implementations.Materials;
using GladeAgenticAI.Core.Tools.Implementations.Components;
using GladeAgenticAI.Core.Tools.Implementations.Prefabs;
using GladeAgenticAI.Core.Tools.Implementations.Hierarchy;
using GladeAgenticAI.Core.Tools.Implementations.Lighting;
using GladeAgenticAI.Core.Tools.Implementations.VFX;
using GladeAgenticAI.Core.Tools.Implementations.Audio;
using GladeAgenticAI.Core.Tools.Implementations.Physics;
using GladeAgenticAI.Core.Tools.Implementations.Profiler;
using GladeAgenticAI.Core.Tools.Implementations.Runtime;
using GladeAgenticAI.Core.Tools.Implementations.Camera;
#if GLADE_UGUI
using GladeAgenticAI.Core.Tools.Implementations.UI;
#endif
using GladeAgenticAI.Core.Tools.Implementations.ImportSettings;
using GladeAgenticAI.Core.Tools.Implementations.SceneManagement;
using GladeAgenticAI.Core.Tools.Implementations.Animation;
#if GLADE_INPUT_SYSTEM
using GladeAgenticAI.Core.Tools.Implementations.Input;
#endif
#if ENABLE_LEGACY_INPUT_MANAGER
using GladeAgenticAI.Core.Tools.Implementations.InputLegacy;
#endif
using GladeAgenticAI.Core.Tools.Implementations.Terrain;
using GladeAgenticAI.Core.Tools.Implementations.ProjectSettings;
using GameObjImpl = GladeAgenticAI.Core.Tools.Implementations.GameObject;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Central registry for all AI tools.
    /// Implements the Command Pattern to decouple tool execution from tool definition.
    /// </summary>
    public class ToolRegistry
    {
        private readonly Dictionary<string, ITool> _tools = new Dictionary<string, ITool>();
        private bool _isInitialized = false;

        /// <summary>
        /// Registers a tool instance.
        /// </summary>
        public void Register(ITool tool)
        {
            if (tool == null) return;
            if (!_tools.ContainsKey(tool.Name))
                _tools.Add(tool.Name, tool);
            else
                _tools[tool.Name] = tool;
        }

        /// <summary>
        /// Retrieves a tool by name.
        /// </summary>
        public ITool GetTool(string name)
        {
            InitializeIfNeeded();
            return _tools.TryGetValue(name, out var tool) ? tool : null;
        }

        /// <summary>
        /// Gets all registered tool names.
        /// </summary>
        public List<string> GetAllToolNames()
        {
            InitializeIfNeeded();
            return _tools.Keys.ToList();
        }

        private void InitializeIfNeeded()
        {
            if (_isInitialized) return;

            // GameObject
            Register(new GameObjImpl.CreatePrimitiveTool());
            Register(new GameObjImpl.CreateGameObjectTool());
            Register(new GameObjImpl.DestroyGameObjectTool());
            Register(new GameObjImpl.SetGameObjectActiveTool());
            Register(new GameObjImpl.SetGameObjectParentTool());
            Register(new GameObjImpl.ListChildrenTool());
            Register(new GameObjImpl.RenameGameObjectTool());
            Register(new GameObjImpl.DuplicateGameObjectTool());
            Register(new GameObjImpl.SetLayerTool());
            Register(new GameObjImpl.SetTagTool());
            Register(new GameObjImpl.GetGameObjectInfoTool());

            // Transform
            Register(new SetTransformTool());
            Register(new SetLocalTransformTool());

            // Scene
            Register(new OpenSceneTool());
            Register(new SaveSceneTool());
            Register(new SaveSceneAsTool());

            // Selection
            Register(new GetSelectionTool());
            Register(new SetSelectionTool());

            // Utility
            Register(new ThinkTool());
            Register(new GetInputSystemInfoTool());
            Register(new GetSessionSummaryTool());

            // Scripts
            Register(new GetScriptContentTool());
            Register(new FindScriptsTool());
            Register(new SearchScriptsTool());
            Register(new CompileScriptsTool());
            Register(new GetUnityConsoleLogsTool());
            Register(new CreateScriptTool());
            Register(new ModifyScriptTool());

            // Assets
            Register(new CheckAssetExistsTool());
            Register(new ListMaterialsTool());
            Register(new CreateFolderTool());
            Register(new RefreshAssetDatabaseTool());
            Register(new MoveAssetTool());
            Register(new DuplicateAssetTool());
            Register(new DeleteAssetTool());
            Register(new ListAssetsTool());
            Register(new CreateScriptableObjectTool());
            Register(new SetScriptableObjectPropertyTool());

            // Asset pipeline (external asset orchestration). Gated by
            // AssetPipelineGuard.IsEnabled — tools self-reject when disabled.
            Register(new ImportAssetTool());
            Register(new ListImportedAssetsTool());

            // Materials
            Register(new CreateMaterialTool());
            Register(new AssignMaterialToRendererTool());
            Register(new SetMaterialPropertyTool());
            Register(new GetMaterialUsageTool());
            Register(new FindMaterialsByShaderTool());
            Register(new GetShaderInfoTool());
            Register(new ListAvailableShadersTool());
            Register(new ChangeMaterialShaderTool());
            Register(new ConvertMaterialsToRenderPipelineTool());

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

            // GameObject Property
            Register(new GameObjImpl.SetGameObjectPropertyTool());

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

            // Lighting
            Register(new CreateLightTool());
            Register(new SetLightPropertiesTool());
            Register(new SetRenderSettingsTool());
            Register(new CreateReflectionProbeTool());
            Register(new GetLightInfoTool());
            Register(new GetRenderSettingsTool());
            Register(new GetLightingSettingsTool());

            // ProjectSettings
            Register(new GetQualitySettingsTool());
            Register(new SetQualitySettingsTool());
            Register(new GetRenderPipelineAssetSettingsTool());
            Register(new SetRenderPipelineAssetSettingsTool());

            // VFX
            Register(new CreateParticleSystemTool());
            Register(new GetParticleSystemPropertiesTool());
            Register(new SetParticleSystemPropertiesTool());

            // Audio
            Register(new CreateAudioSourceTool());
            Register(new GetAudioSourcePropertiesTool());
            Register(new SetAudioSourcePropertiesTool());
            Register(new AssignAudioClipTool());

            // Physics
            Register(new CreateColliderTool());
            Register(new GetColliderPropertiesTool());
            Register(new SetColliderPropertiesTool());
            Register(new CreateCharacterControllerTool());
            Register(new GetCharacterControllerPropertiesTool());
            Register(new SetCharacterControllerPropertiesTool());
            Register(new AddRigidbodyTool());
            Register(new GetRigidbodyPropertiesTool());
            Register(new SetRigidbodyPropertiesTool());
            Register(new CreatePhysicsMaterialTool());
            Register(new AssignPhysicsMaterialTool());
            // Physics queries
            Register(new RaycastTool());
            Register(new LinecastTool());
            Register(new OverlapSphereTool());
            Register(new OverlapBoxTool());
            Register(new SphereCastTool());
            Register(new BoxCastTool());
            Register(new GetCollisionMatrixTool());
            Register(new SetCollisionMatrixTool());

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

            // Camera
            Register(new CreateCameraTool());
            Register(new GetCameraPropertiesTool());
            Register(new SetCameraPropertiesTool());
            Register(new CreateRenderTextureTool());
#if GLADE_CINEMACHINE
            Register(new CreateCinemachineVirtualCameraTool());
            Register(new GetCinemachineVirtualCameraPropertiesTool());
            Register(new SetCinemachineVirtualCameraPropertiesTool());
#endif
#if GLADE_UGUI
            Register(new AssignRenderTextureTool());
#endif
            // SetPostProcessingTool is registered by SrpToolRegistrar in GladeKit.Bridge.SRP assembly

#if GLADE_UGUI
            // UI
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

            // Import Settings
            Register(new SetTextureImportSettingsTool());
            Register(new SetSpriteImportSettingsTool());
            Register(new SliceSpritesheetGridTool());
            Register(new SetModelImportSettingsTool());
            Register(new SetAudioImportSettingsTool());

            // Scene Management
            Register(new CreateSceneTool());
            Register(new ListScenesInBuildTool());

            // Animation (19 tools)
            Register(new CreateAnimatorControllerTool());
            Register(new AddAnimatorParametersTool());
            Register(new AddAnimatorStateTool());
            Register(new CreateBlendTree1DTool());
            Register(new CreateBlendTree2DTool());
            Register(new AddAnimatorLayerTool());
            Register(new SetAnimatorLayerPropertiesTool());
            Register(new CreateSubStateMachineTool());
            Register(new AddBlendTreeChildTool());
            // Blend tree management
            Register(new GetBlendTreeInfoTool());
            Register(new ModifyBlendTreePropertiesTool());
            Register(new RemoveBlendTreeChildTool());
            Register(new ModifyBlendTreeChildTool());
            Register(new AddAnimatorTransitionTool());
            Register(new AddAnimatorTransitionConditionsTool());
            Register(new RemoveAnimatorTransitionTool());
            Register(new RemoveAnimatorStateTool());
            Register(new RemoveAnimatorStateMachineTool());
            Register(new RemoveAnimatorParameterTool());
            Register(new AssignAnimatorControllerTool());
            Register(new SetAnimatorParameterTool());
            Register(new GetAnimationClipInfoTool());
            Register(new CreateAnimationClipTool());
            Register(new SetAnimationClipCurvesTool());
            // Sprite animation tools (Priority 0)
            Register(new CreateSpriteAnimationClipTool());
            Register(new SetSpriteAnimationCurvesTool());
            Register(new GetSpriteAnimationInfoTool());
            // Animation clip management (Priority 1)
            Register(new DeleteAnimationClipTool());
            Register(new ModifyAnimationClipTool());
            Register(new DuplicateAnimationClipTool());
            Register(new RemoveAnimationClipCurvesTool());
            Register(new GetAnimationClipCurvesTool());
            Register(new SetAnimationCurveTangentsTool());
            // Animator controller info (Priority 2)
            Register(new GetAnimatorControllerInfoTool());
            Register(new GetAnimatorStateInfoTool());
            Register(new GetAnimatorTransitionInfoTool());
            Register(new GetAnimatorLayerInfoTool());
            Register(new GetAnimatorParameterInfoTool());
            // Animator controller modify (Priority 2)
            Register(new SetAnimatorStatePropertiesTool());
            Register(new SetAnimatorTransitionPropertiesTool());
            Register(new DeleteAnimatorControllerTool());
            Register(new DuplicateAnimatorControllerTool());
            // Animation events (Priority 3)
            Register(new AddAnimationEventTool());
            Register(new RemoveAnimationEventTool());
            Register(new GetAnimationEventsTool());
            Register(new ModifyAnimationEventTool());
            
            // IK Tools
            Register(new CreateIKTargetTool());
            Register(new AssignIKTargetTool());
            Register(new GetIKTargetInfoTool());
            Register(new SetIKWeightTool());
            Register(new SetIKPositionTool());
            Register(new GetIKWeightTool());
            Register(new CreateIKControllerScriptTool());

#if GLADE_INPUT_SYSTEM
            // Input (3 tools)
            Register(new CreateInputActionAssetTool());
            Register(new SetInputActionBindingsTool());
            Register(new AssignInputActionsTool());
#endif
#if ENABLE_LEGACY_INPUT_MANAGER
            // Legacy Input Manager (2 tools)
            Register(new ListLegacyInputAxesTool());
            Register(new EnsureLegacyInputAxesTool());
#endif

            // Terrain (5 tools)
            Register(new CreateTerrainTool());
            Register(new SetTerrainPropertiesTool());
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

            _isInitialized = true;
        }
    }
}
