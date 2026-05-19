using GladeAgenticAI.Core.Tools.Implementations.Camera;
using GladeAgenticAI.Core.Tools.Implementations.Lighting;
using GladeAgenticAI.Core.Tools.Implementations.Materials;
using GladeAgenticAI.Core.Tools.Implementations.ProjectSettings;
using GladeAgenticAI.Core.Tools.Implementations.VFX;
using GladeAgenticAI.Core.Tools.Implementations.Audio;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterMaterialAndRenderingTools()
        {
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

            // Lighting
            Register(new CreateLightTool());
            Register(new SetLightPropertiesTool());
            Register(new SetRenderSettingsTool());
            Register(new CreateReflectionProbeTool());
            Register(new GetLightInfoTool());
            Register(new GetRenderSettingsTool());
            Register(new GetLightingSettingsTool());

            // ProjectSettings (render pipeline + quality)
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
            // SetPostProcessingTool is registered by SrpToolRegistrar in the
            // GladeKit.Bridge.SRP assembly — render-pipeline-specific tools live there.
        }
    }
}
