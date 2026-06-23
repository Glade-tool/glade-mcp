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
    /// Gives the player the SHOOT verb in ONE call: a PlayerShooter that, on fire
    /// input (left mouse or F), spawns a projectile and launches it forward (aimed
    /// by the camera). Projectiles damage any Health they hit — so with create_enemy
    /// (enemies carry Health) this closes the combat loop: you can fight back.
    ///
    /// Why a template tool: a hand-written shooter usually re-derives subtly-broken
    /// code — projectiles that hit the firer, never despawn, or don't reliably
    /// collide. The vetted Projectile.cs + PlayerShooter.cs handle ignore-the-shooter,
    /// a lifetime, and physics-driven movement. No prefab to wire — the projectile is
    /// built in code.
    ///
    /// ATOMIC but DEFERRED: writes the two vetted scripts (and ensures Health.cs, the
    /// damage contract) and QUEUES PlayerShooter onto the player to attach on the next
    /// compile. Your only remaining step is compile_scripts.
    /// </summary>
    public class CreateProjectileTool : ITool
    {
        public string Name => "create_projectile";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string shooterName = ToolUtils.GetStringArg(args, "shooter", "Player");
            if (string.IsNullOrEmpty(shooterName)) shooterName = "Player";
            float fireRate = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "fireRate", 3f));
            float speed = Mathf.Max(0.1f, ToolUtils.GetFloatArg(args, "projectileSpeed", 14f));
            int damage = Mathf.Max(1, ToolUtils.GetIntArg(args, "damage", 1));
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            var notes = new List<string>();

            // Projectile.cs damages the Health type — ensure that contract compiles.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component projectiles damage");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string pErr = GameplayScaffold.WriteVettedScript(
                "Projectile.cs.txt", "Projectile.cs", dir, confirmOverwrite, out string projPath);
            if (!string.IsNullOrEmpty(pErr)) return ToolUtils.CreateErrorResponse(pErr);
            string sErr = GameplayScaffold.WriteVettedScript(
                "PlayerShooter.cs.txt", "PlayerShooter.cs", dir, confirmOverwrite, out string shooterPath);
            if (!string.IsNullOrEmpty(sErr)) return ToolUtils.CreateErrorResponse(sErr);

            GameObject shooter = ResolveTarget(shooterName);
            if (shooter == null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Shooter '{shooterName}' not found. Create the player first (e.g. create_third_person_controller), " +
                    "or pass the name of an existing object to mount the shooter on.");
            }

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    shooter.name, null, "PlayerShooter",
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("fireRate", "float", fireRate.ToString()),
                        new PendingControllerWiring.FieldValue("projectileSpeed", "float", speed.ToString()),
                        new PendingControllerWiring.FieldValue("projectileDamage", "int", damage.ToString()),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(shooter.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { projPath, shooterPath } },
                { "requiresCompilation", true },
                { "shooter", shooter.name },
                { "fireRate", fireRate },
                { "projectileSpeed", speed },
                { "damage", damage },
                { "queuedComponents", new List<string> { $"PlayerShooter → {shooter.name}" } },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Gave '{shooter.name}' the shoot verb (left mouse / F, {fireRate}/s, {damage} dmg). This tool is " +
                "ATOMIC: it wrote VETTED Projectile.cs + PlayerShooter.cs and QUEUED PlayerShooter onto the player to " +
                "attach on the next compile. DO NOT call add_component. Projectiles damage any Health they hit — give " +
                "enemies Health via create_enemy (it does) so shots can kill them. The projectile is built in code " +
                "(no prefab). Your only remaining step is to call compile_scripts and wait until status='idle'.",
                extras);
        }

        private static GameObject ResolveTarget(string target)
        {
            try
            {
                var byTag = GameObject.FindWithTag(target);
                if (byTag != null) return byTag;
            }
            catch { /* not a defined tag */ }
            return GameObject.Find(target);
        }
    }
}
