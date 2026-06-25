using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.TestTools;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Scripts;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Coverage for create_third_person_controller — the ATOMIC template tool.
    /// It copies two Play-tested gameplay scripts (ThirdPersonController.cs +
    /// FollowCamera.cs) into the project VERBATIM, AND assembles the scene around
    /// them so the caller never has to issue follow-up add_component calls.
    ///
    /// Contracts under test:
    ///   1. Both scripts are written, content byte-identical to the bundled
    ///      templates (verbatim — the whole point of the tool).
    ///   2. The session-aware overwrite guard mirrors create_script: a pre-existing
    ///      file not created this session is refused, ATOMICALLY (no partial write,
    ///      and — since the guard runs first — no scene objects created either).
    ///   3. The confirm flag allows the overwrite.
    ///   4. Written scripts are marked session-created.
    ///   5. ATOMIC scene assembly: a Player capsule (with CharacterController +
    ///      'Player' tag) and a Main Camera exist after the call, and the two
    ///      custom MonoBehaviours are QUEUED for post-compile attachment.
    ///   6. The caller's Player/Camera are reused, not duplicated, when present.
    public class CreateThirdPersonControllerTool_Tests
    {
        private const string TmpDir = "Assets/_TmpTpcTest";
        private const string ControllerPath = "Assets/_TmpTpcTest/ThirdPersonController.cs";
        private const string CameraPath = "Assets/_TmpTpcTest/FollowCamera.cs";
        private const string RealUserContent = "public class ThirdPersonController { int keep = 1; }\n";

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
            // Snapshot the scene so TearDown can remove anything the tool spawns
            // (Player capsule / Main Camera / Ground plane) without touching
            // objects the test runner's scene already had.
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

        // ── Atomic scene assembly ───────────────────────────────────────────

        [Test]
        public void Create_BuildsPlayerWithCharacterController_AndQueuesWiring()
        {
            var tool = new CreateThirdPersonControllerScriptTool();
            string result = tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            var player = GameObject.Find("Player");
            Assert.IsNotNull(player, "tool must create a Player when the scene has none");
            Assert.IsNotNull(player.GetComponent<CharacterController>(),
                "Player must get a CharacterController immediately (built-in type)");
            Assert.AreEqual("Player", player.tag, "Player must be tagged so the camera self-resolves it");

            Assert.IsNotNull(Camera.main, "tool must ensure a Main Camera exists");

            // The two custom MonoBehaviours can't be added until the scripts
            // compile, so they must be QUEUED for post-compile attachment.
            Assert.IsTrue(PendingControllerWiring.HasPending,
                "ThirdPersonController + FollowCamera must be queued for deferred wiring");
            StringAssert.Contains("ATOMIC", result);
            StringAssert.Contains("compile_scripts", result);
        }

        [Test]
        public void Create_ReusesExistingPlayer_NoDuplicate()
        {
            // Caller built the Player first (the common multi-system order).
            var existing = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            existing.name = "Player";

            var tool = new CreateThirdPersonControllerScriptTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            int playerCount = 0;
            foreach (var go in Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None))
                if (go.name == "Player") playerCount++;
            Assert.AreEqual(1, playerCount, "existing Player must be reused, not duplicated");
            Assert.IsNotNull(existing.GetComponent<CharacterController>(),
                "the reused Player must still get its CharacterController");
        }

        [Test]
        public void Create_SkipsGround_WhenSceneAlreadyHasFloor()
        {
            var floor = GameObject.CreatePrimitive(PrimitiveType.Plane);
            floor.name = "Ground";

            var tool = new CreateThirdPersonControllerScriptTool();
            tool.Execute(new Dictionary<string, object> { ["directory"] = TmpDir });

            int groundCount = 0;
            foreach (var go in Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None))
                if (go.name == "Ground") groundCount++;
            Assert.AreEqual(1, groundCount, "must not add a second ground when one exists");
        }

        // ── Overwrite guard (atomic — runs before any write OR scene change) ──

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
            // ...and the guard runs BEFORE scene assembly, so nothing was spawned.
            Assert.IsNull(GameObject.Find("Player"),
                "a refused call must not create scene objects");
            Assert.IsFalse(PendingControllerWiring.HasPending,
                "a refused call must not queue any wiring");
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

    /// Coverage for PendingControllerWiring — the deferred-attachment driver that
    /// closes the gap between "scripts written" and "MonoBehaviour types loaded".
    /// Tested directly (with a built-in component type so resolution is
    /// deterministic) rather than by staging a real domain reload.
    public class PendingControllerWiring_Tests
    {
        private GameObject _go;

        [SetUp]
        public void SetUp()
        {
            PendingControllerWiring.Clear();
            _go = new GameObject("WiringTarget");
        }

        [TearDown]
        public void TearDown()
        {
            if (_go != null) Object.DestroyImmediate(_go);
            PendingControllerWiring.Clear();
        }

        [Test]
        public void TryComplete_AttachesResolvableComponent_AndClears()
        {
            PendingControllerWiring.Queue(new[]
            {
                // Rigidbody is built-in, so FindComponentType resolves it now —
                // standing in for the post-compile-resolvable ThirdPersonController.
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody"),
            });
            Assert.IsTrue(PendingControllerWiring.HasPending);

            PendingControllerWiring.TryComplete();

            Assert.IsNotNull(_go.GetComponent<Rigidbody>(),
                "a resolvable queued component must be attached");
            Assert.IsFalse(PendingControllerWiring.HasPending,
                "the queue must clear once every entry's type resolves");
        }

        [Test]
        public void TryComplete_KeepsQueue_WhenTypeNotYetCompiled()
        {
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "NoSuchComponentType_Xyz"),
            });

            PendingControllerWiring.TryComplete();

            Assert.IsTrue(PendingControllerWiring.HasPending,
                "an unresolved type means the scripts haven't compiled yet — keep waiting");
        }

        [Test]
        public void TryComplete_GivesUp_AfterRepeatedFailures()
        {
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "NoSuchComponentType_Xyz"),
            });

            // A compile failure would never produce the type; the driver must
            // self-clear instead of re-firing forever on every later reload.
            for (int i = 0; i < 10 && PendingControllerWiring.HasPending; i++)
            {
                PendingControllerWiring.TryComplete();
            }

            Assert.IsFalse(PendingControllerWiring.HasPending,
                "the queue must give up and clear after the attempt cap");
        }

        [Test]
        public void TryComplete_ResolvesAndClears_WhenTargetMissing()
        {
            PendingControllerWiring.Queue(new[]
            {
                // Type resolves (Rigidbody) but the object doesn't exist — nothing
                // to attach, and it must NOT loop forever.
                new PendingControllerWiring.WiringRequest("GhostObject_DoesNotExist", null, "Rigidbody"),
            });

            PendingControllerWiring.TryComplete();

            Assert.IsFalse(PendingControllerWiring.HasPending,
                "a resolvable-type/missing-object entry must clear, not loop");
        }

        [Test]
        public void Queue_Accumulates_AcrossSeparateCalls()
        {
            // Models the real flow: one scaffolder queues its component, then a
            // SECOND scaffolder queues a different one before the single compile
            // that wires them all. The second call must NOT clobber the first.
            var go2 = new GameObject("WiringTarget2");
            try
            {
                PendingControllerWiring.Queue(new[]
                {
                    new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody"),
                });
                PendingControllerWiring.Queue(new[]
                {
                    new PendingControllerWiring.WiringRequest("WiringTarget2", null, "BoxCollider"),
                });

                PendingControllerWiring.TryComplete();

                Assert.IsNotNull(_go.GetComponent<Rigidbody>(),
                    "the first scaffolder's queued component must survive a later Queue call");
                Assert.IsNotNull(go2.GetComponent<BoxCollider>(),
                    "the second scaffolder's component must attach too");
                Assert.IsFalse(PendingControllerWiring.HasPending,
                    "the merged queue must clear once every entry resolves");
            }
            finally
            {
                Object.DestroyImmediate(go2);
            }
        }

        [Test]
        public void ApplyFields_AppliesKnownFields_AndWarnsOnDroppedOnes()
        {
            // The reused-existing-class trap: a scaffolder queues its template's knobs
            // (here a real one + one the resolved class doesn't have). The real field
            // must still land, and the missing one must surface as a WARNING — not
            // vanish silently the way a bare "the elevator didn't move" bug does.
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("mass", "float", "7"),         // Rigidbody has this
                        new PendingControllerWiring.FieldValue("route", "string", "0,0,0;4,0,0"), // it does NOT
                    }),
            });

            // The dropped knob must be named in a warning (the actionable signal the
            // backend forwards). Match the field name to keep the assert robust to
            // copy tweaks.
            LogAssert.Expect(LogType.Warning, new Regex("route"));

            PendingControllerWiring.TryComplete();

            var rb = _go.GetComponent<Rigidbody>();
            Assert.IsNotNull(rb, "the component must still attach");
            Assert.AreEqual(7f, rb.mass,
                "a valid queued field must still apply even when a sibling field is dropped");
            Assert.IsFalse(PendingControllerWiring.HasPending, "the queue must clear");
        }

        [Test]
        public void ApplyFields_NoWarning_WhenEveryFieldResolves()
        {
            // The common case: the vetted template WAS written, so every queued knob
            // exists on the attached class. No warning should fire — the collision
            // signal must stay quiet unless there's an actual collision.
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("mass", "float", "3"),
                    }),
            });

            PendingControllerWiring.TryComplete();

            // The happy path must wire cleanly: the field lands and nothing errors.
            var rb = _go.GetComponent<Rigidbody>();
            Assert.IsNotNull(rb);
            Assert.AreEqual(3f, rb.mass);
        }

        [Test]
        public void Queue_DedupesSameAttachment_NewestFieldsWin()
        {
            // Re-queuing the same target+component (e.g. create_game_manager run
            // twice before a compile) must not stack duplicates; the latest call's
            // field values are the ones that take effect.
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody",
                    new System.Collections.Generic.List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("mass", "float", "5"),
                    }),
            });
            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest("WiringTarget", null, "Rigidbody",
                    new System.Collections.Generic.List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("mass", "float", "9"),
                    }),
            });

            PendingControllerWiring.TryComplete();

            var rb = _go.GetComponent<Rigidbody>();
            Assert.IsNotNull(rb, "the deduped attachment must still attach exactly once");
            Assert.AreEqual(9f, rb.mass,
                "the newest Queue call's field value must win (no stale first-call value)");
        }
    }
}
