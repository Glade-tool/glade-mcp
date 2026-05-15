using System.Runtime.CompilerServices;

// Surface bridge internals to the NUnit Edit Mode test assembly so unit tests
// can reach pure helpers (e.g. host-allowlist filtering on PBR texture URLs)
// without going through the full IAsyncTool dispatch path. The test assembly
// already references GladeKit.Bridge — this attribute is what lifts the
// `internal` visibility ceiling.
[assembly: InternalsVisibleTo("GladeKit.Bridge.Tests")]
