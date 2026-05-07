using NUnit.Framework;
using UnityEditor;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// Pre-merge verification for the DemoAssetsGuard ↔ Live Loop ApplyQueuedFix
    /// contract: the guard MUST key on the target asset path, never on the
    /// initiator of the call. If a future change introduced a call-source
    /// heuristic ("is this an autonomous turn?") the demo-project regression
    /// would be silent — Live Loop fixes for non-demo paths get blocked even
    /// though the user is editing their own code.
    ///
    /// Canonical demo roots (kept in sync with DemoAssetsGuard.DemoAssetsRoots
    /// and deploy-plugin.ps1 destinations):
    ///   - Assets/DemoAssets                              (dev project)
    ///   - Packages/com.gladekit.agenticai/DemoAssets     (DLL bridge install)
    public class DemoAssetsGuard_LiveLoopApply
    {
        private const string PrefKey = "GladeAI.ReferenceDemoAssets";
        private const string DevDemoRoot = "Assets/DemoAssets";
        private const string PackageDemoRoot = "Packages/com.gladekit.agenticai/DemoAssets";

        private bool _hadKey;
        private bool _priorValue;

        [SetUp]
        public void SaveEditorPref()
        {
            _hadKey = EditorPrefs.HasKey(PrefKey);
            _priorValue = EditorPrefs.GetBool(PrefKey, true);
        }

        [TearDown]
        public void RestoreEditorPref()
        {
            if (_hadKey) EditorPrefs.SetBool(PrefKey, _priorValue);
            else EditorPrefs.DeleteKey(PrefKey);
        }

        // ── Path-keyed predicate: caller identity is irrelevant ─────────────────

        [Test]
        public void IsPathUnderDemoAssets_NonDemoUserScript_ReturnsFalse()
        {
            Assert.IsFalse(DemoAssetsGuard.IsPathUnderDemoAssets("Assets/MyGame/Player.cs"));
        }

        [Test]
        public void IsPathUnderDemoAssets_DevDemoFolder_ReturnsTrue()
        {
            Assert.IsTrue(DemoAssetsGuard.IsPathUnderDemoAssets(DevDemoRoot + "/BlackKnight.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_PackageDemoFolder_ReturnsTrue()
        {
            Assert.IsTrue(DemoAssetsGuard.IsPathUnderDemoAssets(PackageDemoRoot + "/BlackKnight.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_BackslashesNormalized_ReturnsTrue()
        {
            Assert.IsTrue(DemoAssetsGuard.IsPathUnderDemoAssets(@"Assets\DemoAssets\BlackKnight.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_CaseInsensitive_ReturnsTrue()
        {
            Assert.IsTrue(DemoAssetsGuard.IsPathUnderDemoAssets("ASSETS/DEMOASSETS/BlackKnight.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_AssetRelativeInput_ReturnsTrue()
        {
            // Caller passes "DemoAssets/X.prefab" without the "Assets/" prefix —
            // guard normalizes it before matching.
            Assert.IsTrue(DemoAssetsGuard.IsPathUnderDemoAssets("DemoAssets/BlackKnight.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_LegacyPath_ReturnsFalse()
        {
            // Regression guard: the old hardcoded constant
            // "Assets/Editor/GladeAgenticAI/DemoAssets" is no longer recognized
            // (the bridge migration moved demo content out of that folder).
            Assert.IsFalse(DemoAssetsGuard.IsPathUnderDemoAssets(
                "Assets/Editor/GladeAgenticAI/DemoAssets/Phantom.prefab"));
        }

        [Test]
        public void IsPathUnderDemoAssets_PackagesPath_NotPrefixedWithAssets()
        {
            // Sanity: a non-demo Packages/ path must not be silently corrupted by
            // an Assets/ prefix-prepend (the pre-fix behavior would have produced
            // "Assets/Packages/com.foo/DemoAssets/..." which then matched nothing,
            // but the corrupted path also broke other guards downstream).
            Assert.IsFalse(DemoAssetsGuard.IsPathUnderDemoAssets(
                "Packages/com.unity.timeline/Editor/SomeFile.cs"));
        }

        // ── Two TODO-mandated cases ─────────────────────────────────────────────
        // (a) Live Loop apply targeting Assets/MyGame/Player.cs in a project
        //     with demo content → allowed regardless of demo setting.
        // (b) Live Loop apply targeting Assets/DemoAssets/... or
        //     Packages/com.gladekit.agenticai/DemoAssets/... → blocked when off,
        //     allowed when on.

        [Test]
        public void LiveLoopApply_NonDemoTarget_AllowedRegardlessOfDemoSetting()
        {
            EditorPrefs.SetBool(PrefKey, false);
            Assert.IsTrue(
                DemoAssetsGuard.AllowUseOfDemoAssetPath("Assets/MyGame/Player.cs"),
                "Live Loop apply targeting a non-demo path must be allowed even when " +
                "'Reference demo assets' is off — guard is path-keyed, not call-source-keyed.");

            EditorPrefs.SetBool(PrefKey, true);
            Assert.IsTrue(
                DemoAssetsGuard.AllowUseOfDemoAssetPath("Assets/MyGame/Player.cs"));
        }

        [Test]
        public void LiveLoopApply_DevDemoTarget_BlockedWhenDemoSettingOff()
        {
            string demoPath = DevDemoRoot + "/BlackKnight.prefab";

            EditorPrefs.SetBool(PrefKey, false);
            Assert.IsFalse(
                DemoAssetsGuard.AllowUseOfDemoAssetPath(demoPath),
                "Dev-project demo path must be blocked when 'Reference demo assets' is off, " +
                "regardless of whether the call came from Live Loop or a direct user prompt.");

            EditorPrefs.SetBool(PrefKey, true);
            Assert.IsTrue(
                DemoAssetsGuard.AllowUseOfDemoAssetPath(demoPath),
                "Dev-project demo path must be allowed when the user has opted in.");
        }

        [Test]
        public void LiveLoopApply_PackageDemoTarget_BlockedWhenDemoSettingOff()
        {
            string demoPath = PackageDemoRoot + "/BlackKnight.prefab";

            EditorPrefs.SetBool(PrefKey, false);
            Assert.IsFalse(
                DemoAssetsGuard.AllowUseOfDemoAssetPath(demoPath),
                "DLL-bridge UPM-package demo path must be blocked when 'Reference demo " +
                "assets' is off — same path-keyed contract as the dev-project root.");

            EditorPrefs.SetBool(PrefKey, true);
            Assert.IsTrue(
                DemoAssetsGuard.AllowUseOfDemoAssetPath(demoPath));
        }

        // ── Path-list filter mirrors the same rule (used by ListAssetsTool) ─────

        [Test]
        public void FilterPathsExcludingDemoAssets_DemoOff_StripsDemoPathsKeepsUserPaths()
        {
            EditorPrefs.SetBool(PrefKey, false);
            var paths = new System.Collections.Generic.List<string>
            {
                "Assets/MyGame/Player.cs",
                DevDemoRoot + "/BlackKnight.prefab",
                PackageDemoRoot + "/Map.prefab",
                "Assets/MyGame/Enemies/Goblin.cs",
            };
            var filtered = DemoAssetsGuard.FilterPathsExcludingDemoAssets(paths);
            Assert.AreEqual(2, filtered.Count);
            CollectionAssert.Contains(filtered, "Assets/MyGame/Player.cs");
            CollectionAssert.Contains(filtered, "Assets/MyGame/Enemies/Goblin.cs");
        }
    }
}
