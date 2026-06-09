using System;
using System.Collections.Generic;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Runtime
{
    /// <summary>
    /// Applies a queued multi-step fix by dispatching each change through
    /// the existing tool dispatcher. Idempotent — a second call with the
    /// same proposalId returns the prior result instead of re-executing.
    /// Useful for any agent orchestrating "review-then-apply" flows where
    /// the apply step needs at-most-once semantics.
    ///
    /// Args:
    ///   proposalId (string, required): idempotency key. A second call
    ///     with the same id returns <c>alreadyApplied: true</c> plus the
    ///     prior result without re-executing.
    ///   summary (string, optional): one-line user-facing description,
    ///     stored on the apply tracker for diagnostics.
    ///   changes (array, required): list of {toolName, args, rationale}
    ///     entries. Each is dispatched via ToolExecutor.ExecuteTool — so
    ///     they share the same DemoAssetsGuard and SessionTracker hooks
    ///     as direct tool calls.
    ///   expectedFileHashes (object, optional): map of asset-path → SHA-256
    ///     hex digest captured by the client at propose time. The bridge
    ///     verifies each entry against the file's current on-disk hash
    ///     before dispatching any change. If ANY mismatch, the apply is
    ///     refused with details so the caller can re-investigate rather
    ///     than silently overwriting user edits. Pass null/omit to skip
    ///     the check (e.g., for non-file-touching proposals or when the
    ///     client couldn't capture a baseline).
    ///
    /// Apply semantics:
    ///   - All changes attempted in order. First-error does NOT short-circuit
    ///     — a multi-step fix may have step 2 isolating a graceful failure
    ///     of step 1, and the cost of attempting all is low while the cost
    ///     of stopping early can leave a half-applied edit.
    ///   - Per-change results returned in the <c>results</c> extra so the
    ///     caller can reconstruct exactly what landed.
    ///   - Aggregate success = every change reported success. Any failure
    ///     marks the apply <c>success: false</c> and records that on the
    ///     tracker so a retry returns the failed-state record (NOT a free
    ///     re-execute — failure is a final state for v1).
    ///   - File-hash drift detection happens BEFORE any change runs — a
    ///     mismatch fails the whole apply atomically (zero changes land).
    ///   - postApplyCursor is captured BEFORE dispatch so callers can poll
    ///     <c>get_runtime_events(sinceCursor=...)</c> after a brief delay
    ///     to surface any compile errors triggered by the apply.
    /// </summary>
    public class ApplyQueuedFixTool : ITool
    {
        public string Name => "apply_queued_fix";

        public string Execute(Dictionary<string, object> args)
        {
            if (args == null)
                return ToolUtils.CreateErrorResponse("args required");

            string proposalId = args.TryGetValue("proposalId", out var pidObj) ? pidObj?.ToString() : null;
            if (string.IsNullOrEmpty(proposalId))
                return ToolUtils.CreateErrorResponse("proposalId is required");

            string summary = args.TryGetValue("summary", out var sObj) ? sObj?.ToString() ?? "" : "";

            // Idempotency check (Issue 2.C).
            var prior = FixApplyTracker.TryGet(proposalId);
            if (prior != null)
            {
                var alreadyExtras = new Dictionary<string, object>
                {
                    { "alreadyApplied", true },
                    { "proposalId", prior.ProposalId },
                    { "priorSuccess", prior.Success },
                    { "priorSummary", prior.Summary },
                    { "priorTimestamp", prior.Timestamp },
                };
                return ToolUtils.CreateSuccessResponse(
                    "Fix already applied — returning prior result",
                    alreadyExtras);
            }

            // Re-hydrate the changes array. Per the 2026-04-30 audit pass 5
            // lesson, ParseJsonToDict does NOT deep-parse nested JSON
            // arrays — values arrive as raw JSON strings and must be
            // re-hydrated via TryParseJsonArrayToList.
            List<object> changesList = null;
            if (args.TryGetValue("changes", out var chObj))
            {
                if (chObj is List<object> alreadyList)
                {
                    changesList = alreadyList;
                }
                else if (chObj is string rawJson)
                {
                    if (!ToolUtils.TryParseJsonArrayToList(rawJson, out changesList))
                        changesList = null;
                }
            }
            if (changesList == null || changesList.Count == 0)
                return ToolUtils.CreateErrorResponse("changes array is required and must be non-empty");

            // Hash-drift check (Live Loop critical gap fix, 2026-05-21).
            // If the cloud captured per-file hashes at propose time, verify
            // them against on-disk state BEFORE running any change. A single
            // drift fails the whole apply — protects against overwriting
            // user edits that landed between propose and apply.
            Dictionary<string, object> expectedHashes = null;
            if (args.TryGetValue("expectedFileHashes", out var hashesObj))
            {
                if (hashesObj is Dictionary<string, object> alreadyDict)
                    expectedHashes = alreadyDict;
                else if (hashesObj is string rawHashes)
                    expectedHashes = ToolUtils.ParseJsonToDict(rawHashes);
            }
            if (expectedHashes != null && expectedHashes.Count > 0)
            {
                var driftDetails = new List<Dictionary<string, object>>();
                foreach (var kv in expectedHashes)
                {
                    string path = kv.Key;
                    string expected = kv.Value?.ToString();
                    if (string.IsNullOrEmpty(path) || string.IsNullOrEmpty(expected))
                        continue;
                    string actual = ToolUtils.ComputeFileSha256(path);
                    // actual == null means file missing or unreadable; we
                    // treat that as drift because the AI's plan assumed
                    // the file existed in a specific state.
                    bool drifted = actual == null
                        || !string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase);
                    if (drifted)
                    {
                        driftDetails.Add(new Dictionary<string, object>
                        {
                            { "scriptPath", path },
                            { "expectedHash", expected },
                            { "actualHash", actual ?? "<missing or unreadable>" },
                        });
                    }
                }
                if (driftDetails.Count > 0)
                {
                    var driftExtras = new Dictionary<string, object>
                    {
                        { "alreadyApplied", false },
                        { "success", false },
                        { "hashMismatch", true },
                        { "driftedFiles", driftDetails },
                        { "proposalId", proposalId },
                    };
                    string fileList = string.Join(", ",
                        driftDetails.ConvertAll(d => d["scriptPath"].ToString()));
                    return ToolUtils.CreateErrorResponse(
                        $"Apply refused — {driftDetails.Count} file(s) changed since the proposal was generated: {fileList}. "
                        + "Re-investigate (the proposal may overwrite recent edits) or retry without expectedFileHashes to force-apply.",
                        driftExtras);
                }
            }

            // Snapshot the runtime-log cursor BEFORE any change runs so the
            // caller can poll get_runtime_events(sinceCursor=postApplyCursor)
            // after a brief delay to surface compile errors triggered by the
            // apply. Capturing pre-dispatch (not post-dispatch) is intentional:
            // a fix that compiles slowly may produce errors AFTER our return,
            // and the cursor needs to predate them.
            long postApplyCursor = RuntimeLogStream.LatestCursor();

            var perResults = new List<Dictionary<string, object>>();
            int successCount = 0;
            int failCount = 0;

            for (int i = 0; i < changesList.Count; i++)
            {
                var changeObj = changesList[i];
                var changeDict = changeObj as Dictionary<string, object>;
                if (changeDict == null)
                {
                    perResults.Add(new Dictionary<string, object>
                    {
                        { "index", i },
                        { "success", false },
                        { "error", "change entry is not an object" },
                    });
                    failCount++;
                    continue;
                }

                string toolName = changeDict.TryGetValue("toolName", out var tnObj)
                    ? tnObj?.ToString()
                    : (changeDict.TryGetValue("tool_name", out var tnObj2) ? tnObj2?.ToString() : null);
                if (string.IsNullOrEmpty(toolName))
                {
                    perResults.Add(new Dictionary<string, object>
                    {
                        { "index", i },
                        { "success", false },
                        { "error", "toolName is required on each change" },
                    });
                    failCount++;
                    continue;
                }

                Dictionary<string, object> innerArgs = null;
                if (changeDict.TryGetValue("args", out var aObj))
                {
                    if (aObj is Dictionary<string, object> alreadyDict)
                        innerArgs = alreadyDict;
                    else if (aObj is string rawArgs)
                        innerArgs = ToolUtils.ParseJsonToDict(rawArgs);
                }
                innerArgs ??= new Dictionary<string, object>();

                string innerArgsJson = ToolUtils.SerializeDictToJson(innerArgs);

                string innerResult;
                bool innerSuccess;
                try
                {
                    innerResult = ToolExecutor.ExecuteTool(toolName, innerArgsJson);
                    innerSuccess = !LooksLikeErrorResponse(innerResult);
                }
                catch (Exception ex)
                {
                    innerResult = ToolUtils.CreateErrorResponse($"Execution threw: {ex.Message}");
                    innerSuccess = false;
                }

                perResults.Add(new Dictionary<string, object>
                {
                    { "index", i },
                    { "toolName", toolName },
                    { "success", innerSuccess },
                    { "result", innerResult },
                });
                if (innerSuccess) successCount++; else failCount++;
            }

            bool overallSuccess = failCount == 0;
            double ts = (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            FixApplyTracker.Record(proposalId, overallSuccess, summary, ts);

            var extras = new Dictionary<string, object>
            {
                { "proposalId", proposalId },
                { "alreadyApplied", false },
                { "success", overallSuccess },
                { "successCount", successCount },
                { "failCount", failCount },
                { "results", perResults },
                // Cursor caller polls against to surface compile errors
                // triggered by this apply. Snapshot pre-dispatch so the
                // window covers any errors fired during AssetDatabase.Refresh.
                { "postApplyCursor", postApplyCursor },
            };

            string topMsg = overallSuccess
                ? $"Applied fix ({successCount} change(s))"
                : $"Fix apply incomplete: {successCount} succeeded, {failCount} failed";
            return overallSuccess
                ? ToolUtils.CreateSuccessResponse(topMsg, extras)
                : ToolUtils.CreateErrorResponse(topMsg, extras);
        }

        /// <summary>
        /// Heuristic: every successful tool envelope from
        /// <see cref="ToolUtils.CreateSuccessResponse"/> contains
        /// <c>"success":true</c>. Errors contain <c>"error":</c>. We
        /// inspect the prefix rather than parsing the full JSON because
        /// ParseJsonToDict isn't free and per-change failure detection
        /// is hot in a multi-step apply.
        /// </summary>
        private static bool LooksLikeErrorResponse(string result)
        {
            if (string.IsNullOrEmpty(result)) return true;
            // Cheap negative test: presence of "success":true at the start
            // OR absence of "error" altogether.
            if (result.Contains("\"success\":true")) return false;
            if (result.Contains("\"error\":")) return true;
            // Default: treat ambiguous responses as success. Real failures
            // from existing tools always include "error".
            return false;
        }
    }
}
