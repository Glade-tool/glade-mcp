using System.Collections.Generic;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Scripts
{
    public class GetScriptContentTool : ITool
    {
        public string Name => "get_script_content";

        public string Execute(Dictionary<string, object> args)
        {
            if (!args.ContainsKey("scriptPath"))
                return ToolUtils.CreateErrorResponse("scriptPath is required");

            string scriptPath = args["scriptPath"]?.ToString() ?? "";

            // Optional 1-based inclusive line range. When either bound is present the tool returns
            // just that slice (plus totalLines) so the agent can pull one method out of a large
            // file instead of loading thousands of lines into context. Absent both, behaviour is
            // unchanged: the whole file.
            bool hasRange = ToolUtils.HasArg(args, "startLine") || ToolUtils.HasArg(args, "endLine");

            if (!hasRange)
            {
                if (UnityContextGatherer.TryGetScriptContent(scriptPath, out var content, out var error))
                {
                    var extras = new Dictionary<string, object>
                    {
                        { "scriptPath", scriptPath },
                        { "content", content }
                    };
                    return ToolUtils.CreateSuccessResponse($"Read script: {scriptPath}", extras);
                }
                return ToolUtils.CreateErrorResponse(error ?? "Failed to read script");
            }

            int startLine = ToolUtils.GetIntArg(args, "startLine", 0);
            int endLine = ToolUtils.GetIntArg(args, "endLine", 0);

            if (UnityContextGatherer.TryGetScriptContentSlice(
                    scriptPath, startLine, endLine,
                    out var slice, out int totalLines, out int returnedStart, out int returnedEnd, out var sliceError))
            {
                bool partial = returnedStart > 1 || returnedEnd < totalLines;
                var extras = new Dictionary<string, object>
                {
                    { "scriptPath", scriptPath },
                    { "content", slice },
                    { "startLine", returnedStart },
                    { "endLine", returnedEnd },
                    { "totalLines", totalLines },
                    { "partial", partial }
                };
                string message = $"Read lines {returnedStart}-{returnedEnd} of {totalLines} from {scriptPath}"
                    + (partial ? " (partial — pass a wider startLine/endLine, or omit both, for more)." : ".");
                return ToolUtils.CreateSuccessResponse(message, extras);
            }
            return ToolUtils.CreateErrorResponse(sliceError ?? "Failed to read script");
        }
    }
}
