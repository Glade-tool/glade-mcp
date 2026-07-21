using System.Collections.Generic;
using System.IO;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.SceneManagement;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Gameplay;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for create_top_down_controller — the ATOMIC template tool that
    /// completes the vetted controller trio (third-person 3D, side-scrolling
    /// platformer, top-down 2D). It copies TopDownController2D.cs + the
    /// Camera2DFollow.cs follow camera into the project VERBATIM, AND assembles
    /// the 2D scene around them.
    ///
    /// Contracts under test:
    ///   1. Both scripts are written, content byte-identical to the bundled
    ///      templates (verbatim — the whole point of the tool).
    ///   2. Reuse-don't-refuse: a pre-existing script is REUSED (not clobbered,
    ///      no error) unless the caller explicitly confirms regeneration.
    ///   3. ATOMIC 2D scene assembly: a sprite Player with a Rigidbody2D
    ///      (gravity zeroed, rotation frozen) + BoxCollider2D and an
    ///      orthographic Main Camera exist after the call, and the custom
    ///      MonoBehaviours are QUEUED for post-compile attachment.
    ///   4. The caller's Player is reused, not duplicated, and a Player that
    ///      already carries 3D physics is refused (Unity can't mix 2D + 3D).
    ///   5. followCamera=false skips the camera script + its wiring.
    public class CreateTopDownControllerTool_Tests
    {
        private const string TmpDir = "Assets/_TmpTdcTest";
        private const string ControllerPath = "Assets/_TmpTdcTest/TopDownController2D.cs";
        private const string CameraPath = "Assets/_TmpTdcTest/Camera2DFollow.cs";
        private const string RealUserContent = "public class TopDownController2D { int keep = 1; }\n";

        private HashSet<GameObject> _preExistingRoots;

        [SetUp]
        public void SetUp()
        {
            SessionTracker.Reset();
            PendingControllerWiring.Clear();
            if (!Directory.Exists(TmpDir))
            {
                Directory.CreateDirectory(TmpDir);
                AssetDatabase.Refresh(ImportAssetOptions.Default);
            }
            _preExistingRoots = new HashSet<GameObject>(
                SceneManager.GetActiveScene().GetRootGameObjects());
        }

        [TearDown]
        public void TearDown()
        {
            foreach (var go in SceneManager.GetActiveScene().GetRootGameObjects())
            {
                if (!_preExistingRoots.Contains(go))
                {
                    Object.DestroyImmediate(go);
                }
            }
            if (Directory.Exists(TmpDir))
            {
                AssetDatabase.DeleteAsset(TmpDir);
            }
            SessionTracker.Reset();
            PendingControllerWiring.Clear();
        }

        // ── Happy path + verbatim integrity ─────────────────────────────────

        [Test]
        public void Create_NewDirectory_WritesBothScriptsVerbatim()
        {
            var tool = new CreateTopDownControllerTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["directory"] = TmpDir,
            });

            StringAssert.Contains("top-down 2D player", result);
            Assert.IsTrue(File.Exists(ControllerPath), "TopDownController2D.cs should be written");
            Assert.IsTrue(File.Exists(CameraPath), "Camera2DFollow.cs should be written");

            string controllerTemplate = ToolUtils.ResolveTemplatePath("TopDownController2D.cs.txt");
            string cameraTemplate = ToolUtils.ResolveTemplatePath("Camera2DFollow.cs.txt");
            Assert.IsNotNull(controllerTemplate, "controller template must resolve");
            Assert.IsNotNull(cameraTemplate, "camera template must resolve");
            Assert.AreEqual(File.ReadAllText(controllerTemplate), File.ReadAllText(ControllerPath));
            Assert.AreEqual(File.ReadAllText(cameraTemplate), File.ReadAllText(CameraPath));
        }

        [Test]
        public void Create_MarksScriptsSessionCreated()
        {
            var tool = new CreateTopDownControllerTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(ControllerPath),
                "controller must be marked session-created so modify_script isn't refused");
            Assert.IsTrue(SessionTracker.WasScriptCreatedThisSession(CameraPath),
                "camera follow must be marked session-created");
        }

        // ── Atomic 2D scene assembly ────────────────────────────────────────

        [Test]
        public void Create_BuildsTopDownPlayer_AndQueuesWiring()
        {
            var tool = new CreateTopDownControllerTool();
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            var player = GameObject.Find("Player");
            Assert.IsNotNull(player, "tool must create a Player when the scene has none");

            var rb = player.GetComponent<Rigidbody2D>();
            Assert.IsNotNull(rb, "Player must get a Rigidbody2D immediately (built-in type)");
            Assert.AreEqual(0f, rb.gravityScale, "top-down player must not fall (gravityScale 0)");
            Assert.IsTrue(rb.freezeRotation, "top-down player must not tip over");
            Assert.IsNotNull(player.GetComponent<BoxCollider2D>(), "Player must get a BoxCollider2D");
            Assert.AreEqual("Player", player.tag, "Player must be tagged so Camera2DFollow self-resolves it");

            Assert.IsNotNull(Camera.main, "tool must ensure a Main Camera exists");
            Assert.IsTrue(Camera.main.orthographic, "2D camera must be orthographic");

            Assert.IsTrue(PendingControllerWiring.HasPending,
                "TopDownController2D + Camera2DFollow must be queued for deferred wiring");
            StringAssert.Contains("ATOMIC", result);
            StringAssert.Contains("compile_scripts", result);
        }

        [Test]
        public void Create_FollowCameraFalse_SkipsCameraScriptAndWiring()
        {
            var tool = new CreateTopDownControllerTool();
            string result = tool.Execute(new Dictionary<string, object>
            {
                ["directory"] = TmpDir,
                ["followCamera"] = false,
            });

            StringAssert.Contains("top-down 2D player", result);
            Assert.IsTrue(File.Exists(ControllerPath), "controller must still be written");
            Assert.IsFalse(File.Exists(CameraPath),
                "followCamera=false must not write the camera script");
            // No camera component queued and no mention of it in the reply.
            StringAssert.DoesNotContain("Camera2DFollow", result);
        }

        [Test]
        public void Create_ReusesExistingPlayer_NoDuplicate()
        {
            var existing = new GameObject("Player");

            var tool = new CreateTopDownControllerTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            int playerCount = 0;
            foreach (var go in Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None))
                if (go.name == "Player") playerCount++;
            Assert.AreEqual(1, playerCount, "existing Player must be reused, not duplicated");
            Assert.IsNotNull(existing.GetComponent<Rigidbody2D>(),
                "the reused Player must still get its Rigidbody2D");
            Assert.AreEqual(0f, existing.GetComponent<Rigidbody2D>().gravityScale,
                "the reused Player's gravity must be zeroed for top-down");
        }

        [Test]
        public void Create_PlayerWith3DPhysics_Refused()
        {
            var existing = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            existing.name = "Player";
            existing.AddComponent<Rigidbody>(); // 3D physics — can't mix with 2D

            var tool = new CreateTopDownControllerTool();
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            StringAssert.Contains("can't mix 2D and 3D physics", result);
            Assert.IsNull(existing.GetComponent<Rigidbody2D>(),
                "a refused call must not add 2D physics onto a 3D body");
        }

        // ── Reuse-don't-refuse on the shared scripts ────────────────────────

        [Test]
        public void Create_PreExistingScriptWithoutFlag_ReusedNotClobbered()
        {
            File.WriteAllText(ControllerPath, RealUserContent);
            AssetDatabase.ImportAsset(ControllerPath);

            var tool = new CreateTopDownControllerTool();
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            StringAssert.Contains("top-down 2D player", result);
            Assert.AreEqual(RealUserContent, File.ReadAllText(ControllerPath),
                "a pre-existing script must be reused as-is, not clobbered");
        }

        [Test]
        public void Create_PreExistingScriptWithFlag_Regenerated()
        {
            File.WriteAllText(ControllerPath, RealUserContent);
            AssetDatabase.ImportAsset(ControllerPath);

            var tool = new CreateTopDownControllerTool();
            tool.Execute(new Dictionary<string, object>
            {
                ["directory"] = TmpDir,
                ["confirmExistingFileModification"] = true,
            });

            string controllerTemplate = ToolUtils.ResolveTemplatePath("TopDownController2D.cs.txt");
            Assert.AreEqual(File.ReadAllText(controllerTemplate), File.ReadAllText(ControllerPath),
                "confirmed call must regenerate the vetted template");
        }
    }
}
