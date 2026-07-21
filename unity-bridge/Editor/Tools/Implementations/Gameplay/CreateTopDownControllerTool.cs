using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Core.Tools.Implementations.Physics2D;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    // Sibling sub-namespaces `...Implementations.GameObject` and `...Camera`
    // shadow the bare type names; alias inside the namespace body so they bind to
    // the Unity types (same gotcha the third-person controller documents).
    using GameObject = UnityEngine.GameObject;
    using Camera = UnityEngine.Camera;

    /// <summary>
    /// Produces a complete, playable TOP-DOWN 2D PLAYER (Zelda-like) in ONE
    /// call — it completes the vetted controller trio (third-person 3D,
    /// side-scrolling platformer, top-down). It copies the vetted
    /// TopDownController2D script (8-direction Rigidbody2D movement, normalized
    /// diagonals, zero gravity) VERBATIM plus a Camera2DFollow that tracks the
    /// player, then assembles the 2D scene around them: a sprite Player with a
    /// Rigidbody2D (gravity zeroed, rotation frozen) + BoxCollider2D and an
    /// ORTHOGRAPHIC Main Camera.
    ///
    /// Why a template tool: an AI client asked to write a top-down controller
    /// tends to re-derive subtly-broken movement — most commonly unnormalized
    /// diagonals (moving diagonally is ~1.41x faster) and a forgotten
    /// gravityScale (the character slides off-screen the moment Play starts).
    /// The vetted script fixes both. A follow camera ships by default because a
    /// top-down player roams in every direction and leaves a static frame in
    /// seconds — the 2D platformer's fixed camera doesn't translate here.
    ///
    /// ATOMIC but DEFERRED, like the other gameplay scaffolders: it writes the
    /// scripts and builds the scene now, then QUEUES TopDownController2D (with
    /// moveSpeed) and Camera2DFollow to attach on the next compile — a
    /// MonoBehaviour can't be AddComponent'd until its script compiles and a
    /// domain reload loads the assembly. The caller's only remaining step is to
    /// call compile_scripts and wait until status='idle'.
    /// </summary>
    public class CreateTopDownControllerTool : ITool
    {
        public string Name => "create_top_down_controller";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string playerName = ToolUtils.GetStringArg(args, "playerName", "Player");
            if (string.IsNullOrEmpty(playerName)) playerName = "Player";
            float moveSpeed = Mathf.Max(0f, ToolUtils.GetFloatArg(args, "moveSpeed", 6f));
            bool followCamera = ToolUtils.GetBoolArg(args, "followCamera", true);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Vetted scripts (reuse-don't-refuse: many callers rebuild the scene
            // without wanting the shared scripts clobbered).
            string scriptErr = GameplayScaffold.WriteVettedScript(
                "TopDownController2D.cs.txt", "TopDownController2D.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            var createdScripts = new List<string> { scriptPath };
            if (followCamera)
            {
                string camErr = GameplayScaffold.WriteVettedScript(
                    "Camera2DFollow.cs.txt", "Camera2DFollow.cs", dir, confirmOverwrite, out string camScriptPath);
                if (!string.IsNullOrEmpty(camErr)) return ToolUtils.CreateErrorResponse(camErr);
                createdScripts.Add(camScriptPath);
            }

            var notes = new List<string>();

            GameObject player = EnsurePlayer(playerName, notes, out string playerErr);
            if (!string.IsNullOrEmpty(playerErr)) return ToolUtils.CreateErrorResponse(playerErr);

            GameObject camera = EnsureCamera2D(notes);

            var wiring = new List<PendingControllerWiring.WiringRequest>
            {
                new PendingControllerWiring.WiringRequest(
                    player.name, "Player", "TopDownController2D",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("moveSpeed", "float", moveSpeed.ToString(CultureInfo.InvariantCulture)),
                    }),
            };
            if (followCamera)
            {
                wiring.Add(new PendingControllerWiring.WiringRequest(camera.name, "MainCamera", "Camera2DFollow"));
            }
            PendingControllerWiring.Queue(wiring);

            try { EditorSceneManager.MarkSceneDirty(player.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var queued = new List<string> { $"TopDownController2D → {player.name}" };
            if (followCamera) queued.Add($"Camera2DFollow → {camera.name}");

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", createdScripts },
                { "requiresCompilation", true },
                { "playerObject", player.name },
                { "cameraObject", camera.name },
                { "moveSpeed", moveSpeed },
                { "queuedComponents", queued },
                { "sceneSetup", notes },
                {
                    "wiring",
                    "Automatic — this tool created the sprite Player (Rigidbody2D with zero gravity + BoxCollider2D) " +
                    "and an orthographic Main Camera, then queued TopDownController2D" +
                    (followCamera ? " + Camera2DFollow" : "") + " to attach the moment the scripts compile. " +
                    (followCamera
                        ? "Camera2DFollow self-resolves the 'Player' tag, so no object-reference wiring is needed."
                        : "No object-reference wiring is needed.")
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a complete, playable top-down 2D player in '{dir}'. This tool is ATOMIC — it wrote the " +
                "vetted TopDownController2D script" + (followCamera ? " and a Camera2DFollow" : "") + ", built a " +
                "sprite Player with a Rigidbody2D (gravity zeroed, rotation frozen) + BoxCollider2D, added an " +
                "orthographic Main Camera, and QUEUED the component" + (followCamera ? "s" : "") + " to attach as " +
                "soon as the scripts compile. DO NOT call add_component — that happens for you on the next compile. " +
                "Your ONLY remaining step is to call compile_scripts and wait until status='idle'; after that the " +
                "player moves in 8 directions with WASD/arrows" + (followCamera ? " and the camera follows" : "") + ". " +
                "Placeholder sprites are used — swap in real art on the SpriteRenderers when you like. For a " +
                "collectible/hazard loop, call create_game_manager, create_collectible and create_hazard with " +
                "dimension=\"2d\".",
                extras);
        }

        // ── Scene assembly (built-in / 2D-physics types only — safe to run now) ──

        /// <summary>Returns the existing Player (by 'Player' tag, then by name) or
        /// creates a sprite one. Either way it ends up with a Rigidbody2D (dynamic,
        /// gravity zeroed, rotation frozen) and a BoxCollider2D — the movement
        /// script's physics contract, added now since both are built-in types.
        /// Refuses if the target already carries 3D physics (Unity blocks mixing
        /// 2D and 3D on one object).</summary>
        private static GameObject EnsurePlayer(string playerName, List<string> notes, out string error)
        {
            error = "";
            GameObject player = FindByTag("Player") ?? GameObject.Find(playerName);
            if (player == null)
            {
                player = new GameObject(playerName);
                var sr = player.AddComponent<SpriteRenderer>();
                var sprite = GameplayScaffold.LoadOrCreatePlaceholderSprite(out string spriteErr);
                if (sprite != null)
                {
                    sr.sprite = sprite;
                    sr.color = new Color(0.30f, 0.60f, 0.95f); // obviously-placeholder blue
                }
                else if (!string.IsNullOrEmpty(spriteErr))
                {
                    notes.Add(spriteErr); // non-fatal: object still gets physics + a collider
                }
                player.transform.position = Vector3.zero;
                Undo.RegisterCreatedObjectUndo(player, "Create Player");
                notes.Add($"created sprite Player '{playerName}' at (0,0,0)");
            }
            else
            {
                notes.Add($"reused existing player '{player.name}'");
            }

            string blocker = Physics2DUtils.Describe3DPhysicsBlocker(player);
            if (blocker != null)
            {
                error = $"'{player.name}' already has {blocker}. Unity can't mix 2D and 3D physics on one object — " +
                        "remove the 3D component, or pass a different playerName so a fresh 2D player is built.";
                return null;
            }

            TrySetTag(player, "Player");

            var rb = player.GetComponent<Rigidbody2D>();
            if (rb == null)
            {
                rb = player.AddComponent<Rigidbody2D>();
                notes.Add("added Rigidbody2D to player");
            }
            // The template's Awake enforces both too, but set them now so the
            // editor-time inspector state matches what Play mode will run with.
            rb.gravityScale = 0f;
            rb.freezeRotation = true;

            if (player.GetComponent<Collider2D>() == null)
            {
                player.AddComponent<BoxCollider2D>();
                notes.Add("added BoxCollider2D to player");
            }

            return player;
        }

        /// <summary>Ensures the Main Camera exists and is orthographic (2D),
        /// framed on the origin from -Z. Returns the camera GameObject so the
        /// follow component can be queued onto it.</summary>
        private static GameObject EnsureCamera2D(List<string> notes)
        {
            Camera cam = Camera.main;
            if (cam == null)
            {
                cam = UnityEngine.Object.FindFirstObjectByType<Camera>();
                if (cam != null)
                {
                    TrySetTag(cam.gameObject, "MainCamera");
                    notes.Add($"tagged existing camera '{cam.gameObject.name}' as MainCamera");
                }
            }

            if (cam == null)
            {
                var camGo = new GameObject("Main Camera");
                cam = camGo.AddComponent<Camera>();
                camGo.AddComponent<AudioListener>();
                TrySetTag(camGo, "MainCamera");
                Undo.RegisterCreatedObjectUndo(camGo, "Create Main Camera");
                notes.Add("created a Main Camera (scene had none)");
            }
            else
            {
                notes.Add($"reused Main Camera '{cam.gameObject.name}'");
            }

            cam.orthographic = true;
            cam.orthographicSize = 5f;
            cam.transform.position = new Vector3(0f, 0f, -10f);
            cam.transform.rotation = Quaternion.identity;
            return cam.gameObject;
        }

        private static GameObject FindByTag(string tag)
        {
            try { return GameObject.FindWithTag(tag); }
            catch { return null; } // tag not defined in this project
        }

        private static void TrySetTag(GameObject go, string tag)
        {
            try { go.tag = tag; }
            catch { /* tag not defined — the scripts also fall back to name lookup */ }
        }
    }
}
