using GladeAgenticAI.Core.Tools.Implementations.Physics;

namespace GladeAgenticAI.Services
{
    public partial class ToolRegistry
    {
        private void RegisterPhysicsTools()
        {
            // Colliders + Rigidbody + CharacterController
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

            // Physics queries (raycast/overlap/sweep)
            Register(new RaycastTool());
            Register(new LinecastTool());
            Register(new OverlapSphereTool());
            Register(new OverlapBoxTool());
            Register(new SphereCastTool());
            Register(new BoxCastTool());
            Register(new GetCollisionMatrixTool());
            Register(new SetCollisionMatrixTool());
        }
    }
}
