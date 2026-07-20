using System.IO;
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

        // ── IsPathInsideRoot: containment guard for the raw File.Copy/File.Delete
        // endpoints (turn/revert, file/backup). Unlike IsAssetPathSafe it also
        // rejects ABSOLUTE escapes that carry no ".." segment, and rejects a
        // sibling dir that merely shares the root's name prefix. Root is injected
        // so the logic is testable without a live Unity project. ──

        // A synthetic absolute root that need not exist on disk — GetFullPath
        // resolves it without requiring the directory to be present.
        private static readonly string Root = Path.GetFullPath("GladeSecTestRoot");

        [Test]
        public void InsideRoot_AllowsRelativeUnderRoot()
        {
            Assert.IsTrue(ToolUtils.IsPathInsideRoot("Assets/Scripts/Player.cs", Root));
            Assert.IsTrue(ToolUtils.IsPathInsideRoot(".gladekit-backups/turn1/files/x.cs", Root));
        }

        [Test]
        public void InsideRoot_AllowsAbsoluteUnderRoot()
        {
            Assert.IsTrue(ToolUtils.IsPathInsideRoot(Path.Combine(Root, "Assets", "x.cs"), Root));
        }

        [Test]
        public void InsideRoot_AllowsExactRoot()
        {
            Assert.IsTrue(ToolUtils.IsPathInsideRoot(Root, Root));
        }

        [Test]
        public void InsideRoot_RejectsTraversalEscape()
        {
            Assert.IsFalse(ToolUtils.IsPathInsideRoot("Assets/../../evil.cs", Root));
        }

        [Test]
        public void InsideRoot_RejectsAbsoluteEscapeWithoutDotDot()
        {
            // The turn/revert exploit: an absolute path with no ".." segment —
            // IsAssetPathSafe would pass it; IsPathInsideRoot must reject it.
            Assert.IsFalse(ToolUtils.IsPathInsideRoot("/etc/passwd", Root));
        }

        [Test]
        public void InsideRoot_RejectsSiblingSharingNamePrefix()
        {
            // "/x/GladeSecTestRoot-evil" must NOT count as inside "/x/GladeSecTestRoot":
            // the separator-boundary check defeats a bare StartsWith.
            Assert.IsFalse(ToolUtils.IsPathInsideRoot(Root + "-evil/x.cs", Root));
        }

        [Test]
        public void InsideRoot_RejectsNullOrEmptyInputs()
        {
            Assert.IsFalse(ToolUtils.IsPathInsideRoot(null, Root));
            Assert.IsFalse(ToolUtils.IsPathInsideRoot("", Root));
            Assert.IsFalse(ToolUtils.IsPathInsideRoot("Assets/x.cs", null));
            Assert.IsFalse(ToolUtils.IsPathInsideRoot("Assets/x.cs", ""));
        }
    }
}
