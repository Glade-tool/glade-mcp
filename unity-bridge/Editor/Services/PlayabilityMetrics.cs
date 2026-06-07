using System.Collections.Generic;
using UnityEngine;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Pure playability math, extracted from the runtime <c>ProbeDriver</c> so
    /// the "is this scene actually playable?" logic is unit-testable WITHOUT
    /// entering Play mode. ProbeDriver samples the player's world position each
    /// physics step during a live run; these functions turn that sample stream
    /// into the three metrics the eval harness asserts on.
    ///
    /// Why position-derived, not component-introspected: a controller can move
    /// via CharacterController, Rigidbody, or raw transform writes. Reading
    /// ".velocity" would branch on the mechanism. Position deltas are universal
    /// — every moving player changes position regardless of how.
    ///
    /// Metric shapes:
    ///
    ///   PlanarPathLength  sum of XZ step distances  → "did it move at all"
    ///   Straightness      |net XZ| / pathLength     → "line vs circle"
    ///   MaxJumpRise       max (y - startY) post-jump → "jump did something"
    ///
    /// <code>
    ///   straight run   ●──●──●──●──●        net≈path  → straightness ≈ 1.0
    ///   circles bug    ●──●           path long, net short
    ///                  │   ●          → straightness ≈ 0.1
    ///                  ●──●
    ///   stuck          ●               path ≈ 0 → straightness 0 (not "straight")
    /// </code>
    /// </summary>
    public static class PlayabilityMetrics
    {
        // Below this planar path length the player effectively did not move, so
        // straightness is undefined (0/0). We report straightness 0 in that
        // case: a non-moving player is "stuck", not "perfectly straight".
        private const float MinMeaningfulPathLength = 1e-4f;

        /// <summary>
        /// Total planar (XZ) distance travelled: the sum of horizontal
        /// distances between consecutive samples. This is the denominator of
        /// the straightness ratio and the guard for the "didn't move" case.
        /// Returns 0 for null / empty / single-sample input.
        /// </summary>
        public static float PlanarPathLength(IList<Vector3> samples)
        {
            if (samples == null || samples.Count < 2) return 0f;
            float total = 0f;
            for (int i = 1; i < samples.Count; i++)
            {
                total += PlanarDistance(samples[i - 1], samples[i]);
            }
            return total;
        }

        /// <summary>
        /// Net planar displacement divided by total planar path length, in
        /// [0, 1]. ~1.0 means the player travelled in a straight line; near 0
        /// means it looped back on itself (the circles bug). Returns 0 when the
        /// player barely moved (path length below a small epsilon) — a stuck
        /// player is not "straight".
        /// </summary>
        public static float Straightness(IList<Vector3> samples)
        {
            if (samples == null || samples.Count < 2) return 0f;
            float pathLength = PlanarPathLength(samples);
            if (pathLength < MinMeaningfulPathLength) return 0f;
            float net = PlanarDistance(samples[0], samples[samples.Count - 1]);
            return Mathf.Clamp01(net / pathLength);
        }

        /// <summary>
        /// Maximum upward rise in Y above the starting sample's height, looking
        /// only at samples from <paramref name="startIndex"/> onward (the frame
        /// the jump was pressed). Catches the dead jump: a controller whose jump
        /// does nothing never rises above its start height. Returns 0 for
        /// null / empty / out-of-range input, and never returns negative (a
        /// player only falling has a rise of 0, not a negative number).
        /// </summary>
        public static float MaxJumpRise(IList<Vector3> samples, int startIndex)
        {
            if (samples == null || samples.Count == 0) return 0f;
            if (startIndex < 0) startIndex = 0;
            if (startIndex >= samples.Count) return 0f;
            float startY = samples[startIndex].y;
            float maxRise = 0f;
            for (int i = startIndex; i < samples.Count; i++)
            {
                float rise = samples[i].y - startY;
                if (rise > maxRise) maxRise = rise;
            }
            return maxRise;
        }

        /// <summary>Horizontal (XZ-plane) distance between two world points.</summary>
        private static float PlanarDistance(Vector3 a, Vector3 b)
        {
            float dx = a.x - b.x;
            float dz = a.z - b.z;
            return Mathf.Sqrt(dx * dx + dz * dz);
        }
    }
}
