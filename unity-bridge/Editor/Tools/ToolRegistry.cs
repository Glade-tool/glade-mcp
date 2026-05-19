using System.Collections.Generic;
using System.Linq;
using GladeAgenticAI.Core.Tools;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Central registry for all AI tools. Implements the Command Pattern to
    /// decouple tool execution from tool definition.
    ///
    /// The tool registration block was previously a single ~320-line method
    /// inside this file. It is now split across partial-class files under
    /// Registrars/ — each owns one category and is a small focused edit when
    /// adding tools. The dispatch order in InitializeIfNeeded() determines
    /// shadowing behavior when two tools share a name (last wins via
    /// Register's overwrite semantics).
    /// </summary>
    public partial class ToolRegistry
    {
        private readonly Dictionary<string, ITool> _tools = new Dictionary<string, ITool>();
        private bool _isInitialized = false;

        /// <summary>
        /// Registers a tool instance. Last-registration-wins if the name collides,
        /// which lets later registrars deliberately override earlier defaults.
        /// </summary>
        public void Register(ITool tool)
        {
            if (tool == null) return;
            if (!_tools.ContainsKey(tool.Name))
                _tools.Add(tool.Name, tool);
            else
                _tools[tool.Name] = tool;
        }

        /// <summary>Retrieves a tool by name.</summary>
        public ITool GetTool(string name)
        {
            InitializeIfNeeded();
            return _tools.TryGetValue(name, out var tool) ? tool : null;
        }

        /// <summary>Gets all registered tool names.</summary>
        public List<string> GetAllToolNames()
        {
            InitializeIfNeeded();
            return _tools.Keys.ToList();
        }

        private void InitializeIfNeeded()
        {
            if (_isInitialized) return;

            RegisterSceneAndAssetTools();
            RegisterComponentAndPrefabTools();
            RegisterMaterialAndRenderingTools();
            RegisterPhysicsTools();
            RegisterAnimationTools();
            RegisterRuntimeAndDiagnosticsTools();
            RegisterUIAndInputTools();
            RegisterTerrainAndNavMeshTools();

            _isInitialized = true;
        }
    }
}
