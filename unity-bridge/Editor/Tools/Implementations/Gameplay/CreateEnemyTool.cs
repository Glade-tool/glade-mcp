using System.Collections.Generic;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Adds an ENEMY to the scene in ONE call: a visible capsule that chases the
    /// player across the ground and, on contact, costs the player a life via the
    /// GameManager. It carries Health too, so create_projectile can destroy it.
    /// The antagonist half of the combat loop.
    ///
    /// Why a template tool: a hand-written chaser commonly ships bugs — chasing the
    /// player's vertical position so it flies, or draining every life in one frame
    /// of contact. The vetted Enemy.cs chases on the ground plane and rate-limits
    /// its hits. It references GameManager + Health, so this tool ensures both
    /// contract scripts exist.
    ///
    /// ATOMIC but DEFERRED: builds the capsule (with a trigger collider + kinematic
    /// Rigidbody for reliable trigger hits) now, and QUEUES Enemy + Health to attach
    /// on the next compile. Call repeatedly for many enemies (each gets a unique name).
    /// </summary>
    public class CreateEnemyTool : ITool
    {
        public string Name => "create_enemy";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string baseName = ToolUtils.GetStringArg(args, "name", "Enemy");
            if (string.IsNullOrEmpty(baseName)) baseName = "Enemy";
            float moveSpeed = Mathf.Max(0f, ToolUtils.GetFloatArg(args, "moveSpeed", 3f));
            int health = Mathf.Max(1, ToolUtils.GetIntArg(args, "health", 3));
            bool chase = ToolUtils.GetBoolArg(args, "chase", true);
            float x = ToolUtils.GetFloatArg(args, "x", 0f);
            float y = ToolUtils.GetFloatArg(args, "y", 1f);
            float z = ToolUtils.GetFloatArg(args, "z", 5f);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            var notes = new List<string>();

            // Enemy.cs references GameManager.Instance and the Health type — ensure
            // both contracts compile.
            string gmErr = GameplayScaffold.EnsureGameManagerScript(dir, notes);
            if (!string.IsNullOrEmpty(gmErr)) return ToolUtils.CreateErrorResponse(gmErr);
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component enemies use");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "Enemy.cs.txt", "Enemy.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            // Build a visible capsule. Trigger collider + kinematic Rigidbody so its
            // contact with the player's CharacterController reliably fires triggers.
            string objName = GameplayScaffold.UniqueName(baseName);
            var go = GameObject.CreatePrimitive(PrimitiveType.Capsule);
            go.name = objName;
            go.transform.position = new Vector3(x, y, z);
            var col = go.GetComponent<Collider>();
            if (col != null) col.isTrigger = true;
            var rb = go.AddComponent<Rigidbody>();
            rb.isKinematic = true;
            rb.useGravity = false;
            Undo.RegisterCreatedObjectUndo(go, "Create Enemy");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    objName, null, "Enemy",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("moveSpeed", "float", moveSpeed.ToString()),
                        new PendingControllerWiring.FieldValue("chase", "bool", chase ? "true" : "false"),
                    }),
                new PendingControllerWiring.WiringRequest(
                    objName, null, "Health",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("maxHealth", "int", health.ToString()),
                        new PendingControllerWiring.FieldValue("destroyOnDeath", "bool", "true"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(go.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "enemyObject", objName },
                { "moveSpeed", moveSpeed },
                { "health", health },
                { "chase", chase },
                { "queuedComponents", new List<string> { $"Enemy → {objName}", $"Health → {objName}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Added an enemy ('{objName}', {health} HP, " + (chase ? $"chases at {moveSpeed}/s" : "stationary") + "). " +
                "This tool is ATOMIC: it wrote a VETTED chaser script, built a capsule with a trigger collider + " +
                "kinematic Rigidbody, and QUEUED Enemy + Health to attach on the next compile. DO NOT call " +
                "add_component. On contact it calls GameManager.Instance.LoseLife — so call create_game_manager too " +
                "(without it, contact does nothing). Give the player create_projectile to fight back (projectiles " +
                "damage the enemy's Health). Place more by calling this again. Your remaining step is compile_scripts.",
                extras);
        }
    }
}
