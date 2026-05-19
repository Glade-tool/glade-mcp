using System.Collections.Generic;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Core.Tools.Implementations.Transform
{
    public class SetLocalTransformTool : ITool
    {
        public string Name => "set_local_transform";

        public string Execute(Dictionary<string, object> args)
        {
            return TransformToolCore.Execute(args, isLocal: true, toolDisplay: "Set Local Transform");
        }
    }
}
