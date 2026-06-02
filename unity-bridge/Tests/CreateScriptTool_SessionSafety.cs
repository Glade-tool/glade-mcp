using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for the session-aware create_script overwrite gate. Sibling
    /// hole to ModifyScriptTool_SessionSafety: previously a model could
    /// clobber any real project script by calling create_script with a
    /// colliding path. Demonstrated 2026-06-01 — a trial's create_script
    /// overwrote ThirdPersonCameraFollow.cs (151 lines → 21 lines).
    ///
    /// Contract under test: create_script against a path that already
    /// exists on disk AND was not created in the current Unity session
    /// is REFUSED unless the caller explicitly passes
    /// confirmExistingFileModification=true. The flag name matches the
    /// modify_script gate so the agent only learns one pattern.
    public class CreateScriptTool_SessionSafety
    {
        private const string TmpDir = "Assets/_TmpCreateSessionSafety";
        private const string TmpScript = "Assets/_TmpCreateSessionSafety/Probe.cs";
        private const string RealUserContent = "public class Probe { public int existingField = 42; }\n";
        private const string ScaffoldContent = "public class Probe { }\n";
        private const string RegeneratedContent = "public class Probe { public string regen; }\n";

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

        // ── Refusal cases ───────────────────────────────────────────────────

        [Test]
        public void CreateScript_OverwritesExistingFileWithoutFlag_Refused()
        {
            // Pre-create the script on disk WITHOUT recording it via SessionTracker —
            // simulates a real project script the agent didn't create this session.
            File.WriteAllText(TmpScript, RealUserContent);
            AssetDatabase.ImportAsset(TmpScript);

            var tool = new CreateScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ScaffoldContent,
            });

            StringAssert.Contains("Refused to overwrite", result);
            StringAssert.Contains("preExistingScriptWithoutConfirmation", result);
            // Critical assertion: the file was NOT overwritten.
            Assert.AreEqual(RealUserContent, File.ReadAllText(TmpScript),
                "Refused create_script must not touch the file on disk.");
        }

        // ── Allowed cases ───────────────────────────────────────────────────

        [Test]
        public void CreateScript_NewPath_Allowed()
        {
            // The happy path: target doesn't exist yet → create freely, no flag needed.
            Assert.IsFalse(File.Exists(TmpScript));

            var tool = new CreateScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = ScaffoldContent,
            });

            StringAssert.Contains("Created", result);
            Assert.IsTrue(File.Exists(TmpScript));
            Assert.AreEqual(ScaffoldContent, File.ReadAllText(TmpScript));
        }

        [Test]
        public void CreateScript_OverwritesExistingFileWithFlag_Allowed()
        {
            // Same refusal setup, but the caller acknowledges the overwrite.
            File.WriteAllText(TmpScript, RealUserContent);
            AssetDatabase.ImportAsset(TmpScript);

            var tool = new CreateScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = RegeneratedContent,
                ["confirmExistingFileModification"] = true,
            });

            StringAssert.Contains("Created", result);
            Assert.AreEqual(RegeneratedContent, File.ReadAllText(TmpScript),
                "Acknowledged create_script must write the new content.");
        }

        [Test]
        public void CreateScript_CreatedThisSessionWithoutFlag_Allowed()
        {
            // Regenerate-from-scratch flow: the model already called create_script
            // earlier this session for this path. A second create_script against
            // the same path should not need the flag — the agent is operating on
            // its own scaffold, not user code.
            File.WriteAllText(TmpScript, ScaffoldContent);
            AssetDatabase.ImportAsset(TmpScript);

            string argsJson = "{\"scriptPath\":\"" + TmpScript + "\"}";
            string resultJson = "{\"success\":true,\"scriptPath\":\"" + TmpScript + "\"}";
            SessionTracker.Record("create_script", argsJson, resultJson);

            var tool = new CreateScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptPath"] = TmpScript,
                ["scriptContent"] = RegeneratedContent,
            });

            StringAssert.Contains("Created", result);
            Assert.AreEqual(RegeneratedContent, File.ReadAllText(TmpScript));
        }

        // ── Ordering: argument validation runs before the safety gate ───────

        [Test]
        public void CreateScript_MissingScriptPath_FailsBeforeSafetyCheck()
        {
            // A missing required arg should produce the "scriptPath is required"
            // error, not the safety refusal — keeps actionable validation errors
            // surfaced first.
            var tool = new CreateScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["scriptContent"] = ScaffoldContent,
            });

            StringAssert.Contains("scriptPath is required", result);
            StringAssert.DoesNotContain("Refused to overwrite", result);
        }
    }
}
