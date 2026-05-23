using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using GladeAgenticAI.Core.Tools.Implementations.Diagnostics;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for the per-trial evaluation state reset tool.
    ///
    /// Three sub-behaviors are independently testable:
    ///   1. Scene reset destroys root GameObjects except Main Camera and
    ///      Directional Light.
    ///   2. Scripts glob deletion ONLY operates under Assets/Scripts/ —
    ///      patterns outside that root are refused with a structured reason.
    ///   3. SessionTracker.Reset is called when clearSession=true.
    ///
    /// File system side effects use a dedicated Assets/_TmpResetState/ folder
    /// AND temporary scripts written under Assets/Scripts/ with a distinctive
    /// prefix so the tests can't collide with real project content.
    public class ResetEvalStateTool_Tests
    {
        private const string TmpFolder = "Assets/_TmpResetState";
        private const string ScriptsDir = "Assets/Scripts";
        private const string TestScriptPrefix = "_ResetToolTest_";

        // Track scripts we wrote so TearDown can clean them up even on
        // partial test failure.
        private readonly List<string> _writtenTestScripts = new List<string>();

        [SetUp]
        public void SetUp()
        {
            SessionTracker.Reset();
            if (!Directory.Exists(TmpFolder))
            {
                Directory.CreateDirectory(TmpFolder);
            }
            if (!Directory.Exists(ScriptsDir))
            {
                Directory.CreateDirectory(ScriptsDir);
            }
            AssetDatabase.Refresh(ImportAssetOptions.Default);
        }

        [TearDown]
        public void TearDown()
        {
            // Belt-and-suspenders: remove any test scripts left behind.
            foreach (var path in _writtenTestScripts)
            {
                if (File.Exists(path))
                {
                    AssetDatabase.DeleteAsset(path);
                }
            }
            _writtenTestScripts.Clear();

            if (Directory.Exists(TmpFolder))
            {
                AssetDatabase.DeleteAsset(TmpFolder);
            }
            SessionTracker.Reset();
        }

        private string WriteTestScript(string name)
        {
            string path = $"{ScriptsDir}/{TestScriptPrefix}{name}.cs";
            File.WriteAllText(path, "public class " + TestScriptPrefix + name + " { }\n");
            AssetDatabase.ImportAsset(path);
            _writtenTestScripts.Add(path);
            return path;
        }

        // ── Scene reset ─────────────────────────────────────────────────────

        [Test]
        public void Reset_ClearScene_DestroysRootGameObjectsExceptPreserved()
        {
            var keeper = new GameObject("Main Camera");
            var keeper2 = new GameObject("Directional Light");
            var victim = new GameObject("_ResetToolTest_Victim");

            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = true,
                ["clearSession"] = false,
            });

            StringAssert.Contains("\"sceneCleared\":true", result);
            StringAssert.Contains("_ResetToolTest_Victim", result);

            // Keepers survive; victim is gone.
            Assert.IsTrue(keeper != null && keeper);
            Assert.IsTrue(keeper2 != null && keeper2);
            Assert.IsTrue(victim == null || !victim, "Non-whitelisted root should be destroyed.");

            // Cleanup keepers for next test (also removes them from scene).
            if (keeper) UnityEngine.Object.DestroyImmediate(keeper);
            if (keeper2) UnityEngine.Object.DestroyImmediate(keeper2);
        }

        [Test]
        public void Reset_ClearSceneFalse_DoesNotTouchHierarchy()
        {
            var victim = new GameObject("_ResetToolTest_Survivor");

            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
            });

            StringAssert.Contains("\"sceneCleared\":false", result);
            Assert.IsTrue(victim != null && victim, "GameObject must survive when clearScene=false.");

            UnityEngine.Object.DestroyImmediate(victim);
        }

        [Test]
        public void Reset_ClearScene_DuplicatePreservedNames_KeepsOnlyOne()
        {
            // Regression guard: if a previous eval trial leaked an extra
            // "Main Camera" (e.g. via create_camera that didn't query for
            // an existing one first), the reset must collapse the
            // duplicates back to a single survivor — otherwise sequential
            // trials accumulate camera duplicates and the eval signal
            // degrades.
            var cam1 = new GameObject("Main Camera");
            var cam2 = new GameObject("Main Camera");
            var cam3 = new GameObject("Main Camera");
            var light = new GameObject("Directional Light");

            var tool = new ResetEvalStateTool();
            tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = true,
                ["clearSession"] = false,
            });

            // Exactly one "Main Camera" survives.
            var activeScene = SceneManager.GetActiveScene();
            int cameraCount = 0;
            foreach (var root in activeScene.GetRootGameObjects())
            {
                if (root != null && root.name == "Main Camera") cameraCount++;
            }
            Assert.AreEqual(1, cameraCount,
                "Whitelisted name should preserve exactly one GameObject, not all duplicates.");

            // Cleanup any survivor that's still around.
            foreach (var root in activeScene.GetRootGameObjects())
            {
                if (root != null && (root.name == "Main Camera" || root.name == "Directional Light"))
                {
                    UnityEngine.Object.DestroyImmediate(root);
                }
            }
        }

        // ── Scripts glob deletion ───────────────────────────────────────────

        [Test]
        public void Reset_ScriptsGlob_DeletesMatchingScripts()
        {
            string a = WriteTestScript("Alpha");
            string b = WriteTestScript("Bravo");

            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
                ["scriptsGlob"] = $"Assets/Scripts/{TestScriptPrefix}*.cs",
            });

            StringAssert.Contains("\"scriptsDeletedCount\":2", result);
            Assert.IsFalse(File.Exists(a), "Glob-matched script should be deleted.");
            Assert.IsFalse(File.Exists(b), "Glob-matched script should be deleted.");
        }

        [Test]
        public void Reset_ScriptsGlob_OutsideScriptsRoot_Refused()
        {
            // Pattern outside Assets/Scripts/ must produce a structured refusal,
            // never actually delete anything outside the allowed root.
            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
                ["scriptsGlob"] = "Assets/Materials/*.mat",
            });

            StringAssert.Contains("outsideScriptsRoot", result);
            StringAssert.Contains("\"scriptsDeletedCount\":0", result);
        }

        [Test]
        public void Reset_ScriptsGlob_CommaSeparatedPatterns_AllApplied()
        {
            string a = WriteTestScript("Alpha");
            string b = WriteTestScript("Bravo");
            string c = WriteTestScript("Charlie");

            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
                ["scriptsGlob"] = $"Assets/Scripts/{TestScriptPrefix}Alpha.cs,Assets/Scripts/{TestScriptPrefix}Bravo.cs",
            });

            StringAssert.Contains("\"scriptsDeletedCount\":2", result);
            Assert.IsFalse(File.Exists(a));
            Assert.IsFalse(File.Exists(b));
            Assert.IsTrue(File.Exists(c), "Charlie not in the glob list — should survive.");
        }

        [Test]
        public void Reset_ScriptsGlob_NonexistentDirectory_NoError()
        {
            // Glob pointing at an empty/nonexistent subdirectory returns
            // zero deletions, not an error — useful when the eval runs
            // against a project that hasn't had any prior trial yet.
            var tool = new ResetEvalStateTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
                ["scriptsGlob"] = "Assets/Scripts/_NoSuchDir/*.cs",
            });

            StringAssert.Contains("\"scriptsDeletedCount\":0", result);
            StringAssert.Contains("\"success\":true", result);
        }

        // ── Session timeline reset ──────────────────────────────────────────

        [Test]
        public void Reset_ClearSession_ResetsSessionTracker()
        {
            // Record a synthetic create_script so SessionTracker has something
            // to clear, then verify the reset wiped it.
            SessionTracker.Record(
                "create_script",
                "{\"scriptPath\":\"Assets/Scripts/SessionProbe.cs\"}",
                "{\"success\":true,\"scriptPath\":\"Assets/Scripts/SessionProbe.cs\"}"
            );
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession("Assets/Scripts/SessionProbe.cs"));

            var tool = new ResetEvalStateTool();
            tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = true,
            });

            Assert.IsFalse(SessionTracker.WasScriptCreatedThisSession("Assets/Scripts/SessionProbe.cs"),
                "clearSession=true must drop the session timeline.");
        }

        [Test]
        public void Reset_ClearSessionFalse_PreservesTimeline()
        {
            SessionTracker.Record(
                "create_script",
                "{\"scriptPath\":\"Assets/Scripts/SessionKeep.cs\"}",
                "{\"success\":true,\"scriptPath\":\"Assets/Scripts/SessionKeep.cs\"}"
            );

            var tool = new ResetEvalStateTool();
            tool.Execute(new Dictionary<string, object>
            {
                ["clearScene"] = false,
                ["clearSession"] = false,
            });

            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession("Assets/Scripts/SessionKeep.cs"),
                "clearSession=false must leave the timeline intact.");
        }
    }
}
