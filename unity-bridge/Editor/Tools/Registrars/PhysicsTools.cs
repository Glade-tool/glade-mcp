using GladeAgenticAI.Core.Tools.Implementations.Physics;
using GladeAgenticAI.Core.Tools.Implementations.Physics2D;

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

            // 2D physics (separate simulation — Rigidbody2D/Collider2D)
            Register(new AddRigidbody2DTool());
            Register(new SetRigidbody2DPropertiesTool());
            Register(new CreateCollider2DTool());
            Register(new SetCollider2DPropertiesTool());
            Register(new CreatePhysicsMaterial2DTool());

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
