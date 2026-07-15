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
    /// Produces a complete, playable 2D SIDE-SCROLLING PLATFORMER PLAYER in ONE
    /// call — the 2D counterpart of create_third_person_controller. It copies the
    /// vetted PlatformerController2D script (Rigidbody2D run + grounded jump)
    /// VERBATIM, then assembles the 2D scene around it: a sprite Player with a
    /// Rigidbody2D (dynamic, rotation frozen) + BoxCollider2D, an ORTHOGRAPHIC
    /// Main Camera, and an optional static ground platform so the character has
    /// somewhere to land.
    ///
    /// Why a template tool: an AI client asked to write a 2D controller tends to
    /// re-derive subtly-broken movement — most commonly a mid-air jump (a
    /// collision-normal ground check done wrong) or a character that tips over
    /// (Rigidbody2D rotation left unfrozen). The vetted script fixes both.
    ///
    /// ATOMIC but DEFERRED, like the other gameplay scaffolders: it writes the
    /// script and builds the scene now, then QUEUES the PlatformerController2D
    /// component (with moveSpeed / jumpForce) to attach on the next compile — a
    /// MonoBehaviour can't be AddComponent'd until its script compiles and a
    /// domain reload loads the assembly. The caller's only remaining step is to
    /// call compile_scripts and wait until status='idle'.
    /// </summary>
    public class CreatePlatformerControllerTool : ITool
    {
        public string Name => "create_platformer_controller";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string playerName = ToolUtils.GetStringArg(args, "playerName", "Player");
            if (string.IsNullOrEmpty(playerName)) playerName = "Player";
            float moveSpeed = Mathf.Max(0f, ToolUtils.GetFloatArg(args, "moveSpeed", 7f));
            float jumpForce = Mathf.Max(0f, ToolUtils.GetFloatArg(args, "jumpForce", 12f));
            bool createGround = ToolUtils.GetBoolArg(args, "createGround", true);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Vetted script (reuse-don't-refuse: many callers rebuild the scene
            // without wanting the shared script clobbered).
            string scriptErr = GameplayScaffold.WriteVettedScript(
                "PlatformerController2D.cs.txt", "PlatformerController2D.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            var notes = new List<string>();

            GameObject player = EnsurePlayer(playerName, notes, out string playerErr);
            if (!string.IsNullOrEmpty(playerErr)) return ToolUtils.CreateErrorResponse(playerErr);

            EnsureCamera2D(notes);
            if (createGround) EnsureGround(notes);

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    player.name, "Player", "PlatformerController2D",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("moveSpeed", "float", moveSpeed.ToString(CultureInfo.InvariantCulture)),
                        new PendingControllerWiring.FieldValue("jumpForce", "float", jumpForce.ToString(CultureInfo.InvariantCulture)),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(player.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "playerObject", player.name },
                { "moveSpeed", moveSpeed },
                { "jumpForce", jumpForce },
                { "queuedComponents", new List<string> { $"PlatformerController2D → {player.name}" } },
                { "sceneSetup", notes },
                {
                    "wiring",
                    "Automatic — this tool created the sprite Player (Rigidbody2D + BoxCollider2D), an " +
                    "orthographic Main Camera, and (optionally) a ground platform, then queued " +
                    "PlatformerController2D to attach the moment the script compiles. No object-reference wiring needed."
                },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a complete, playable 2D platformer player in '{dir}'. This tool is ATOMIC — it wrote the " +
                "vetted PlatformerController2D script, built a sprite Player with a Rigidbody2D + BoxCollider2D, added " +
                "an orthographic Main Camera" + (createGround ? " and a ground platform" : "") + ", and QUEUED " +
                "PlatformerController2D to attach as soon as the script compiles. DO NOT call add_component — that " +
                "happens for you on the next compile. Your ONLY remaining step is to call compile_scripts and wait " +
                "until status='idle'; after that the player runs with A/D (or arrows) and jumps with Space. Placeholder " +
                "sprites are used — swap in real art on the SpriteRenderers when you like. For a collectible/hazard loop, " +
                "call create_game_manager, create_collectible and create_hazard with dimension=\"2d\".",
                extras);
        }

        // ── Scene assembly (built-in / 2D-physics types only — safe to run now) ──

        /// <summary>Returns the existing Player (by 'Player' tag, then by name) or
        /// creates a sprite one. Either way it ends up with a Rigidbody2D (dynamic,
        /// rotation frozen) and a BoxCollider2D — the movement script's physics
        /// contract, added now since both are built-in types. Refuses if the target
        /// already carries 3D physics (Unity blocks mixing 2D and 3D on one object).</summary>
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
                player.transform.position = new Vector3(0f, 1f, 0f);
                Undo.RegisterCreatedObjectUndo(player, "Create Player");
                notes.Add($"created sprite Player '{playerName}' at (0,1,0)");
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
            rb.freezeRotation = true; // don't let the character tip over

            if (player.GetComponent<Collider2D>() == null)
            {
                player.AddComponent<BoxCollider2D>();
                notes.Add("added BoxCollider2D to player");
            }

            return player;
        }

        /// <summary>Ensures the Main Camera is orthographic (2D). Retags/creates as
        /// needed, then flips it to orthographic and frames the origin from -Z.</summary>
        private static void EnsureCamera2D(List<string> notes)
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
            cam.transform.position = new Vector3(0f, 2f, -10f);
            cam.transform.rotation = Quaternion.identity;
        }

        /// <summary>Creates a wide static ground platform (sprite + BoxCollider2D) if
        /// the scene has nothing floor-like, so a standalone call yields a character
        /// that can stand somewhere.</summary>
        private static void EnsureGround(List<string> notes)
        {
            if (SceneHasGround()) return;

            var ground = new GameObject("Ground");
            var sr = ground.AddComponent<SpriteRenderer>();
            var sprite = GameplayScaffold.LoadOrCreatePlaceholderSprite(out _);
            if (sprite != null)
            {
                sr.sprite = sprite;
                sr.color = new Color(0.35f, 0.30f, 0.28f); // earthy placeholder
            }
            ground.transform.position = new Vector3(0f, -2f, 0f);
            ground.transform.localScale = new Vector3(30f, 1f, 1f); // 1-unit sprite → 30-wide slab
            ground.AddComponent<BoxCollider2D>();
            Undo.RegisterCreatedObjectUndo(ground, "Create Ground");
            notes.Add("created a static ground platform (scene had none)");
        }

        private static bool SceneHasGround()
        {
            foreach (var go in UnityEngine.Object.FindObjectsByType<GameObject>(FindObjectsSortMode.None))
            {
                string n = go.name.ToLowerInvariant();
                if (n.Contains("ground") || n.Contains("floor") || n.Contains("platform"))
                    return true;
            }
            return false;
        }

        private static GameObject FindByTag(string tag)
        {
            try { return GameObject.FindWithTag(tag); }
            catch { return null; } // tag not defined in this project
        }

        private static void TrySetTag(GameObject go, string tag)
        {
            try { go.tag = tag; }
            catch { /* tag not defined — the collectible/hazard scripts also fall back to name lookup */ }
        }
    }
}
