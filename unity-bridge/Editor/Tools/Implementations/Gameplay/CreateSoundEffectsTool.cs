using System;
using System.Collections.Generic;
using System.Globalization;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.Gameplay
{
    using GameObject = UnityEngine.GameObject;

    /// <summary>
    /// Drops the SOUND layer into the scene in ONE call: a SoundEffects jukebox that
    /// SYNTHESIZES short retro blips at runtime (no imported .wav files) and plays them on
    /// demand, so a freshly-scaffolded game stops being silent. It also auto-wires combat
    /// audio — it watches every Health and plays a "hit" on damage and a "death" on death.
    ///
    /// Why a template tool: hand-rolled SFX stalls on the asset problem (there are no clips
    /// to import, so the AI skips sound or references clips that don't exist). Procedural
    /// generation — phase-accurate sweeps and arpeggios with per-sample envelopes — always
    /// works in any project and is easy to get subtly wrong by hand (clicks, clipping).
    ///
    /// Reach it from anywhere via the static API: <c>SoundEffects.Play("jump")</c> (also
    /// "shoot", "collect", "levelup", "hit", "death", "hurt"). Combat cues fire on their
    /// own; wire the rest with one line in the jump / shot / pickup code.
    ///
    /// ATOMIC but DEFERRED like the other gameplay scaffolders: writes the vetted script
    /// (and ensures Health.cs, the type its combat hook reads), creates the SoundEffects
    /// object now, and QUEUES the SoundEffects component to attach on the next compile.
    /// Call once per scene; your only remaining step is compile_scripts.
    /// </summary>
    public class CreateSoundEffectsTool : ITool
    {
        public string Name => "create_sound_effects";

        private const string ComponentType = "SoundEffects";

        public string Execute(Dictionary<string, object> args)
        {
            string dir = GameplayScaffold.NormalizeDir(ToolUtils.GetStringArg(args, "directory", "Assets/Scripts"));
            string systemName = ToolUtils.GetStringArg(args, "name", "SoundEffects");
            if (string.IsNullOrEmpty(systemName)) systemName = "SoundEffects";
            float volume = Mathf.Clamp01(ToolUtils.GetFloatArg(args, "volume", 0.5f));
            bool autoHookCombat = ToolUtils.GetBoolArg(args, "autoHookCombat", true);
            bool confirmOverwrite = ToolUtils.GetBoolArg(args, "confirmExistingFileModification", false);

            // Refuse a SECOND jukebox — two would double every cue. The runtime singleton
            // is a backstop; catching it here keeps the scene clean and signals reuse.
            GameObject existing = FindExistingSystem(systemName);
            if (existing != null)
            {
                var dupExtras = new Dictionary<string, object>
                {
                    { "system", existing.name },
                    { "reason", "soundEffectsAlreadyExists" },
                };
                return ToolUtils.CreateErrorResponse(
                    $"A SoundEffects already exists in this scene (object '{existing.name}'). " +
                    "Reuse it — gameplay code reaches it via the static SoundEffects.Play(\"jump\"). " +
                    "Delete the existing one first if you want a fresh one.",
                    dupExtras);
            }

            var notes = new List<string>();

            // The combat auto-hook reads Health — ensure that type compiles.
            string hErr = GameplayScaffold.EnsureContractScript(
                "Health.cs.txt", "Health.cs", dir, notes, "the HP component its hit/death cues watch");
            if (!string.IsNullOrEmpty(hErr)) return ToolUtils.CreateErrorResponse(hErr);

            string scriptErr = GameplayScaffold.WriteVettedScript(
                "SoundEffects.cs.txt", "SoundEffects.cs", dir, confirmOverwrite, out string scriptPath);
            if (!string.IsNullOrEmpty(scriptErr)) return ToolUtils.CreateErrorResponse(scriptErr);

            var system = new GameObject(systemName);
            Undo.RegisterCreatedObjectUndo(system, "Create SoundEffects");

            PendingControllerWiring.Queue(new[]
            {
                new PendingControllerWiring.WiringRequest(
                    systemName, null, ComponentType,
                    new List<PendingControllerWiring.FieldValue>
                    {
                        new PendingControllerWiring.FieldValue("volume", "float", volume.ToString(CultureInfo.InvariantCulture)),
                        new PendingControllerWiring.FieldValue("autoHookCombat", "bool", autoHookCombat ? "true" : "false"),
                    }),
            });

            try { EditorSceneManager.MarkSceneDirty(system.scene); } catch { /* no open scene */ }
            AssetDatabase.Refresh(ImportAssetOptions.Default);

            var extras = new Dictionary<string, object>
            {
                { "createdScripts", new List<string> { scriptPath } },
                { "requiresCompilation", true },
                { "systemObject", systemName },
                { "volume", volume },
                { "autoHookCombat", autoHookCombat },
                { "cues", new List<string> { "jump", "shoot", "collect", "levelup", "hit", "death", "hurt" } },
                { "queuedComponents", new List<string> { $"SoundEffects → {systemName}" } },
                {
                    "triggers", new Dictionary<string, object>
                    {
                        { "jump", "SoundEffects.Play(\"jump\")" },
                        { "shoot", "SoundEffects.Play(\"shoot\")" },
                        { "collect", "SoundEffects.Play(\"collect\")" },
                        { "levelup", "SoundEffects.Play(\"levelup\")" },
                    }
                },
                { "sceneSetup", notes },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Created a SoundEffects jukebox — the audio layer. This tool is ATOMIC: it wrote a VETTED script, " +
                $"created the '{systemName}' object, and QUEUED the SoundEffects component to attach as soon as scripts " +
                "compile (every cue is SYNTHESIZED at runtime — no audio files needed). DO NOT call add_component, " +
                "create_audio_source, or assign_audio_clip. Combat audio is automatic: a 'hit' plays when any Health " +
                "takes damage and a 'death' when one dies. For the other cues, add one line where the event happens — " +
                "SoundEffects.Play(\"jump\") in the jump code, Play(\"shoot\") on fire, Play(\"collect\") on pickup, " +
                "Play(\"levelup\") on level up. Your ONLY remaining step is to call compile_scripts and wait until " +
                "status='idle'.",
                extras);
        }

        // An existing system: a loaded SoundEffects component (after the first compile), or
        // — before the type is loaded — a GameObject by the system name.
        private static GameObject FindExistingSystem(string systemName)
        {
            Type type = ToolUtils.FindComponentType(ComponentType);
            if (type != null)
            {
                var found = UnityEngine.Object.FindFirstObjectByType(type) as Component;
                if (found != null) return found.gameObject;
            }
            return GameObject.Find(systemName);
        }
    }
}
