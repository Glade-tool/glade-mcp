using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for the session-aware modify_script gate. AI clients that
    /// misread a "scaffold a new system" prompt as "extend an existing one"
    /// can silently overwrite real project code; without this gate a single
    /// misread modify_script call against a pre-existing user script can
    /// corrupt hundreds of lines.
    ///
    /// Contract under test: modify_script against a script not created in
    /// the current Unity session is REFUSED unless the caller explicitly
    /// passes confirmExistingFileModification=true. These tests cover both
    /// the SessionTracker predicate (WasScriptCreatedThisSession) and the
    /// ModifyScriptTool gate around it. File-system side effects use a
    /// dedicated _TmpSessionSafety/ folder under Assets/ so collisions
    /// with real project scripts are impossible.
    public class ModifyScriptTool_SessionSafety
    {
        private const string TmpDir = "Assets/_TmpSessionSafety";
        private const string TmpScript = "Assets/_TmpSessionSafety/Probe.cs";
        private const string MinimalContent = "public class Probe { }\n";
        private const string ModifiedContent = "public class Probe { public int n; }\n";

        [SetUp]
        public void SetUp()
        {
            SessionTracker.Reset();
            if (!Directory.Exists(TmpDir))
            {
                Directory.CreateDirectory(TmpDir);
                AssetDatabase.Refresh(ImportAssetOptions.Default);
            }
        }

        [TearDown]
        public void TearDown()
        {
            if (Directory.Exists(TmpDir))
            {
                AssetDatabase.DeleteAsset(TmpDir);
            }
            SessionTracker.Reset();
        }

        // ── SessionTracker.WasScriptCreatedThisSession ──────────────────────

        [Test]
        public void WasScriptCreatedThisSession_EmptyPath_ReturnsFalse()
        {
            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession(""));
            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession(null));
        }

        [Test]
        public void WasScriptCreatedThisSession_PathNeverRecorded_ReturnsFalse()
        {
            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession(TmpScript));
        }

        [Test]
        public void WasScriptCreatedThisSession_RecordedCreate_ReturnsTrue()
        {
            // Mimic what UnityBridgeServer does: record after a successful tool dispatch.
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(TmpScript));
        }

        [Test]
        public void WasScriptCreatedThisSession_FailedCreate_ReturnsFalse()
        {
            // A create_script that FAILED should not flip the gate open —
            // there's no script for modify_script to legitimately edit.
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":false,\"error\":\"compile error\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession(TmpScript));
        }

        [Test]
        public void WasScriptCreatedThisSession_AssetsPrefixOptional_BothMatch()
        {
            // Caller may pass with or without Assets/ prefix on either side.
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            // Query without prefix should match the prefixed record.
            string withoutPrefix = TmpScript.Substring("Assets/".Length);
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(withoutPrefix));
        }

        [Test]
        public void WasScriptCreatedThisSession_CaseInsensitive_Matches()
        {
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(TmpScript.ToLowerInvariant()));
        }

        [Test]
        public void WasScriptCreatedThisSession_BackslashPath_Normalizes()
        {
            // Windows-style separators get normalized to forward slash.
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            string backslashed = TmpScript.Replace('/', '\\');
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(backslashed));
        }

        [Test]
        public void WasScriptCreatedThisSession_AfterReset_ReturnsFalse()
        {
            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(TmpScript));

            SessionTracker.Reset();
            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession(TmpScript));
        }

        // ── ModifyScriptTool gating ─────────────────────────────────────────

        [Test]
        public void ModifyScript_PreExistingWithoutFlag_Refused()
        {
            // Pre-create the script on disk WITHOUT recording it via SessionTracker —
            // simulates a real project script the agent didn't create this session.
            File.WriteAllText(TmpScript, MinimalContent);
            AssetDatabase.ImportAsset(TmpScript);

            var tool = new ModifyScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ModifiedContent,
            });

            StringAssert.Contains("Refused to modify", result);
            StringAssert.Contains("preExistingScriptWithoutConfirmation", result);
            // Critical assertion: the file was NOT overwritten.
            Assert.AreEqual(MinimalContent, File.ReadAllText(TmpScript),
                "Refused modify_script must not touch the file on disk.");
        }

        [Test]
        public void ModifyScript_PreExistingWithFlag_Allowed()
        {
            // Same setup, but the caller acknowledges the modification.
            File.WriteAllText(TmpScript, MinimalContent);
            AssetDatabase.ImportAsset(TmpScript);

            var tool = new ModifyScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ModifiedContent,
                ["confirmExistingFileModification"] = true,
            });

            StringAssert.Contains("Modified", result);
            Assert.AreEqual(ModifiedContent, File.ReadAllText(TmpScript),
                "Acknowledged modify_script must write the new content.");
        }

        [Test]
        public void ModifyScript_CreatedThisSessionWithoutFlag_Allowed()
        {
            // Pre-create the script AND record a successful create_script —
            // simulates the normal in-session flow: model calls create_script,
            // then later modifies the same path. Should not need the flag.
            File.WriteAllText(TmpScript, MinimalContent);
            AssetDatabase.ImportAsset(TmpScript);

            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            var tool = new ModifyScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ModifiedContent,
            });

            StringAssert.Contains("Modified", result);
            Assert.AreEqual(ModifiedContent, File.ReadAllText(TmpScript));
        }

        [Test]
        public void ModifyScript_NonexistentFile_FailsBeforeSafetyCheck()
        {
            // Order of operations matters: a script that doesn't exist at all
            // should produce the "does not exist" error, not the safety refusal.
            // (Confirms the safety gate runs AFTER the file-exists check so the
            // model gets the actionable error first.)
            var tool = new ModifyScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ModifiedContent,
            });

            StringAssert.Contains("does not exist", result);
            StringAssert.DoesNotContain("Refused to modify", result);
        }
    }
}
