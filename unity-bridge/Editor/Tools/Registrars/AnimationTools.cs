using GladeAgenticAI.Core.Tools.Implementations.Animation;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterAnimationTools()
        {
            // Animator controllers + states + transitions (19 core tools)
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

            // Animation clips
            Register(new GetAnimationClipInfoTool());
            Register(new CreateAnimationClipTool());
            Register(new SetAnimationClipCurvesTool());

            // Sprite animation (Priority 0)
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

            // IK
            Register(new CreateIKTargetTool());
            Register(new AssignIKTargetTool());
            Register(new GetIKTargetInfoTool());
            Register(new SetIKWeightTool());
            Register(new SetIKPositionTool());
            Register(new GetIKWeightTool());
            Register(new CreateIKControllerScriptTool());
        }
    }
}
