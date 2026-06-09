using NUnit.Framework;
using GladeAgenticAI.Bridge;

namespace GladeAgenticAI.Tests
{
    /// Local-only access control for the bridge HTTP server. The server binds
    /// to localhost, but a web page the user visits can still target
    /// http://localhost:8765 directly, and DNS-rebinding can point a remote
    /// name at 127.0.0.1. These guards reject both without disturbing the
    /// native clients (which send no Origin) or the desktop UI (allowlisted).
    public class UnityBridgeServer_AccessControl
    {
        // ── Host header (DNS-rebinding defense) ──────────────────────────────

        [Test]
        public void Host_AllowsLocalhostWithPort()
        {
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("localhost:8765"));
        }

        [Test]
        public void Host_AllowsLoopbackIpWithPort()
        {
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("127.0.0.1:8765"));
        }

        [Test]
        public void Host_AllowsBareLocalhost()
        {
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("localhost"));
        }

        [Test]
        public void Host_AllowsIpv6Loopback()
        {
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("[::1]:8765"));
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("::1"));
        }

        [Test]
        public void Host_IsCaseInsensitive()
        {
            Assert.IsTrue(UnityBridgeServer.IsHostAllowed("LOCALHOST:8765"));
        }

        [Test]
        public void Host_RejectsRebindingHost()
        {
            Assert.IsFalse(UnityBridgeServer.IsHostAllowed("evil.com:8765"));
            Assert.IsFalse(UnityBridgeServer.IsHostAllowed("attacker.example.com"));
        }

        [Test]
        public void Host_RejectsMissing()
        {
            Assert.IsFalse(UnityBridgeServer.IsHostAllowed(null));
            Assert.IsFalse(UnityBridgeServer.IsHostAllowed(""));
        }

        // ── Origin (browser drive-by defense) ────────────────────────────────

        [Test]
        public void Origin_AllowsNoOrigin_NativeClient()
        {
            // MCP server / editor / curl send no Origin — must pass.
            Assert.IsTrue(UnityBridgeServer.IsOriginAllowed(null));
            Assert.IsTrue(UnityBridgeServer.IsOriginAllowed(""));
        }

        [Test]
        public void Origin_AllowsDevServer()
        {
            Assert.IsTrue(UnityBridgeServer.IsOriginAllowed("http://localhost:5173"));
            Assert.IsTrue(UnityBridgeServer.IsOriginAllowed("http://127.0.0.1:5173"));
        }

        [Test]
        public void Origin_AllowsPackagedFileOrigin()
        {
            // A packaged desktop UI loads its page from file://, which the
            // browser reports as the opaque origin "null".
            Assert.IsTrue(UnityBridgeServer.IsOriginAllowed("null"));
        }

        [Test]
        public void Origin_RejectsDriveByWebPage()
        {
            Assert.IsFalse(UnityBridgeServer.IsOriginAllowed("https://evil.com"));
            Assert.IsFalse(UnityBridgeServer.IsOriginAllowed("http://evil.com"));
        }

        [Test]
        public void Origin_RejectsOtherLocalhostPorts()
        {
            // A malicious page served from another local port is still hostile.
            Assert.IsFalse(UnityBridgeServer.IsOriginAllowed("http://localhost:31337"));
        }
    }
}
