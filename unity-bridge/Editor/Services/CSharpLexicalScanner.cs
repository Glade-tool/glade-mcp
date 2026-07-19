using System;
using System.Collections.Generic;
using System.Text;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// A lexical (not semantic) scanner for C# source. It walks the raw text and
    /// classifies every character as CODE or non-code (comment / string / char /
    /// verbatim literal), so callers can match or rewrite <b>whole identifiers only
    /// in code regions</b> — never inside a string like <c>"Player"</c> or a
    /// <c>// Player</c> comment, which is the false-positive class a plain regex
    /// over the file content cannot avoid.
    ///
    /// Identifiers inside interpolated-string holes (<c>$"score: {playerScore}"</c>)
    /// ARE code and are seen, so a rename stays correct across interpolation.
    ///
    /// This is deliberately dependency-free (no Roslyn / no Microsoft.CodeAnalysis
    /// DLLs to ship into the package). It is a lexer, not a parser: it does NOT
    /// bind identifiers to symbols, so it cannot tell two distinct things that
    /// share a name apart (a <c>Player</c> type vs a local variable named
    /// <c>Player</c>). That semantic disambiguation is a future layer; for the
    /// common refactor ("rename this symbol everywhere") the lexical pass is
    /// correct and vastly more precise than substring/regex matching.
    ///
    /// Known lexical limitations (rare in gameplay code, documented, not bugs):
    ///   - Raw string literals (<c>"""…"""</c>, C# 11) are not special-cased —
    ///     Unity's compiler targets an older language version where they do not
    ///     appear.
    ///   - Interpolation format specifiers (<c>$"{v:F2}"</c>) are treated as code,
    ///     so the format text after ':' could expose a spurious identifier. We do
    ///     NOT special-case ':' because it is ambiguous with a ternary inside a
    ///     hole (<c>$"{a ? b : c}"</c>), and keeping real code correct matters more.
    ///   - Verbatim identifiers (<c>@event</c>) are matched without the leading '@'.
    /// </summary>
    public static class CSharpLexicalScanner
    {
        /// <summary>One whole-identifier occurrence in a code region.</summary>
        public struct Occurrence
        {
            public int Index;   // char offset of the identifier's first char
            public int Line;    // 1-based line number
            public int Column;  // 1-based column within the line
        }

        private static bool IsIdentStart(char c) => char.IsLetter(c) || c == '_';
        private static bool IsIdentPart(char c) => char.IsLetterOrDigit(c) || c == '_';

        /// <summary>
        /// True if <paramref name="s"/> is a syntactically valid C# identifier: a
        /// letter or '_' followed by letters, digits, or '_'. (The '@'-verbatim
        /// prefix and Unicode escapes are intentionally out of scope.) Callers use
        /// this to reject a rename target or a find_references symbol that could
        /// never be a real code identifier before scanning the project.
        /// </summary>
        public static bool IsValidIdentifier(string s)
        {
            if (string.IsNullOrEmpty(s) || !IsIdentStart(s[0]))
                return false;
            for (int i = 1; i < s.Length; i++)
            {
                if (!IsIdentPart(s[i]))
                    return false;
            }
            return true;
        }

        /// <summary>
        /// Interpolated-string context. <see cref="HoleDepth"/> == 0 means we are in
        /// the literal-text portion (skip); &gt; 0 means we are inside <c>{ … }</c>
        /// holes, i.e. code. A stack of these handles nested interpolation.
        /// </summary>
        private struct Interp
        {
            public bool Verbatim;
            public int HoleDepth;
        }

        /// <summary>
        /// Return the (start, length) span of every identifier token that lies in a
        /// code region. Identifiers are maximal <c>[A-Za-z0-9_]</c> runs starting
        /// with a letter or '_', so "whole identifier" falls out for free:
        /// <c>PlayerController</c> is one span, never matched by a search for
        /// <c>Player</c>, and <c>foo.Player</c> yields two spans (<c>foo</c>,
        /// <c>Player</c>).
        /// </summary>
        internal static List<(int start, int len)> CodeIdentifierSpans(string s)
        {
            var spans = new List<(int, int)>();
            if (string.IsNullOrEmpty(s))
                return spans;

            int n = s.Length;
            // Stack of enclosing interpolated strings; last = innermost.
            var interp = new List<Interp>();
            int i = 0;

            while (i < n)
            {
                // In the literal-text portion of an interpolated string → skip text,
                // but watch for the closing quote and the '{' that opens a code hole.
                if (interp.Count > 0 && interp[interp.Count - 1].HoleDepth == 0)
                {
                    Interp top = interp[interp.Count - 1];
                    char c = s[i];

                    if (c == '"')
                    {
                        // "" is an escaped quote in a verbatim interpolated string.
                        if (top.Verbatim && i + 1 < n && s[i + 1] == '"') { i += 2; continue; }
                        interp.RemoveAt(interp.Count - 1); // string closed
                        i++;
                        continue;
                    }
                    if (!top.Verbatim && c == '\\' && i + 1 < n) { i += 2; continue; } // escape
                    if (c == '{')
                    {
                        if (i + 1 < n && s[i + 1] == '{') { i += 2; continue; } // {{ literal brace
                        top.HoleDepth = 1;                 // open a code hole
                        interp[interp.Count - 1] = top;
                        i++;
                        continue;
                    }
                    if (c == '}')
                    {
                        if (i + 1 < n && s[i + 1] == '}') { i += 2; continue; } // }} literal brace
                        i++;
                        continue;
                    }
                    i++; // ordinary string-text char
                    continue;
                }

                // Otherwise we are in CODE (top level, or inside an interpolation hole).
                char ch = s[i];

                // Line comment
                if (ch == '/' && i + 1 < n && s[i + 1] == '/')
                {
                    i += 2;
                    while (i < n && s[i] != '\n') i++;
                    continue;
                }
                // Block comment
                if (ch == '/' && i + 1 < n && s[i + 1] == '*')
                {
                    i += 2;
                    while (i + 1 < n && !(s[i] == '*' && s[i + 1] == '/')) i++;
                    i = Math.Min(n, i + 2);
                    continue;
                }

                // Interpolated string: $"…", $@"…", @$"…"
                if (ch == '$')
                {
                    int j = i + 1;
                    bool verb = false;
                    if (j < n && s[j] == '@') { verb = true; j++; }
                    if (j < n && s[j] == '"')
                    {
                        interp.Add(new Interp { Verbatim = verb, HoleDepth = 0 });
                        i = j + 1;
                        continue;
                    }
                    i++; // lone '$'
                    continue;
                }
                if (ch == '@' && i + 1 < n && s[i + 1] == '$')
                {
                    if (i + 2 < n && s[i + 2] == '"')
                    {
                        interp.Add(new Interp { Verbatim = true, HoleDepth = 0 });
                        i += 3;
                        continue;
                    }
                    i++;
                    continue;
                }
                // Verbatim string @"…"
                if (ch == '@' && i + 1 < n && s[i + 1] == '"')
                {
                    i += 2;
                    while (i < n)
                    {
                        if (s[i] == '"')
                        {
                            if (i + 1 < n && s[i + 1] == '"') { i += 2; continue; } // "" escaped
                            i++;
                            break;
                        }
                        i++;
                    }
                    continue;
                }
                // Regular string "…"
                if (ch == '"')
                {
                    i++;
                    while (i < n)
                    {
                        if (s[i] == '\\' && i + 1 < n) { i += 2; continue; }
                        if (s[i] == '"') { i++; break; }
                        if (s[i] == '\n') break; // unterminated — bail defensively
                        i++;
                    }
                    continue;
                }
                // Char literal '…'
                if (ch == '\'')
                {
                    i++;
                    while (i < n)
                    {
                        if (s[i] == '\\' && i + 1 < n) { i += 2; continue; }
                        if (s[i] == '\'') { i++; break; }
                        if (s[i] == '\n') break;
                        i++;
                    }
                    continue;
                }

                // Brace tracking while inside an interpolation hole.
                if (interp.Count > 0 && interp[interp.Count - 1].HoleDepth > 0)
                {
                    if (ch == '{')
                    {
                        Interp top = interp[interp.Count - 1];
                        top.HoleDepth++;
                        interp[interp.Count - 1] = top;
                        i++;
                        continue;
                    }
                    if (ch == '}')
                    {
                        Interp top = interp[interp.Count - 1];
                        top.HoleDepth--; // may return to 0 → back to string text next iteration
                        interp[interp.Count - 1] = top;
                        i++;
                        continue;
                    }
                }

                // Identifier token
                if (IsIdentStart(ch))
                {
                    int start = i;
                    i++;
                    while (i < n && IsIdentPart(s[i])) i++;
                    spans.Add((start, i - start));
                    continue;
                }

                i++; // any other code char
            }

            return spans;
        }

        /// <summary>Every whole-identifier occurrence of <paramref name="symbol"/> in a code region, with line/column.</summary>
        public static List<Occurrence> FindOccurrences(string source, string symbol)
        {
            var result = new List<Occurrence>();
            if (string.IsNullOrEmpty(source) || string.IsNullOrEmpty(symbol))
                return result;

            var spans = CodeIdentifierSpans(source);
            if (spans.Count == 0)
                return result;

            // Precompute line starts for O(1)-ish line/column lookup.
            foreach (var (start, len) in spans)
            {
                if (len != symbol.Length)
                    continue;
                if (string.CompareOrdinal(source, start, symbol, 0, len) != 0)
                    continue;
                ComputeLineColumn(source, start, out int line, out int col);
                result.Add(new Occurrence { Index = start, Line = line, Column = col });
            }
            return result;
        }

        /// <summary>Count of whole-identifier occurrences of <paramref name="symbol"/> in code regions (no allocation of line data).</summary>
        public static int CountOccurrences(string source, string symbol)
        {
            if (string.IsNullOrEmpty(source) || string.IsNullOrEmpty(symbol))
                return 0;
            int count = 0;
            foreach (var (start, len) in CodeIdentifierSpans(source))
            {
                if (len == symbol.Length && string.CompareOrdinal(source, start, symbol, 0, len) == 0)
                    count++;
            }
            return count;
        }

        /// <summary>
        /// Replace every code-region whole-identifier <paramref name="oldName"/> with
        /// <paramref name="newName"/>, leaving strings, comments, and char literals
        /// untouched. Returns the rewritten source; <paramref name="count"/> is the
        /// number of replacements made.
        /// </summary>
        public static string Rewrite(string source, string oldName, string newName, out int count)
        {
            count = 0;
            if (string.IsNullOrEmpty(source) || string.IsNullOrEmpty(oldName))
                return source;

            var spans = CodeIdentifierSpans(source);
            var sb = new StringBuilder(source.Length + 16);
            int cursor = 0;
            foreach (var (start, len) in spans)
            {
                if (len != oldName.Length || string.CompareOrdinal(source, start, oldName, 0, len) != 0)
                    continue;
                sb.Append(source, cursor, start - cursor); // text before the match, verbatim
                sb.Append(newName);
                cursor = start + len;
                count++;
            }
            sb.Append(source, cursor, source.Length - cursor); // tail
            return count == 0 ? source : sb.ToString();
        }

        private static void ComputeLineColumn(string source, int index, out int line, out int column)
        {
            line = 1;
            int lastNewline = -1;
            for (int k = 0; k < index; k++)
            {
                if (source[k] == '\n')
                {
                    line++;
                    lastNewline = k;
                }
            }
            column = index - lastNewline; // 1-based
        }
    }
}
