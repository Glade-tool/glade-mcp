using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Tests
{
    /// <summary>
    /// Coverage for the C# file-outline extractor that powers get_script_content's outline
    /// mode. It must surface types + methods + properties with correct line numbers, and —
    /// critically — NOT mistake a method CALL inside a method body for a declaration (the
    /// depth check), nor pick up text inside strings/comments (the blanked-source pass).
    /// Pure logic, EditMode, no bridge dependency.
    /// </summary>
    public class CSharpOutline_Tests
    {
        private const string Sample =
            "using UnityEngine;\n" +
            "\n" +
            "namespace Game.Player\n" +
            "{\n" +
            "    // The main controller\n" +
            "    public class PlayerController : MonoBehaviour\n" +
            "    {\n" +
            "        public int MaxHealth = 100;\n" +
            "        private float _speed = 5f;\n" +
            "\n" +
            "        public int Health { get; private set; }\n" +
            "\n" +
            "        void Start()\n" +
            "        {\n" +
            "            Health = MaxHealth;\n" +
            "            Debug.Log($\"start {Health}\");   // Update( here is a call in a string\n" +
            "        }\n" +
            "\n" +
            "        public void TakeDamage(int amount)\n" +
            "        {\n" +
            "            Health -= amount;\n" +
            "            if (Health <= 0) Die();\n" +
            "        }\n" +
            "\n" +
            "        int Compute<T>(T value) => value.GetHashCode();\n" +
            "\n" +
            "        private void Die()\n" +
            "        {\n" +
            "            Destroy(gameObject);\n" +
            "        }\n" +
            "    }\n" +
            "\n" +
            "    public enum Team { Red, Blue }\n" +
            "}\n";

        private static List<Dictionary<string, object>> Outline(string src) => CSharpOutline.Extract(src);

        private static bool Has(List<Dictionary<string, object>> o, string kind, string name) =>
            o.Any(s => (string)s["kind"] == kind && (string)s["name"] == name);

        private static Dictionary<string, object> Get(List<Dictionary<string, object>> o, string name) =>
            o.First(s => (string)s["name"] == name);

        [Test]
        public void FindsTypesMethodsAndProperties()
        {
            var o = Outline(Sample);
            Assert.IsTrue(Has(o, "class", "PlayerController"));
            Assert.IsTrue(Has(o, "property", "Health"));
            Assert.IsTrue(Has(o, "method", "Start"));
            Assert.IsTrue(Has(o, "method", "TakeDamage"));
            Assert.IsTrue(Has(o, "method", "Die"));
            Assert.IsTrue(Has(o, "enum", "Team"));
        }

        [Test]
        public void GenericMethodNameStrippedOfTypeArgs()
        {
            // int Compute<T>(...) → name is "Compute", not "T".
            var o = Outline(Sample);
            Assert.IsTrue(Has(o, "method", "Compute"));
            Assert.IsFalse(Has(o, "method", "T"));
        }

        [Test]
        public void DoesNotTreatCallsInsideBodiesAsDeclarations()
        {
            // Debug.Log / Destroy / GetHashCode are calls one level deeper than the type body.
            var o = Outline(Sample);
            Assert.IsFalse(Has(o, "method", "Log"));
            Assert.IsFalse(Has(o, "method", "Destroy"));
            Assert.IsFalse(Has(o, "method", "GetHashCode"));
        }

        [Test]
        public void ReportsCorrectLineNumbers()
        {
            var o = Outline(Sample);
            Assert.AreEqual(6, (int)Get(o, "PlayerController")["line"]);
            Assert.AreEqual(13, (int)Get(o, "Start")["line"]);
            Assert.AreEqual(33, (int)Get(o, "Team")["line"]);
        }

        [Test]
        public void SignatureIsTheTrimmedSourceLine()
        {
            var start = Get(Outline(Sample), "Start");
            Assert.AreEqual("void Start()", (string)start["signature"]);
        }

        [Test]
        public void HandlesKAndRBraceStyle()
        {
            // Brace on the same line as the type declaration.
            string src = "public class Foo {\n    public void Bar() { }\n}\n";
            var o = Outline(src);
            Assert.IsTrue(Has(o, "class", "Foo"));
            Assert.IsTrue(Has(o, "method", "Bar"));
        }

        [Test]
        public void EmptyOrNullIsSafe()
        {
            Assert.AreEqual(0, Outline("").Count);
            Assert.AreEqual(0, Outline(null).Count);
        }
    }
}
