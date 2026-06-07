using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Coverage for the pure playability math. These run in EditMode with no
    /// Play-mode dependency — that is the whole point of extracting the metrics
    /// from ProbeDriver: the logic that decides "playable or not" is verified
    /// deterministically here, and only the input/sampling WIRING needs the
    /// (flaky, local-only) Play-mode smoke test.
    /// </summary>
    public class PlayabilityMetrics_Tests
    {
        // ── PlanarPathLength ────────────────────────────────────────────────

        [Test]
        public void PathLength_EmptyOrSingle_IsZero()
        {
            Assert.AreEqual(0f, PlayabilityMetrics.PlanarPathLength(null));
            Assert.AreEqual(0f, PlayabilityMetrics.PlanarPathLength(new List<Vector3>()));
            Assert.AreEqual(0f, PlayabilityMetrics.PlanarPathLength(new List<Vector3> { Vector3.zero }));
        }

        [Test]
        public void PathLength_StraightLine_SumsXZSteps()
        {
            var samples = new List<Vector3>
            {
                new Vector3(0, 0, 0),
                new Vector3(0, 0, 1),
                new Vector3(0, 0, 2),
                new Vector3(0, 0, 3),
            };
            Assert.AreEqual(3f, PlayabilityMetrics.PlanarPathLength(samples), 1e-4f);
        }

        [Test]
        public void PathLength_IgnoresVerticalMotion()
        {
            // Pure vertical bobbing (a jump) should not count as ground travel.
            var samples = new List<Vector3>
            {
                new Vector3(0, 0, 0),
                new Vector3(0, 2, 0),
                new Vector3(0, 0, 0),
            };
            Assert.AreEqual(0f, PlayabilityMetrics.PlanarPathLength(samples), 1e-4f);
        }

        // ── Straightness ────────────────────────────────────────────────────

        [Test]
        public void Straightness_StraightLine_IsOne()
        {
            var samples = new List<Vector3>
            {
                new Vector3(0, 0, 0),
                new Vector3(0, 0, 1),
                new Vector3(0, 0, 2),
                new Vector3(0, 0, 3),
            };
            Assert.AreEqual(1f, PlayabilityMetrics.Straightness(samples), 1e-3f);
        }

        [Test]
        public void Straightness_FullCircle_IsNearZero()
        {
            // The circles bug: player loops back to ~start. Long path, ~0 net.
            var samples = new List<Vector3>();
            int steps = 64;
            float radius = 3f;
            for (int i = 0; i <= steps; i++)
            {
                float t = (float)i / steps * 2f * Mathf.PI;
                samples.Add(new Vector3(radius * Mathf.Cos(t), 0, radius * Mathf.Sin(t)));
            }
            float s = PlayabilityMetrics.Straightness(samples);
            Assert.Less(s, 0.1f, $"full circle should score near 0, got {s}");
        }

        [Test]
        public void Straightness_GentleCurve_StillHigh()
        {
            // A correct controller that turns slightly should NOT be flagged.
            var samples = new List<Vector3>();
            for (int i = 0; i <= 20; i++)
            {
                samples.Add(new Vector3(i * 0.1f, 0, i)); // drifts sideways a little
            }
            float s = PlayabilityMetrics.Straightness(samples);
            Assert.Greater(s, 0.9f, $"gentle curve should stay high, got {s}");
        }

        [Test]
        public void Straightness_NoMovement_IsZero()
        {
            var samples = new List<Vector3>
            {
                new Vector3(1, 0, 1),
                new Vector3(1, 0, 1),
                new Vector3(1, 0, 1),
            };
            Assert.AreEqual(0f, PlayabilityMetrics.Straightness(samples), 1e-4f);
        }

        [Test]
        public void Straightness_EmptyOrSingle_IsZero()
        {
            Assert.AreEqual(0f, PlayabilityMetrics.Straightness(null));
            Assert.AreEqual(0f, PlayabilityMetrics.Straightness(new List<Vector3> { Vector3.zero }));
        }

        // ── MaxJumpRise ─────────────────────────────────────────────────────

        [Test]
        public void JumpRise_RisingArc_ReturnsPeak()
        {
            var samples = new List<Vector3>
            {
                new Vector3(0, 0f, 0),   // jump pressed here (index 0)
                new Vector3(0, 0.5f, 1),
                new Vector3(0, 0.9f, 2), // peak
                new Vector3(0, 0.4f, 3),
                new Vector3(0, 0.0f, 4),
            };
            Assert.AreEqual(0.9f, PlayabilityMetrics.MaxJumpRise(samples, 0), 1e-4f);
        }

        [Test]
        public void JumpRise_DeadJump_IsZero()
        {
            // Jump does nothing: y never rises above start.
            var samples = new List<Vector3>
            {
                new Vector3(0, 0f, 0),
                new Vector3(0, 0f, 1),
                new Vector3(0, 0f, 2),
            };
            Assert.AreEqual(0f, PlayabilityMetrics.MaxJumpRise(samples, 0), 1e-4f);
        }

        [Test]
        public void JumpRise_OnlyFalling_IsZero()
        {
            // A player that only falls (never jumps) has rise 0, not negative.
            var samples = new List<Vector3>
            {
                new Vector3(0, 5f, 0),
                new Vector3(0, 3f, 0),
                new Vector3(0, 1f, 0),
            };
            Assert.AreEqual(0f, PlayabilityMetrics.MaxJumpRise(samples, 0), 1e-4f);
        }

        [Test]
        public void JumpRise_MeasuresFromStartIndex()
        {
            // Rise is measured relative to the sample at startIndex, not sample 0.
            var samples = new List<Vector3>
            {
                new Vector3(0, 0f, 0),
                new Vector3(0, 0f, 0),   // jump pressed here (index 1)
                new Vector3(0, 1.5f, 0), // peak relative to index 1
            };
            Assert.AreEqual(1.5f, PlayabilityMetrics.MaxJumpRise(samples, 1), 1e-4f);
        }

        [Test]
        public void JumpRise_OutOfRangeIndex_IsZero()
        {
            var samples = new List<Vector3> { new Vector3(0, 1, 0) };
            Assert.AreEqual(0f, PlayabilityMetrics.MaxJumpRise(samples, 5));
            Assert.AreEqual(0f, PlayabilityMetrics.MaxJumpRise(null, 0));
        }
    }
}
