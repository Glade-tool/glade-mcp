using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
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

        // ── Golden-file parity ──────────────────────────────────────────────
        //
        // PlayabilityMetrics is pinned to a shared spec, metrics_golden.json,
        // which sits next to this test file. Each golden vector carries a sample
        // stream plus the hand-computed expected straightness / path length /
        // jump rise. If the metric math drifts without the golden file changing
        // in lockstep, this test fails — so the implementation and the
        // documented spec can never silently diverge.

        [Test]
        public void GoldenVectors_MatchCSharpImplementation()
        {
            string path = ResolveGoldenPath();
            Assert.IsNotNull(path, "could not resolve this test's source directory");
            Assert.IsTrue(File.Exists(path),
                $"metrics_golden.json not found next to the test (looked at {path})");

            var vectors = ParseGoldenVectors(File.ReadAllText(path));
            Assert.Greater(vectors.Count, 0,
                "Parsed zero golden vectors — parser or golden file is broken.");

            foreach (var v in vectors)
            {
                Assert.AreEqual(
                    v.PathLength,
                    PlayabilityMetrics.PlanarPathLength(v.Samples),
                    1e-5f,
                    $"[{v.Name}] pathLength");
                Assert.AreEqual(
                    v.Straightness,
                    PlayabilityMetrics.Straightness(v.Samples),
                    1e-5f,
                    $"[{v.Name}] straightness");
                Assert.AreEqual(
                    v.JumpDy,
                    PlayabilityMetrics.MaxJumpRise(v.Samples, v.JumpStartIndex),
                    1e-5f,
                    $"[{v.Name}] jumpDy");
            }
        }

        // ── Golden-file plumbing ────────────────────────────────────────────

        private struct GoldenVector
        {
            public string Name;
            public List<Vector3> Samples;
            public int JumpStartIndex;
            public float Straightness;
            public float PathLength;
            public float JumpDy;
        }

        /// <summary>
        /// Resolve metrics_golden.json, which lives next to this test file. We
        /// anchor on <see cref="System.Runtime.CompilerServices.CallerFilePathAttribute"/>
        /// (the compile-time path of this .cs file) so resolution works whether
        /// the bridge is embedded in a Unity project or installed as a UPM
        /// package — neither relies on the Editor's working directory. Returns
        /// null only when the caller path is unavailable.
        /// </summary>
        private static string ResolveGoldenPath([CallerFilePath] string thisFile = "")
        {
            if (string.IsNullOrEmpty(thisFile)) return null;
            string testsDir = Path.GetDirectoryName(thisFile);   // .../Tests
            if (testsDir == null) return null;
            return Path.Combine(testsDir, "metrics_golden.json");
        }

        // Matches one "samples" array of [x, y, z] triples, e.g.
        //   [[0, 0, 0], [0, 0, 1]]  →  the inner [..] groups are captured.
        private static readonly Regex TripleRx = new Regex(
            @"\[\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*\]",
            RegexOptions.Compiled);

        /// <summary>
        /// Minimal, dependency-free reader for metrics_golden.json's known
        /// shape. Unity's JsonUtility can't represent the nested float[][] and
        /// free-form "expected" object cleanly, and the bridge ships no general
        /// JSON library, so we extract exactly the fields this test needs with
        /// regex. The canonical source remains the json file; this parser only
        /// has to understand that one file.
        /// </summary>
        private static List<GoldenVector> ParseGoldenVectors(string json)
        {
            var result = new List<GoldenVector>();

            // Split into per-vector objects on the "name" key. Each vector
            // object is delimited by the next "name" or the end of the array.
            var entryRx = new Regex(
                "\"name\"\\s*:\\s*\"(?<name>[^\"]+)\"" +
                "(?<body>.*?)" +
                "(?=\"name\"\\s*:|\\]\\s*}\\s*$)",
                RegexOptions.Singleline);

            foreach (Match entry in entryRx.Matches(json))
            {
                // Skip the README block (its first key is not a vector "name").
                string name = entry.Groups["name"].Value;
                string body = entry.Groups["body"].Value;
                if (!body.Contains("\"samples\"") || !body.Contains("\"expected\""))
                    continue;

                var v = new GoldenVector
                {
                    Name = name,
                    Samples = new List<Vector3>(),
                    JumpStartIndex = ExtractInt(body, "jumpStartIndex"),
                };

                // Isolate the samples array so we don't pick up triples that
                // might appear elsewhere (none do today, but be precise).
                string samplesSegment = ExtractArraySegment(body, "samples");
                foreach (Match t in TripleRx.Matches(samplesSegment))
                {
                    v.Samples.Add(new Vector3(
                        ParseFloat(t.Groups[1].Value),
                        ParseFloat(t.Groups[2].Value),
                        ParseFloat(t.Groups[3].Value)));
                }

                v.Straightness = ExtractFloat(body, "straightness");
                v.PathLength = ExtractFloat(body, "pathLength");
                v.JumpDy = ExtractFloat(body, "jumpDy");
                result.Add(v);
            }

            return result;
        }

        // Returns the substring from "<key>" : [  up to the matching ].
        private static string ExtractArraySegment(string body, string key)
        {
            int keyIdx = body.IndexOf("\"" + key + "\"", System.StringComparison.Ordinal);
            if (keyIdx < 0) return string.Empty;
            int open = body.IndexOf('[', keyIdx);
            if (open < 0) return string.Empty;
            int depth = 0;
            for (int i = open; i < body.Length; i++)
            {
                if (body[i] == '[') depth++;
                else if (body[i] == ']')
                {
                    depth--;
                    if (depth == 0) return body.Substring(open, i - open + 1);
                }
            }
            return body.Substring(open);
        }

        private static float ExtractFloat(string body, string key)
        {
            var m = Regex.Match(body,
                "\"" + Regex.Escape(key) + "\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)");
            return m.Success ? ParseFloat(m.Groups[1].Value) : float.NaN;
        }

        private static int ExtractInt(string body, string key)
        {
            var m = Regex.Match(body,
                "\"" + Regex.Escape(key) + "\"\\s*:\\s*(-?\\d+)");
            return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
        }

        private static float ParseFloat(string s)
        {
            return float.Parse(s, CultureInfo.InvariantCulture);
        }
    }
}
