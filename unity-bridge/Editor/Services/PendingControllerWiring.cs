using System;
using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Deferred component attachment for <c>create_third_person_controller</c>.
    ///
    /// Why this exists: a MonoBehaviour type does not exist in the running
    /// AppDomain until the script that declares it has compiled AND a domain
    /// reload has brought the new assembly in. The bridge tool that writes the
    /// controller scripts runs synchronously on the main thread and returns long
    /// before that compile finishes, so it cannot itself
    /// <c>AddComponent&lt;ThirdPersonController&gt;()</c> — the type is not loaded
    /// yet. Historically that forced a multi-step contract: the tool wrote files,
    /// then the caller had to wait for compilation and issue separate
    /// <c>add_component</c> calls. Under multi-system load an AI client frequently
    /// dropped that follow-up (it treated "compile done" as "task done"), leaving
    /// a bare capsule with no controller — a failure no structural check catches.
    ///
    /// This service closes that gap. The tool queues the components it wants
    /// attached (object + type name), then Unity's normal compile → domain-reload
    /// cycle fires <see cref="AssemblyReloadEvents.afterAssemblyReload"/>, by which
    /// point the new types ARE loaded, and we attach them automatically. The queue
    /// lives in <see cref="SessionState"/> because it has to survive the very
    /// domain reload it is waiting on (static fields are wiped by that reload —
    /// the same constraint <see cref="PlayabilityProbeStore"/> documents).
    ///
    /// Lifecycle:
    /// <code>
    ///   tool: Queue(player→ThirdPersonController, camera→FollowCamera)  [SessionState]
    ///   tool: AssetDatabase.Refresh()  → compile starts (async)
    ///   ...compile succeeds → domain reload → InitializeOnLoad static ctor runs
    ///   afterAssemblyReload / delayCall → TryComplete(): types resolve → AddComponent → Clear()
    /// </code>
    /// Idempotent and self-clearing: TryComplete skips objects that already have
    /// the component, clears the queue once every entry's type resolves (attaching
    /// what it can), and gives up after <see cref="MaxAttempts"/> reload cycles so
    /// a compile failure can never wedge the queue across an entire session.
    /// </summary>
    [InitializeOnLoad]
    public static class PendingControllerWiring
    {
        private const string KeyJson = "GladeKit.PendingWiring.Json";
        private const string KeyAttempts = "GladeKit.PendingWiring.Attempts";

        // A compile failure means no domain reload, so the new types never load.
        // Bound the retries so the queue self-clears instead of lingering and
        // re-firing on every unrelated reload for the rest of the session.
        private const int MaxAttempts = 6;

        static PendingControllerWiring()
        {
            // Both hooks run after a domain reload completes; afterAssemblyReload
            // is the canonical "new assemblies are live now" signal, and the
            // delayCall covers the case where the types were already compiled
            // (e.g. a second call in the same session). TryComplete is idempotent,
            // so firing twice is harmless.
            AssemblyReloadEvents.afterAssemblyReload += TryComplete;
            EditorApplication.delayCall += TryComplete;
        }

        /// <summary>True while components are still waiting to be attached.</summary>
        public static bool HasPending =>
            !string.IsNullOrEmpty(SessionState.GetString(KeyJson, string.Empty));

        /// <summary>
        /// Queue components to attach once their declaring scripts compile.
        /// Each request resolves its target at attach time by tag first (if set),
        /// then by name — robust across the domain reload that sits between this
        /// call and <see cref="TryComplete"/>.
        ///
        /// ACCUMULATES rather than replaces: a single turn may scaffold several
        /// systems before the one compile that wires them all (e.g.
        /// create_third_person_controller THEN create_game_manager THEN
        /// create_collectible, each queueing its own component). Replacing the slot
        /// would drop every earlier scaffolder's wiring, leaving bare objects with
        /// no scripts. So new requests merge into the existing queue, deduped by
        /// target+component (a re-queue of the same attachment updates its fields
        /// rather than adding a duplicate). The attempt budget resets on every call
        /// since fresh work was just added.
        /// </summary>
        public static void Queue(IEnumerable<WiringRequest> requests)
        {
            var merged = ReadQueue();
            foreach (var req in requests)
            {
                if (req == null || string.IsNullOrEmpty(req.componentType)) continue;
                string key = RequestKey(req);
                merged.RemoveAll(r => RequestKey(r) == key);
                merged.Add(req);
            }
            var wrapper = new WiringRequestList { items = merged };
            SessionState.SetString(KeyJson, JsonUtility.ToJson(wrapper));
            SessionState.SetInt(KeyAttempts, 0);
        }

        /// <summary>Reads the currently-queued requests (empty list if none or if
        /// the stored JSON is unreadable — start fresh rather than throw).</summary>
        private static List<WiringRequest> ReadQueue()
        {
            string json = SessionState.GetString(KeyJson, string.Empty);
            if (string.IsNullOrEmpty(json)) return new List<WiringRequest>();
            try
            {
                var wrapper = JsonUtility.FromJson<WiringRequestList>(json);
                if (wrapper?.items != null) return wrapper.items;
            }
            catch { /* corrupt slot — discard and start clean */ }
            return new List<WiringRequest>();
        }

        /// <summary>Dedup identity for a queued attachment: the same component on the
        /// same target (resolved by name+tag) is one attachment, regardless of fields.</summary>
        private static string RequestKey(WiringRequest r) =>
            $"{r.objectName}|{r.objectTag}|{r.componentType}";

        /// <summary>Drops the queue without attaching anything (defensive cleanup).</summary>
        public static void Clear()
        {
            SessionState.EraseString(KeyJson);
            SessionState.EraseInt(KeyAttempts);
        }

        /// <summary>
        /// Attempt to attach every queued component. Public so the C# test suite
        /// can drive it directly without staging a real domain reload.
        /// </summary>
        public static void TryComplete()
        {
            string json = SessionState.GetString(KeyJson, string.Empty);
            if (string.IsNullOrEmpty(json)) return;

            WiringRequestList wrapper;
            try { wrapper = JsonUtility.FromJson<WiringRequestList>(json); }
            catch { Clear(); return; }
            if (wrapper?.items == null || wrapper.items.Count == 0) { Clear(); return; }

            bool allResolved = true;
            var attached = new List<string>();

            foreach (var req in wrapper.items)
            {
                Type type = ToolUtils.FindComponentType(req.componentType);
                if (type == null || !typeof(Component).IsAssignableFrom(type))
                {
                    // Script not compiled into the loaded domain yet — keep waiting.
                    allResolved = false;
                    continue;
                }

                GameObject target = Resolve(req);
                if (target == null)
                {
                    // The type exists but the object is gone (e.g. the scene was
                    // wiped between queueing and now). Nothing to attach — treat as
                    // resolved so we don't loop forever on a missing object.
                    Debug.LogWarning(
                        $"[GladeKit] Deferred wiring: '{req.componentType}' target not found " +
                        $"(name='{req.objectName}', tag='{req.objectTag}') — skipping.");
                    continue;
                }

                if (target.GetComponent(type) == null)
                {
                    var component = target.AddComponent(type);
                    ApplyFields(component, req.fields);
                    EditorUtility.SetDirty(target);
                    attached.Add($"{type.Name} → {target.name}");
                }
            }

            if (attached.Count > 0)
            {
                Debug.Log("[GladeKit] Deferred controller wiring attached: " +
                          string.Join(", ", attached));
            }

            if (allResolved)
            {
                Clear();
            }
            else
            {
                int attempts = SessionState.GetInt(KeyAttempts, 0) + 1;
                if (attempts >= MaxAttempts)
                {
                    Debug.LogError(
                        "[GladeKit] Deferred controller wiring gave up after " +
                        $"{attempts} reload cycles — the controller scripts likely " +
                        "failed to compile, so their components could not attach. " +
                        "Fix the compile error and re-run create_third_person_controller.");
                    Clear();
                }
                else
                {
                    SessionState.SetInt(KeyAttempts, attempts);
                }
            }
        }

        private static GameObject Resolve(WiringRequest req)
        {
            if (!string.IsNullOrEmpty(req.objectTag))
            {
                try
                {
                    var byTag = GameObject.FindWithTag(req.objectTag);
                    if (byTag != null) return byTag;
                }
                catch
                {
                    // Undefined tag — fall through to name lookup.
                }
            }
            return string.IsNullOrEmpty(req.objectName) ? null : GameObject.Find(req.objectName);
        }

        /// <summary>
        /// Set the configuration the tool requested on a freshly-attached component.
        /// A scaffolder can't set these inline — the type isn't loaded when the tool
        /// runs — so it ships the values with the queued request and we apply them
        /// here, the moment the component exists. Only public fields/properties are
        /// touched, and only int / float / bool / string, which covers every
        /// scaffolder knob (lives, score-to-win, pickup value, damage, …). A name
        /// that doesn't resolve is skipped quietly: the script default stands.
        /// </summary>
        private static void ApplyFields(Component component, List<FieldValue> fields)
        {
            if (component == null || fields == null || fields.Count == 0) return;
            Type t = component.GetType();
            foreach (var f in fields)
            {
                if (string.IsNullOrEmpty(f.name)) continue;
                try
                {
                    var field = t.GetField(f.name);
                    if (field != null) { field.SetValue(component, ConvertValue(f, field.FieldType)); continue; }
                    var prop = t.GetProperty(f.name);
                    if (prop != null && prop.CanWrite) prop.SetValue(component, ConvertValue(f, prop.PropertyType));
                }
                catch
                {
                    // Type mismatch or a setter that threw — leave the script default.
                }
            }
        }

        private static object ConvertValue(FieldValue f, Type target)
        {
            if (target == typeof(int)) return int.Parse(f.value);
            if (target == typeof(float)) return float.Parse(f.value);
            if (target == typeof(bool)) return bool.Parse(f.value);
            return f.value; // string (and anything else falls back to the raw text)
        }

        /// <summary>One queued attachment: a component type to add to a target
        /// resolved by tag (preferred) or name, plus optional initial field values
        /// to apply once the component is attached.</summary>
        [Serializable]
        public class WiringRequest
        {
            public string objectName;
            public string objectTag;
            public string componentType;
            public List<FieldValue> fields;

            public WiringRequest() { }

            public WiringRequest(string objectName, string objectTag, string componentType,
                                 List<FieldValue> fields = null)
            {
                this.objectName = objectName;
                this.objectTag = objectTag;
                this.componentType = componentType;
                this.fields = fields;
            }
        }

        /// <summary>An initial value for a public field/property on a queued
        /// component. <see cref="kind"/> is informational; conversion is driven by
        /// the component's actual member type.</summary>
        [Serializable]
        public class FieldValue
        {
            public string name;
            public string kind;   // "int" | "float" | "bool" | "string"
            public string value;

            public FieldValue() { }

            public FieldValue(string name, string kind, string value)
            {
                this.name = name;
                this.kind = kind;
                this.value = value;
            }
        }

        // JsonUtility cannot serialize a bare List<T>; it needs a wrapper object.
        [Serializable]
        private class WiringRequestList
        {
            public List<WiringRequest> items;
        }
    }
}
