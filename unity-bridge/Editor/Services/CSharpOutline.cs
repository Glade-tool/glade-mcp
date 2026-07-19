using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Extracts a lightweight structural outline from a C# source file — its top-level
    /// types and their direct members (methods, properties) with line numbers — so a
    /// caller can navigate a large file before deciding which lines to actually read.
    ///
    /// It runs over a "blanked" copy of the source (<see cref="CSharpLexicalScanner.BlankNonCode"/>
    /// spaces out strings/comments), so declarations are never matched inside a string or
    /// comment. Member declarations are recognized only when the current brace depth sits
    /// directly inside a type body — that is what keeps a method CALL in a method body
    /// (one level deeper) from being mistaken for a declaration.
    ///
    /// This is a heuristic navigation aid, not a parser: it favors the reliable anchors
    /// (types + methods + simple properties) and may miss exotic declarations. Fields and
    /// local variables are intentionally omitted to keep the outline readable.
    /// </summary>
    public static class CSharpOutline
    {
        private static readonly Regex TypeRe =
            new Regex(@"\b(class|struct|interface|enum|record)\s+([A-Za-z_]\w*)");
        private static readonly Regex PropRe =
            new Regex(@"([A-Za-z_]\w*)\s*(\{|=>)");
        private static readonly Regex TrailingIdent =
            new Regex(@"([A-Za-z_]\w*)\s*$");

        // Words that can sit immediately before '(' without being a method declaration —
        // control flow, casts, and expression keywords. Filters out the common call/keyword
        // false positives that survive the depth check.
        private static readonly HashSet<string> KeywordsBeforeParen = new HashSet<string>
        {
            "if", "for", "while", "switch", "foreach", "catch", "using", "lock", "return",
            "fixed", "yield", "do", "else", "when", "sizeof", "typeof", "nameof", "new",
            "await", "in", "is", "as", "base", "this",
        };

        private struct TypeCtx
        {
            public int DeclDepth;
            public bool Entered;
        }

        /// <summary>
        /// Returns one dictionary per symbol: <c>{ kind, name, line, signature }</c>, in
        /// source order. <c>kind</c> is one of class/struct/interface/enum/record/method/property.
        /// </summary>
        public static List<Dictionary<string, object>> Extract(string source)
        {
            var symbols = new List<Dictionary<string, object>>();
            if (string.IsNullOrEmpty(source))
                return symbols;

            string blanked = CSharpLexicalScanner.BlankNonCode(source);
            string[] lines = blanked.Split('\n');
            string[] rawLines = source.Split('\n');

            int depth = 0;
            var typeStack = new List<TypeCtx>();

            for (int idx = 0; idx < lines.Length; idx++)
            {
                string bline = lines[idx];
                string stripped = bline.Trim();
                int lineNo = idx + 1;
                int opens = CountChar(bline, '{');
                int closes = CountChar(bline, '}');
                int curDepth = depth;

                bool insideType = typeStack.Count > 0
                    && typeStack[typeStack.Count - 1].Entered
                    && curDepth == typeStack[typeStack.Count - 1].DeclDepth + 1;

                Match tm = TypeRe.Match(bline);
                if (tm.Success)
                {
                    symbols.Add(MakeSymbol(tm.Groups[1].Value, tm.Groups[2].Value, lineNo, rawLines, idx));
                    typeStack.Add(new TypeCtx { DeclDepth = curDepth, Entered = false });
                }
                else if (insideType)
                {
                    string mname = MethodNameBeforeParen(bline);
                    if (mname != null && (stripped.EndsWith("{") || stripped.EndsWith(";")
                        || stripped.Contains("=>") || stripped.EndsWith(")") || stripped.EndsWith(",")))
                    {
                        symbols.Add(MakeSymbol("method", mname, lineNo, rawLines, idx));
                    }
                    else
                    {
                        Match pm = PropRe.Match(bline);
                        if (pm.Success && bline.Substring(0, pm.Groups[2].Index).IndexOf('(') < 0)
                            symbols.Add(MakeSymbol("property", pm.Groups[1].Value, lineNo, rawLines, idx));
                    }
                }

                depth += opens - closes;

                // A type is "entered" once we descend past its declaration depth — this is
                // what lets an Allman-brace type (brace on the next line) survive until its
                // body actually opens instead of being popped immediately.
                if (typeStack.Count > 0)
                {
                    TypeCtx t = typeStack[typeStack.Count - 1];
                    if (!t.Entered && depth > t.DeclDepth)
                    {
                        t.Entered = true;
                        typeStack[typeStack.Count - 1] = t;
                    }
                }
                while (typeStack.Count > 0
                    && typeStack[typeStack.Count - 1].Entered
                    && depth <= typeStack[typeStack.Count - 1].DeclDepth)
                {
                    typeStack.RemoveAt(typeStack.Count - 1);
                }
            }

            return symbols;
        }

        // The method name is the identifier immediately before '(', after stripping a
        // trailing generic clause (Foo<T>(…) → Foo). Returns null when the token is a
        // keyword (so `if (`, `for (`, `return (` are not treated as declarations).
        private static string MethodNameBeforeParen(string codeLine)
        {
            int p = codeLine.IndexOf('(');
            if (p < 0)
                return null;
            string head = codeLine.Substring(0, p).TrimEnd();
            if (head.EndsWith(">"))
            {
                int d = 0, k = head.Length - 1;
                while (k >= 0)
                {
                    if (head[k] == '>') d++;
                    else if (head[k] == '<')
                    {
                        d--;
                        if (d == 0) { head = head.Substring(0, k).TrimEnd(); break; }
                    }
                    k--;
                }
            }
            Match m = TrailingIdent.Match(head);
            if (!m.Success)
                return null;
            string name = m.Groups[1].Value;
            return KeywordsBeforeParen.Contains(name) ? null : name;
        }

        private static Dictionary<string, object> MakeSymbol(string kind, string name, int line, string[] rawLines, int idx)
        {
            string sig = idx < rawLines.Length ? rawLines[idx].Trim() : "";
            if (sig.Length > 200)
                sig = sig.Substring(0, 200);
            return new Dictionary<string, object>
            {
                { "kind", kind },
                { "name", name },
                { "line", line },
                { "signature", sig },
            };
        }

        private static int CountChar(string s, char c)
        {
            int n = 0;
            foreach (char ch in s)
                if (ch == c) n++;
            return n;
        }
    }
}
