using NUnit.Framework;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Coverage for the lexical scanner that powers accurate find_references and safe
    /// rename. The whole point is that it matches whole identifiers ONLY in code
    /// regions — never inside strings, comments, or char literals (the false-positive
    /// class a raw regex over file content cannot avoid) — while still seeing
    /// identifiers inside interpolated-string holes so a rename stays correct.
    /// Pure logic, runs in EditMode with no Play-mode or bridge dependency.
    /// </summary>
    public class CSharpLexicalScanner_Tests
    {
        private static int Count(string src, string sym) => CSharpLexicalScanner.CountOccurrences(src, sym);

        // ── whole-identifier matching ────────────────────────────────────────

        [Test]
        public void Matches_PlainCodeIdentifier()
        {
            Assert.AreEqual(2, Count("Player p = new Player();", "Player"));
        }

        [Test]
        public void WholeIdentifier_DoesNotMatchSubstring()
        {
            // Searching "Player" must not hit "PlayerController" (the substring trap).
            Assert.AreEqual(0, Count("public class PlayerController {}", "Player"));
            Assert.AreEqual(1, Count("public class PlayerController {}", "PlayerController"));
        }

        [Test]
        public void CaseSensitive()
        {
            Assert.AreEqual(1, Count("int player; int Player;", "Player"));
            Assert.AreEqual(1, Count("int player; int Player;", "player"));
        }

        [Test]
        public void MatchesAcrossMemberAccess()
        {
            // foo.Player → two identifier tokens; "." is not an identifier char.
            Assert.AreEqual(1, Count("var x = foo.Player;", "Player"));
            Assert.AreEqual(1, Count("var x = foo.Player;", "foo"));
        }

        // ── strings / comments / char literals are skipped ───────────────────

        [Test]
        public void SkipsStringLiteral()
        {
            Assert.AreEqual(0, Count("Debug.Log(\"Player wins\");", "Player"));
            // …but a real code use in the same line is still found.
            Assert.AreEqual(1, Count("Player p; Debug.Log(\"Player wins\");", "Player"));
        }

        [Test]
        public void SkipsEscapedQuoteInString()
        {
            // The \" does not end the string, so "Player" stays inside it.
            Assert.AreEqual(0, Count("var s = \"he said \\\"Player\\\" loud\";", "Player"));
        }

        [Test]
        public void SkipsLineComment()
        {
            Assert.AreEqual(0, Count("// TODO: wire up Player here", "Player"));
            Assert.AreEqual(1, Count("Player p; // TODO: wire up Player here", "Player"));
        }

        [Test]
        public void SkipsBlockComment()
        {
            Assert.AreEqual(0, Count("/* Player Player Player */", "Player"));
            Assert.AreEqual(1, Count("Player p; /* not this Player */", "Player"));
        }

        [Test]
        public void SkipsVerbatimString()
        {
            Assert.AreEqual(0, Count("var path = @\"C:\\Player\\data\";", "Player"));
            // "" is an escaped quote inside a verbatim string — content stays skipped.
            Assert.AreEqual(0, Count("var s = @\"say \"\"Player\"\" now\";", "Player"));
        }

        [Test]
        public void SkipsCharLiteral()
        {
            // The '}' char literal must not confuse the scanner; the trailing code matches.
            Assert.AreEqual(1, Count("char c = '}'; Player p;", "Player"));
        }

        // ── interpolated strings ─────────────────────────────────────────────

        [Test]
        public void MatchesIdentifierInInterpolationHole()
        {
            Assert.AreEqual(1, Count("Debug.Log($\"score: {playerScore}\");", "playerScore"));
        }

        [Test]
        public void SkipsInterpolationTextButMatchesHole()
        {
            // "Player" appears as literal text (skip) and as a hole identifier (match).
            Assert.AreEqual(1, Count("Debug.Log($\"Player = {Player}\");", "Player"));
        }

        [Test]
        public void SkipsEscapedBracesInInterpolation()
        {
            // {{ and }} are literal braces — Player here is string text, not a hole.
            Assert.AreEqual(0, Count("Debug.Log($\"{{Player}}\");", "Player"));
        }

        [Test]
        public void HandlesNestedInterpolation()
        {
            // $"{Foo($"{Bar}")}" — both are in code holes.
            string src = "Debug.Log($\"{Foo($\"{Bar}\")}\");";
            Assert.AreEqual(1, Count(src, "Foo"));
            Assert.AreEqual(1, Count(src, "Bar"));
        }

        [Test]
        public void TernaryInsideHoleIsCode()
        {
            // The ':' is a ternary, not a format specifier — both branches are code.
            string src = "Debug.Log($\"{flag ? win : lose}\");";
            Assert.AreEqual(1, Count(src, "win"));
            Assert.AreEqual(1, Count(src, "lose"));
        }

        [Test]
        public void VerbatimInterpolationHole()
        {
            Assert.AreEqual(1, Count("var s = $@\"path {dirName}\";", "dirName"));
            Assert.AreEqual(0, Count("var s = $@\"path {dirName}\";", "path"));
        }

        // ── occurrence line/column ───────────────────────────────────────────

        [Test]
        public void ReportsLineAndColumn()
        {
            string src = "int a;\nPlayer p;\n";
            var occ = CSharpLexicalScanner.FindOccurrences(src, "Player");
            Assert.AreEqual(1, occ.Count);
            Assert.AreEqual(2, occ[0].Line);
            Assert.AreEqual(1, occ[0].Column);
        }

        // ── rewrite (rename) ─────────────────────────────────────────────────

        [Test]
        public void Rewrite_RenamesOnlyCodeOccurrences()
        {
            string src = "Player p = new Player(); // Player comment\nvar s = \"Player\";";
            string outp = CSharpLexicalScanner.Rewrite(src, "Player", "Hero", out int count);
            Assert.AreEqual(2, count);                       // only the two code uses
            Assert.IsTrue(outp.Contains("Hero p = new Hero()"));
            Assert.IsTrue(outp.Contains("// Player comment"));  // comment untouched
            Assert.IsTrue(outp.Contains("\"Player\""));         // string untouched
        }

        [Test]
        public void Rewrite_RenamesInterpolationHoleNotText()
        {
            string src = "Debug.Log($\"Player = {Player}\");";
            string outp = CSharpLexicalScanner.Rewrite(src, "Player", "Hero", out int count);
            Assert.AreEqual(1, count);
            Assert.AreEqual("Debug.Log($\"Player = {Hero}\");", outp);
        }

        [Test]
        public void Rewrite_NoMatch_ReturnsSameStringZeroCount()
        {
            string src = "int a = 1;";
            string outp = CSharpLexicalScanner.Rewrite(src, "Player", "Hero", out int count);
            Assert.AreEqual(0, count);
            Assert.AreSame(src, outp);
        }

        [Test]
        public void EmptyAndNullInputsAreSafe()
        {
            Assert.AreEqual(0, Count("", "Player"));
            Assert.AreEqual(0, Count(null, "Player"));
            Assert.AreEqual(0, Count("Player", ""));
            Assert.AreEqual(0, Count("Player", null));
        }
    }
}
