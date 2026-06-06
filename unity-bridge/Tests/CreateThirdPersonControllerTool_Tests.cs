using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for create_third_person_controller — the template tool that copies
    /// two Play-tested gameplay scripts (ThirdPersonController.cs + FollowCamera.cs)
    /// into the project VERBATIM instead of letting the model re-derive them.
    ///
    /// Contracts under test:
    ///   1. Both scripts are written, with content byte-identical to the bundled
    ///      templates (verbatim — the whole point of the tool).
    ///   2. The session-aware overwrite guard mirrors create_script: a pre-existing
    ///      file not created this session is refused, and the refusal is ATOMIC
    ///      (no partial write of the other script).
    ///   3. The confirm flag allows the overwrite.
    ///   4. Written scripts are marked session-created, so a follow-up
    ///      create_script / modify_script on them is not refused by the guard.
    public class CreateThirdPersonControllerTool_Tests
    {
        private const string TmpDir = "Assets/_TmpTpcTest";
        private const string ControllerPath = "Assets/_TmpTpcTest/ThirdPersonController.cs";
        private const string CameraPath = "Assets/_TmpTpcTest/FollowCamera.cs";
        private const string RealUserContent = "public class ThirdPersonController { int keep = 1; }\n";

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

        private static IDictionary<string, object> Args(params (string, object)[] kv)
        {
            var d = new Dictionary<string, object>();
            foreach (var (k, v) in kv) d[k] = v;
            return d;
        }

        // ── Happy path + verbatim integrity ─────────────────────────────────

        [Test]
        public void Create_NewDirectory_WritesBothScriptsVerbatim()
        {
            var tool = new CreateThirdPersonControllerScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["directory"] = TmpDir,
            });

            StringAssert.Contains("third-person controller", result);
            Assert.IsTrue(File.Exists(ControllerPath), "ThirdPersonController.cs should be written");
            Assert.IsTrue(File.Exists(CameraPath), "FollowCamera.cs should be written");

            // Verbatim: written content must equal the bundled template exactly.
            string controllerTemplate = ToolUtils.ResolveTemplatePath("ThirdPersonController.cs.txt");
            string cameraTemplate = ToolUtils.ResolveTemplatePath("FollowCamera.cs.txt");
            Assert.IsNotNull(controllerTemplate, "controller template must resolve");
            Assert.IsNotNull(cameraTemplate, "camera template must resolve");
            Assert.AreEqual(File.ReadAllText(controllerTemplate), File.ReadAllText(ControllerPath));
            Assert.AreEqual(File.ReadAllText(cameraTemplate), File.ReadAllText(CameraPath));
        }

        [Test]
        public void Create_MarksScriptsSessionCreated()
        {
            var tool = new CreateThirdPersonControllerScriptTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(ControllerPath),
                "controller must be marked session-created so modify_script isn't refused");
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(CameraPath),
                "camera follow must be marked session-created");
        }

        // ── Overwrite guard (atomic) ────────────────────────────────────────

        [Test]
        public void Create_OverwritesExistingFileWithoutFlag_RefusedAtomically()
        {
            // Pre-create ONE of the two targets as untracked "user code".
            File.WriteAllText(ControllerPath, RealUserContent);
            AssetDatabase.ImportAsset(ControllerPath);

            var tool = new CreateThirdPersonControllerScriptTool();
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            StringAssert.Contains("Refused to overwrite", result);
            StringAssert.Contains("preExistingScriptWithoutConfirmation", result);
            // Untouched...
            Assert.AreEqual(RealUserContent, File.ReadAllText(ControllerPath),
                "refused call must not overwrite the existing file");
            // ...and ATOMIC: the other script must not have been written either.
            Assert.IsFalse(File.Exists(CameraPath),
                "refusal must be atomic — no partial write of the second script");
        }

        [Test]
        public void Create_OverwritesExistingFileWithFlag_Allowed()
        {
            File.WriteAllText(ControllerPath, RealUserContent);
            AssetDatabase.ImportAsset(ControllerPath);

            var tool = new CreateThirdPersonControllerScriptTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["directory"] = TmpDir,
                ["confirmExistingFileModification"] = true,
            });

            StringAssert.Contains("third-person controller", result);
            string controllerTemplate = ToolUtils.ResolveTemplatePath("ThirdPersonController.cs.txt");
            Assert.AreEqual(File.ReadAllText(controllerTemplate), File.ReadAllText(ControllerPath),
                "acknowledged call must overwrite with the vetted template");
            Assert.IsTrue(File.Exists(CameraPath));
        }

        [Test]
        public void Create_CreatedThisSessionWithoutFlag_Allowed()
        {
            // First call creates both (and marks them session-created).
            var tool = new CreateThirdPersonControllerScriptTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            // Second call against the same dir should not need the flag — the agent
            // is regenerating its own scaffold, not clobbering user code.
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });
            StringAssert.Contains("third-person controller", result);
            StringAssert.DoesNotContain("Refused to overwrite", result);
        }
    }
}
