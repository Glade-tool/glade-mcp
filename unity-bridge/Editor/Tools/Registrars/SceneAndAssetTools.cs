using GladeAgenticAI.Core.Tools.Implementations.Assets;
using GladeAgenticAI.Core.Tools.Implementations.AssetPipeline;
using GladeAgenticAI.Core.Tools.Implementations.Gameplay;
using GladeAgenticAI.Core.Tools.Implementations.ImportSettings;
using GladeAgenticAI.Core.Tools.Implementations.Scene;
using GladeAgenticAI.Core.Tools.Implementations.SceneManagement;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Core.Tools.Implementations.Selection;
using GladeAgenticAI.Core.Tools.Implementations.Transform;
using GladeAgenticAI.Core.Tools.Implementations.Utility;
using GameObjImpl = GladeAgenticAI.Core.Tools.Implementations.GameObject;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterSceneAndAssetTools()
        {
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
            Register(new GameObjImpl.SetGameObjectPropertyTool());

            // Transform
            Register(new SetTransformTool());
            Register(new SetLocalTransformTool());

            // Scene
            Register(new OpenSceneTool());
            Register(new SaveSceneTool());
            Register(new SaveSceneAsTool());

            // Scene Management
            Register(new CreateSceneTool());
            Register(new ListScenesInBuildTool());

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
            Register(new CreateThirdPersonControllerScriptTool());

            // Gameplay scaffolders (vetted-template "describe → playable game" layer)
            Register(new CreateGameManagerTool());
            Register(new CreateCollectibleTool());
            Register(new CreateHazardTool());
            Register(new CreateHealthTool());
            Register(new CreateHealthBarTool());
            Register(new CreateEnemyTool());
            Register(new CreateProjectileTool());
            Register(new CreateMovingPlatformTool());
            Register(new CreateScreenShakeTool());
            Register(new CreateLevelSystemTool());
            Register(new CreateLootDropTool());
            Register(new CreatePauseMenuTool());
            Register(new CreateMainMenuTool());
            Register(new CreateSoundEffectsTool());
            Register(new CreateHitVfxTool());
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

            // Import Settings
            Register(new SetTextureImportSettingsTool());
            Register(new SetSpriteImportSettingsTool());
            Register(new SliceSpritesheetGridTool());
            Register(new SetModelImportSettingsTool());
            Register(new SetAudioImportSettingsTool());
        }
    }
}
