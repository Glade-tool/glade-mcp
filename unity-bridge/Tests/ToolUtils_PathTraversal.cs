using NUnit.Framework;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Tests
{
    /// Directory-traversal guard for tool path arguments. A bare
    /// StartsWith("Assets/") check lets "Assets/../../evil.cs" through; the
    /// segment-based check rejects any ".." path component while leaving
    /// legitimate dotted filenames alone.
    public class ToolUtils_PathTraversal
    {
        [Test]
        public void Allows_NormalAssetPath()
        {
            Assert.IsTrue(ToolUtils.IsAssetPathSafe("Assets/Scripts/Player.cs"));
        }

        [Test]
        public void Allows_PackagesPath()
        {
            Assert.IsTrue(ToolUtils.IsAssetPathSafe("Packages/com.gladekit.agenticai/DemoAssets/x.prefab"));
        }

        [Test]
        public void Allows_FilenamesContainingDots()
        {
            Assert.IsTrue(ToolUtils.IsAssetPathSafe("Assets/My..Folder/file.cs"));
            Assert.IsTrue(ToolUtils.IsAssetPathSafe("Assets/v1.2.3/data.asset"));
            Assert.IsTrue(ToolUtils.IsAssetPathSafe("Assets/a.b..c/x"));
        }

        [Test]
        public void Allows_NullAndEmpty()
        {
            // Required-ness is each tool's own concern; this guard only judges traversal.
            Assert.IsTrue(ToolUtils.IsAssetPathSafe(null));
            Assert.IsTrue(ToolUtils.IsAssetPathSafe(""));
        }

        [Test]
        public void Rejects_TraversalEscapingProject()
        {
            Assert.IsFalse(ToolUtils.IsAssetPathSafe("Assets/../../evil.cs"));
        }

        [Test]
        public void Rejects_TraversalSegmentAnywhere()
        {
            Assert.IsFalse(ToolUtils.IsAssetPathSafe("Assets/Scripts/../../../etc/passwd"));
            Assert.IsFalse(ToolUtils.IsAssetPathSafe("../outside.cs"));
        }

        [Test]
        public void Rejects_BackslashTraversal()
        {
            // Windows clients may send backslashes.
            Assert.IsFalse(ToolUtils.IsAssetPathSafe("Assets\\..\\..\\evil.cs"));
        }
    }
}
