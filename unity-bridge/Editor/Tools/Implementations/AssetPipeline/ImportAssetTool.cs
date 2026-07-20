using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using UnityEditor;
using UnityEngine;
using GladeAgenticAI.Core.Tools;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.AssetPipeline
{
    /// <summary>
    /// Downloads an external asset (URL resolved by an upstream
    /// <c>asset_pipeline</c> preprocessor), places it under
    /// <c>Assets/&lt;targetPath&gt;/</c>, configures Unity import settings for the
    /// asset type, and writes a <c>.gladekit-asset.json</c> sidecar with license
    /// + attribution metadata for later audit.
    ///
    /// Args (preprocessor-injected unless marked LLM):
    ///   candidateId         (LLM)          stable id from find_asset, e.g. "kenney/tiny-town"
    ///   targetPath          (LLM)          destination folder under Assets/, e.g. "Assets/Sprites/tiny-town/"
    ///   licenseAcknowledged (LLM)          must be true; license gate
    ///   _resolvedUrl        (preprocessor) direct download URL (LLM never sees this)
    ///   _resolvedLicense    (preprocessor) normalized license code, e.g. "CC0-1.0"
    ///   _resolvedAttribution(preprocessor) attribution string (recorded in sidecar)
    ///   _resolvedArchiveFormat (preprocessor) "zip" | null  (only zip supported in v0)
    ///   _resolvedFileExtension (preprocessor) for single-file: ".png" / ".wav" / ".fbx"
    ///   assetType           (LLM)          one of sprite_2d, model_3d, audio_sfx, ui_sprite, audio_music
    ///   importOptions       (LLM)          optional asset-type-specific overrides
    ///
    /// Security — the underscore-prefixed fields MUST be set by the
    /// asset_pipeline preprocessor on the calling client, not by the LLM.
    /// The tool schema exposed to the model does not document them. Three
    /// defense layers guard the download:
    ///   1. The client-side preprocessor strips any caller-supplied
    ///      underscore-prefixed fields before resolving against the trusted
    ///      catalog.
    ///   2. The bridge refuses calls with an empty _resolvedUrl (preprocessor
    ///      didn't run).
    ///   3. The bridge validates _resolvedUrl's host against
    ///      AssetPipelineGuard.IsResolvedUrlHostAllowed for the candidate's
    ///      provider prefix — so even a client bypassing its own preprocessor
    ///      can't smuggle in an arbitrary download URL.
    /// </summary>
    public class ImportAssetTool : IAsyncTool
    {
        public string Name => "import_asset";

        // 60s timeout matches the typical per-tool HTTP budget for an MCP
        // client round-trip. Most Kenney packs are 1-15MB and download in
        // <5s on broadband.
        private const int DownloadTimeoutSeconds = 60;

        // Cap to avoid a runaway download claiming gigabytes of disk before we notice.
        // Largest legitimate Kenney pack is ~120MB (full 3D voxel sets); cap at 250MB.
        private const long MaxDownloadBytes = 250L * 1024L * 1024L;

        /// <summary>
        /// Sync fallback for callers that bypass the async dispatch path
        /// (notably <c>batch_execute</c>). Runs the same state machine but
        /// polls in a tight loop — the Editor freezes for the duration, same
        /// as the legacy implementation. Single-call dispatch via
        /// <c>HandleToolExecute</c> takes the async path through
        /// <see cref="BeginExecute"/> and the Editor stays responsive.
        /// </summary>
        public string Execute(Dictionary<string, object> args)
        {
            var handle = BeginExecute(args);
            try
            {
                while (true)
                {
                    string result = handle.PollResult();
                    if (result != null) return result;
                    Thread.Sleep(50);
                }
            }
            finally
            {
                handle.Dispose();
            }
        }

        /// <summary>
        /// Validate args + preprocessor-injected fields synchronously, then
        /// hand control to <see cref="ImportAssetHandle"/>. The bridge polls
        /// the returned handle each <c>EditorApplication.update</c> tick so
        /// the Editor pump runs between network polls — no Editor freeze.
        /// Any validation failure short-circuits via a pre-completed handle
        /// whose first <c>PollResult</c> returns the error envelope.
        /// </summary>
        public IAsyncToolHandle BeginExecute(Dictionary<string, object> args)
        {
            string disabled = AssetPipelineGuard.RejectIfDisabled();
            if (disabled != null) return ImportAssetHandle.Failed(disabled);

            if (args == null)
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse("args required"));

            // ── LLM-supplied fields ──────────────────────────────────────────
            string candidateId = TryGetString(args, "candidateId");
            if (string.IsNullOrEmpty(candidateId))
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse("candidateId is required"));

            bool licenseAck = ToolUtils.ParseBool(args.TryGetValue("licenseAcknowledged", out var lao) ? lao : null);
            if (!licenseAck)
            {
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse(
                    "licenseAcknowledged must be true. The user must confirm they accept " +
                    "the asset's license (shown in the find_asset preview) before import."));
            }

            string assetType = TryGetString(args, "assetType");
            if (string.IsNullOrEmpty(assetType))
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse("assetType is required"));

            string targetPath = TryGetString(args, "targetPath");
            if (string.IsNullOrEmpty(targetPath))
                targetPath = DefaultTargetPath(assetType, candidateId);
            targetPath = NormalizeTargetPath(targetPath);
            if (!targetPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse("targetPath must start with 'Assets/'"));
            if (!ToolUtils.IsAssetPathSafe(targetPath))
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse("targetPath must not contain directory traversal ('..')."));

            // ── Client-resolved fields ───────────────────────────────────────
            // The caller (an MCP client or other orchestrator) populates these
            // `_resolved*` keys after looking the candidate up in its catalog
            // / provider index. The bridge never resolves URLs itself — it only
            // accepts URLs that pass `AssetPipelineGuard.DescribeUrlHostRejection`.
            string resolvedUrl = TryGetString(args, "_resolvedUrl");
            string resolvedLicense = TryGetString(args, "_resolvedLicense");
            string resolvedAttribution = TryGetString(args, "_resolvedAttribution");
            string archiveFormat = TryGetString(args, "_resolvedArchiveFormat");
            string fileExtension = TryGetString(args, "_resolvedFileExtension");
            // Provider id ("meshy" | "kenney" | …) — drives provider-specific importer
            // presets. Empty when the client doesn't supply it; ConfigureModelImporter
            // falls back to format-only defaults.
            string resolvedProvider = TryGetString(args, "_resolvedProvider");
            // Optional: JSON-encoded list of PBR texture URL sets. Populated for
            // generative providers (Meshy) whose model file doesn't embed textures.
            // Format: [{"base_color": "...", "metallic": "...", "normal": "...", "roughness": "..."}]
            // (one entry per material). The bridge downloads each set into a
            // Textures/ subfolder and binds the maps to the extracted URP material.
            string resolvedTextureUrlsJson = TryGetString(args, "_resolvedTextureUrls");

            if (string.IsNullOrEmpty(resolvedUrl))
            {
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse(
                    "Resolved download URL missing — the asset_pipeline preprocessor did " +
                    "not run before this import_asset call reached the bridge. Either call " +
                    "find_asset first (which produces the candidateId), or check that the " +
                    "MCP server / client invoking the bridge supports asset_pipeline " +
                    "preprocessing (com.gladekit.mcp-bridge requires a matching gladekit-mcp " +
                    "version)."));
            }

            string hostRejection = AssetPipelineGuard.DescribeUrlHostRejection(candidateId, resolvedUrl);
            if (hostRejection != null)
            {
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse(
                    $"Bridge refused the download: {hostRejection}. " +
                    "This means either (a) the URL was injected by a client bypassing its " +
                    "own asset_pipeline preprocessor, or (b) the provider's official " +
                    "download host has changed and the bridge allowlist in " +
                    "AssetPipelineGuard.cs needs updating. The bridge will not download " +
                    "from arbitrary hosts."));
            }

            // ── Optional import overrides ────────────────────────────────────
            Dictionary<string, object> importOptions = null;
            if (args.TryGetValue("importOptions", out var ioObj) && ioObj is Dictionary<string, object> ioDict)
                importOptions = ioDict;

            // ── Ensure target folder exists ──────────────────────────────────
            try
            {
                ToolUtils.EnsureAssetFolder(targetPath);
            }
            catch (Exception e)
            {
                return ImportAssetHandle.Failed(ToolUtils.CreateErrorResponse(
                    $"Failed to create target folder {targetPath}: {e.Message}"));
            }

            string tempFile = Path.Combine(
                Path.GetTempPath(),
                $"gladekit-asset-{Guid.NewGuid():N}{(archiveFormat == "zip" ? ".zip" : (fileExtension ?? ""))}");

            return new ImportAssetHandle(
                candidateId: candidateId,
                targetPath: targetPath,
                assetType: assetType,
                resolvedUrl: resolvedUrl,
                resolvedLicense: resolvedLicense,
                resolvedAttribution: resolvedAttribution,
                archiveFormat: archiveFormat,
                fileExtension: fileExtension,
                resolvedProvider: resolvedProvider,
                resolvedTextureUrlsJson: resolvedTextureUrlsJson,
                importOptions: importOptions,
                tempFile: tempFile);
        }

        // ── Download ─────────────────────────────────────────────────────────

        // ── Extraction / placement ───────────────────────────────────────────

        private static List<string> ExtractZipToProject(string zipPath, string targetPath)
        {
            var imported = new List<string>();
            string projectRoot = Directory.GetParent(Application.dataPath).FullName;
            string targetAbs = Path.Combine(projectRoot, targetPath.Replace('/', Path.DirectorySeparatorChar));

            using (var archive = ZipFile.OpenRead(zipPath))
            {
                foreach (var entry in archive.Entries)
                {
                    if (string.IsNullOrEmpty(entry.Name)) continue; // directory entry

                    // Zip-slip guard: reject entries that escape the target folder.
                    string destFull = Path.GetFullPath(Path.Combine(targetAbs, entry.FullName));
                    string targetFull = Path.GetFullPath(targetAbs);
                    if (!destFull.StartsWith(targetFull, StringComparison.OrdinalIgnoreCase))
                    {
                        Debug.LogWarning($"[GladeKit] Skipping zip entry outside target: {entry.FullName}");
                        continue;
                    }

                    Directory.CreateDirectory(Path.GetDirectoryName(destFull));
                    entry.ExtractToFile(destFull, overwrite: true);

                    // Project-relative for AssetDatabase. Avoid Path.GetRelativePath
                    // since older Unity .NET profiles don't have it; manual
                    // string manipulation works everywhere.
                    string assetsAbs = Path.Combine(projectRoot, "Assets");
                    string relFromAssets = destFull
                        .Substring(assetsAbs.Length)
                        .TrimStart(Path.DirectorySeparatorChar, '/')
                        .Replace('\\', '/');
                    imported.Add("Assets/" + relFromAssets);
                }
            }
            return imported;
        }

        private static List<string> PlaceSingleFileInProject(
            string tempFile, string targetPath, string candidateId, string fileExtension)
        {
            string projectRoot = Directory.GetParent(Application.dataPath).FullName;
            string ext = fileExtension ?? ".bin";
            string fileName = SanitizeFileName(candidateId) + ext;
            string relPath = targetPath.TrimEnd('/') + "/" + fileName;
            string absPath = Path.Combine(projectRoot, relPath.Replace('/', Path.DirectorySeparatorChar));

            Directory.CreateDirectory(Path.GetDirectoryName(absPath));
            File.Copy(tempFile, absPath, overwrite: true);

            return new List<string> { relPath };
        }

        // ── Type-specific import-settings configuration ──────────────────────

        private static int ConfigureImportSettings(
            List<string> importedFiles,
            string assetType,
            Dictionary<string, object> options,
            string provider,
            List<MeshyTexturePaths> meshyTextures)
        {
            int configured = 0;
            switch (assetType)
            {
                case "sprite_2d":
                case "ui_sprite":
                    foreach (string p in importedFiles)
                    {
                        if (!IsImageFile(p)) continue;
                        if (ConfigureSpriteImporter(p, options)) configured++;
                    }
                    break;

                case "model_3d":
                    foreach (string p in importedFiles)
                    {
                        if (!IsModelFile(p)) continue;
                        if (ConfigureModelImporter(p, options, provider, meshyTextures)) configured++;
                    }
                    break;

                case "audio_sfx":
                case "audio_music":
                    foreach (string p in importedFiles)
                    {
                        if (!IsAudioFile(p)) continue;
                        if (ConfigureAudioImporter(p, options)) configured++;
                    }
                    break;
            }
            return configured;
        }

        private static bool ConfigureSpriteImporter(string assetPath, Dictionary<string, object> options)
        {
            var importer = AssetImporter.GetAtPath(assetPath) as TextureImporter;
            if (importer == null) return false;

            importer.textureType = TextureImporterType.Sprite;
            importer.spriteImportMode = SpriteImportMode.Single;

            // Pixel-art-friendly defaults; opt-out via importOptions.
            if (options == null || !options.ContainsKey("filterMode") ||
                string.Equals(TryGetString(options, "filterMode"), "point", StringComparison.OrdinalIgnoreCase))
            {
                importer.filterMode = FilterMode.Point;
            }
            else
            {
                importer.filterMode = FilterMode.Bilinear;
            }
            importer.textureCompression = TextureImporterCompression.Uncompressed;

            if (options != null && options.TryGetValue("pixelsPerUnit", out var ppuObj))
            {
                if (TryParseFloat(ppuObj, out float ppu) && ppu > 0)
                    importer.spritePixelsPerUnit = ppu;
            }

            if (options != null && options.TryGetValue("spriteMode", out var smObj))
            {
                string sm = smObj?.ToString();
                if (string.Equals(sm, "multiple", StringComparison.OrdinalIgnoreCase))
                    importer.spriteImportMode = SpriteImportMode.Multiple;
            }

            EditorUtility.SetDirty(importer);
            importer.SaveAndReimport();
            return true;
        }

        private static bool ConfigureModelImporter(
            string assetPath,
            Dictionary<string, object> options,
            string provider,
            List<MeshyTexturePaths> meshyTextures)
        {
            var importer = AssetImporter.GetAtPath(assetPath) as ModelImporter;
            if (importer == null) return false;

            bool isMeshy = string.Equals(provider, "meshy", StringComparison.OrdinalIgnoreCase);

            // ── Meshy provider preset ────────────────────────────────────────
            // Why these defaults: Meshy exports models with a Y-up / +Y-forward
            // convention that Unity stores as a +90° X rotation on the root node
            // (model lies face-down without correction). bakeAxisConversion = true
            // bakes that rotation into the mesh data so prefabs drop in upright.
            // Materials are forced to External so we have editable .mat assets to
            // rebind to the downloaded PBR textures — without this Unity creates
            // read-only embedded materials we can't fix up.
            if (isMeshy)
            {
                importer.bakeAxisConversion = true;
                importer.useFileScale = true;
                importer.materialImportMode = ModelImporterMaterialImportMode.ImportStandard;
                // materialLocation is the documented path for emitting standalone
                // .mat assets next to the FBX. Newer Unity versions surface
                // SearchAndRemapMaterials as the modern equivalent; the property
                // still works in Unity 6 and produces the same on-disk layout.
                #pragma warning disable CS0618
                importer.materialLocation = ModelImporterMaterialLocation.External;
                #pragma warning restore CS0618
            }

            if (options != null && options.TryGetValue("scaleFactor", out var sfObj))
            {
                if (TryParseFloat(sfObj, out float sf) && sf > 0) importer.globalScale = sf;
            }

            if (options != null && options.TryGetValue("importMaterials", out var imObj))
            {
                bool import = ToolUtils.ParseBool(imObj);
                importer.materialImportMode = import ? ModelImporterMaterialImportMode.ImportStandard : ModelImporterMaterialImportMode.None;
            }

            if (options != null && options.TryGetValue("importRig", out var irObj))
            {
                bool importRig = ToolUtils.ParseBool(irObj);
                importer.animationType = importRig ? ModelImporterAnimationType.Generic : ModelImporterAnimationType.None;
            }

            EditorUtility.SetDirty(importer);
            importer.SaveAndReimport();

            // ── Post-import: bind Meshy textures to the extracted URP material ─
            // This runs AFTER the first SaveAndReimport so Unity has already
            // emitted the external .mat next to the FBX. Each step is wrapped
            // independently so a missing roughness map still leaves base color
            // + normal bound (the visual delta the user cares about most).
            if (isMeshy && meshyTextures != null && meshyTextures.Count > 0)
            {
                try
                {
                    BindMeshyTexturesToExtractedMaterials(assetPath, meshyTextures);
                }
                catch (Exception bindErr)
                {
                    Debug.LogWarning($"[GladeKit] Meshy texture binding failed for {assetPath}: {bindErr.Message}");
                }
            }

            return true;
        }

        // ── Provider texture downloads + URP material binding ────────────────

        /// <summary>
        /// Local-disk paths for one PBR texture set after download. Any field
        /// may be empty if Meshy didn't ship that map or the download failed —
        /// the binding step checks each independently.
        /// </summary>
        private class MeshyTexturePaths
        {
            public string BaseColor;
            public string Metallic;
            public string Normal;
            public string Roughness;
        }

        /// <summary>
        /// One texture-download work item produced by <see cref="BuildMeshyTextureQueue"/>.
        /// Drained one-by-one by the state machine so each network wait yields
        /// back to the Editor between polls.
        /// </summary>
        private class MeshyTextureJob
        {
            public int MatIndex;
            public string UrlKey;       // "base_color" | "metallic" | "normal" | "roughness"
            public string NameSlug;     // "baseColor" | "metallic" | "normal" | "roughness"
            public string Url;
            public string AbsPath;
            public string RelPath;
        }

        // ── Async state machine ──────────────────────────────────────────────

        /// <summary>
        /// State machine that runs the import asynchronously. Each
        /// <see cref="PollResult"/> call advances at most one phase. Network
        /// phases (model download, texture downloads) return null until the
        /// underlying <see cref="EditorAsyncDownload"/> reports IsDone — so
        /// the Editor's update loop keeps running between polls and the UI
        /// stays responsive. Synchronous phases (extract zip, configure
        /// importers, write sidecar) complete in one tick. Errors fold into
        /// a sticky final envelope via <see cref="Failed"/>.
        /// </summary>
        private sealed class ImportAssetHandle : IAsyncToolHandle
        {
            private enum Stage
            {
                StartingDownload,
                DownloadingModel,
                ExtractingAndPlacing,
                StartingTexture,
                DownloadingTexture,
                ImportingAndConfiguring,
                WritingSidecar,
                Done,
            }

            // Inputs (constant after construction)
            private readonly string _candidateId, _targetPath, _assetType, _resolvedUrl,
                _resolvedLicense, _resolvedAttribution, _archiveFormat, _fileExtension,
                _resolvedProvider, _resolvedTextureUrlsJson, _tempFile;
            private readonly Dictionary<string, object> _importOptions;

            // Running state
            private Stage _stage = Stage.StartingDownload;
            private string _finalResult; // sticky — once set, subsequent polls return this verbatim
            private EditorAsyncDownload _modelDownload;
            private long _modelDownloadedBytes;
            private List<string> _importedFiles;
            private List<MeshyTextureJob> _textureQueue;
            private int _textureCursor;
            private EditorAsyncDownload _currentTextureDownload;
            private List<MeshyTexturePaths> _meshyTextures;
            private int _configuredCount;
            private string _sidecarPath;

            public ImportAssetHandle(
                string candidateId, string targetPath, string assetType, string resolvedUrl,
                string resolvedLicense, string resolvedAttribution, string archiveFormat,
                string fileExtension, string resolvedProvider, string resolvedTextureUrlsJson,
                Dictionary<string, object> importOptions, string tempFile)
            {
                _candidateId = candidateId;
                _targetPath = targetPath;
                _assetType = assetType;
                _resolvedUrl = resolvedUrl;
                _resolvedLicense = resolvedLicense;
                _resolvedAttribution = resolvedAttribution;
                _archiveFormat = archiveFormat;
                _fileExtension = fileExtension;
                _resolvedProvider = resolvedProvider;
                _resolvedTextureUrlsJson = resolvedTextureUrlsJson;
                _importOptions = importOptions;
                _tempFile = tempFile;
            }

            /// <summary>Pre-completed handle whose first poll returns the given error envelope.</summary>
            public static ImportAssetHandle Failed(string errorEnvelope)
            {
                var h = new ImportAssetHandle(null, null, null, null, null, null, null, null, null, null, null, null);
                h._finalResult = errorEnvelope;
                h._stage = Stage.Done;
                return h;
            }

            public string Phase
            {
                get
                {
                    switch (_stage)
                    {
                        case Stage.StartingDownload:
                        case Stage.DownloadingModel: return "downloading";
                        case Stage.ExtractingAndPlacing: return "extracting";
                        case Stage.StartingTexture:
                        case Stage.DownloadingTexture: return "downloading_textures";
                        case Stage.ImportingAndConfiguring: return "importing";
                        case Stage.WritingSidecar: return "writing_sidecar";
                        case Stage.Done: return "done";
                        default: return "unknown";
                    }
                }
            }

            public float? Progress
            {
                get
                {
                    if (_stage == Stage.DownloadingModel) return _modelDownload?.Progress;
                    if (_stage == Stage.DownloadingTexture) return _currentTextureDownload?.Progress;
                    return null;
                }
            }

            public string PollResult()
            {
                if (_finalResult != null) return _finalResult;
                try
                {
                    return Advance();
                }
                catch (Exception e)
                {
                    SafeDelete(_tempFile);
                    return Fail($"Import failed: {e.Message}");
                }
            }

            private string Advance()
            {
                switch (_stage)
                {
                    case Stage.StartingDownload:
                        _modelDownload = new EditorAsyncDownload(_resolvedUrl, _tempFile, DownloadTimeoutSeconds, MaxDownloadBytes);
                        _stage = Stage.DownloadingModel;
                        return null;

                    case Stage.DownloadingModel:
                        if (!_modelDownload.IsDone) return null;
                        string dlErr = _modelDownload.Error;
                        if (dlErr != null)
                        {
                            _modelDownload.Dispose();
                            _modelDownload = null;
                            SafeDelete(_tempFile);
                            return Fail($"Download failed: {dlErr}");
                        }
                        _modelDownloadedBytes = _modelDownload.FinalSize;
                        _modelDownload.Dispose();
                        _modelDownload = null;
                        _stage = Stage.ExtractingAndPlacing;
                        return null;

                    case Stage.ExtractingAndPlacing:
                        try
                        {
                            _importedFiles = _archiveFormat == "zip"
                                ? ExtractZipToProject(_tempFile, _targetPath)
                                : PlaceSingleFileInProject(_tempFile, _targetPath, _candidateId, _fileExtension);
                        }
                        catch (Exception e)
                        {
                            SafeDelete(_tempFile);
                            return Fail($"Failed to install asset into project: {e.Message}");
                        }
                        SafeDelete(_tempFile);
                        _meshyTextures = new List<MeshyTexturePaths>();
                        if (!string.IsNullOrEmpty(_resolvedTextureUrlsJson))
                        {
                            try
                            {
                                _textureQueue = BuildMeshyTextureQueue(_candidateId, _resolvedProvider, _targetPath, _resolvedTextureUrlsJson);
                            }
                            catch (Exception e)
                            {
                                Debug.LogWarning($"[GladeKit] Provider texture queue build failed: {e.Message}");
                                _textureQueue = null;
                            }
                        }
                        _stage = Stage.StartingTexture;
                        return null;

                    case Stage.StartingTexture:
                        if (_textureQueue == null || _textureCursor >= _textureQueue.Count)
                        {
                            _stage = Stage.ImportingAndConfiguring;
                            return null;
                        }
                        var job = _textureQueue[_textureCursor];
                        _currentTextureDownload = new EditorAsyncDownload(job.Url, job.AbsPath, DownloadTimeoutSeconds, MaxDownloadBytes);
                        _stage = Stage.DownloadingTexture;
                        return null;

                    case Stage.DownloadingTexture:
                        if (!_currentTextureDownload.IsDone) return null;
                        var jobNow = _textureQueue[_textureCursor];
                        string texErr = _currentTextureDownload.Error;
                        _currentTextureDownload.Dispose();
                        _currentTextureDownload = null;
                        if (texErr != null)
                        {
                            // Per-texture failure: log + skip, don't abort the whole import.
                            // A missing roughness map shouldn't kill a model that has base
                            // color + normal — matches pre-state-machine behavior.
                            Debug.LogWarning($"[GladeKit] Texture download failed ({jobNow.UrlKey}): {texErr}");
                            SafeDelete(jobNow.AbsPath);
                        }
                        else
                        {
                            _importedFiles.Add(jobNow.RelPath);
                            RecordTexturePath(_meshyTextures, jobNow.MatIndex, jobNow.UrlKey, jobNow.RelPath);
                        }
                        _textureCursor++;
                        _stage = Stage.StartingTexture;
                        return null;

                    case Stage.ImportingAndConfiguring:
                        AssetDatabase.Refresh(ImportAssetOptions.ForceUpdate);
                        try
                        {
                            _configuredCount = ConfigureImportSettings(
                                _importedFiles, _assetType, _importOptions, _resolvedProvider, _meshyTextures);
                        }
                        catch (Exception e)
                        {
                            Debug.LogWarning($"[GladeKit] Asset import settings partially failed: {e.Message}");
                        }
                        _stage = Stage.WritingSidecar;
                        return null;

                    case Stage.WritingSidecar:
                        _sidecarPath = WriteSidecar(
                            _targetPath, _candidateId, _resolvedLicense, _resolvedAttribution,
                            _resolvedUrl, _assetType, _fileExtension, _importedFiles);
                        AssetDatabase.Refresh();
                        var extras = new Dictionary<string, object>
                        {
                            { "candidateId", _candidateId },
                            { "targetPath", _targetPath },
                            { "license", _resolvedLicense ?? "UNKNOWN" },
                            { "attribution", _resolvedAttribution ?? "" },
                            { "downloadedBytes", _modelDownloadedBytes },
                            { "importedFileCount", _importedFiles.Count },
                            { "importedFiles", _importedFiles.Take(50).ToList() },
                            { "importedFilesTruncated", _importedFiles.Count > 50 },
                            { "configuredImportSettings", _configuredCount },
                            { "sidecarPath", _sidecarPath },
                        };
                        _finalResult = ToolUtils.CreateSuccessResponse(
                            $"Imported {_importedFiles.Count} file(s) from {_candidateId} to {_targetPath}",
                            extras);
                        _stage = Stage.Done;
                        return _finalResult;

                    case Stage.Done:
                        return _finalResult;

                    default:
                        return Fail("Unknown import stage");
                }
            }

            private string Fail(string msg)
            {
                _finalResult = ToolUtils.CreateErrorResponse(msg);
                _stage = Stage.Done;
                return _finalResult;
            }

            public void Dispose()
            {
                try { _modelDownload?.Dispose(); } catch { /* ignore */ }
                _modelDownload = null;
                try { _currentTextureDownload?.Dispose(); } catch { /* ignore */ }
                _currentTextureDownload = null;
                SafeDelete(_tempFile);
            }
        }

        /// <summary>
        /// Pure-data shape used by <see cref="EnumerateAllowedMeshyTextureUrls"/>.
        /// Tests assert against this. No file paths — keeps the function
        /// testable in NUnit without touching disk.
        /// </summary>
        internal struct MeshyTextureUrl
        {
            public int MatIndex;
            public string UrlKey;    // base_color | metallic | normal | roughness
            public string NameSlug;  // baseColor | metallic | normal | roughness
            public string Url;
        }

        /// <summary>
        /// Walk the JSON-encoded PBR texture list, apply the bridge's host
        /// allowlist to every URL, and return the URLs that survive in
        /// material-index order. Internal so NUnit Edit Mode tests can reach
        /// it via InternalsVisibleTo — the regression this exists to catch
        /// (a Meshy CDN host rotation silently dropping every texture with
        /// only a Debug.LogWarning) is a silent-failure path: the model would
        /// import looking gray, with no exception or error envelope to flag.
        /// </summary>
        internal static List<MeshyTextureUrl> EnumerateAllowedMeshyTextureUrls(
            string candidateId, string provider, string texJson)
        {
            var urls = new List<MeshyTextureUrl>();
            if (!string.Equals(provider, "meshy", StringComparison.OrdinalIgnoreCase))
                return urls; // Future providers plug in here. v0.2.1 only knows Meshy.

            if (!ToolUtils.TryParseJsonArrayToList(texJson, out var entries) || entries == null)
            {
                Debug.LogWarning("[GladeKit] _resolvedTextureUrls did not parse as a JSON array — skipping texture download");
                return urls;
            }

            var spec = new (string urlKey, string nameSlug)[]
            {
                ("base_color", "baseColor"),
                ("metallic",   "metallic"),
                ("normal",     "normal"),
                ("roughness",  "roughness"),
            };

            for (int i = 0; i < entries.Count; i++)
            {
                if (!(entries[i] is Dictionary<string, object> entry)) continue;
                foreach (var (urlKey, nameSlug) in spec)
                {
                    if (!entry.TryGetValue(urlKey, out var urlObj)) continue;
                    string url = urlObj?.ToString();
                    if (string.IsNullOrEmpty(url)) continue;

                    string rejection = AssetPipelineGuard.DescribeUrlHostRejection(candidateId, url);
                    if (rejection != null)
                    {
                        Debug.LogWarning($"[GladeKit] Skipping texture {urlKey}: {rejection}");
                        continue;
                    }
                    urls.Add(new MeshyTextureUrl
                    {
                        MatIndex = i,
                        UrlKey = urlKey,
                        NameSlug = nameSlug,
                        Url = url,
                    });
                }
            }
            return urls;
        }

        /// <summary>
        /// Flatten the per-material PBR texture entries into a linear queue.
        /// Filters out empty URLs and rejects any URL that fails the bridge's
        /// host allowlist BEFORE any network work happens — that filtering
        /// lives in <see cref="EnumerateAllowedMeshyTextureUrls"/> so it can
        /// be unit-tested without filesystem side effects.
        /// </summary>
        private static List<MeshyTextureJob> BuildMeshyTextureQueue(
            string candidateId, string provider, string targetPath, string texJson)
        {
            var allowed = EnumerateAllowedMeshyTextureUrls(candidateId, provider, texJson);
            var jobs = new List<MeshyTextureJob>();
            if (allowed.Count == 0) return jobs;

            string projectRoot = Directory.GetParent(Application.dataPath).FullName;
            string texFolderRel = targetPath.TrimEnd('/') + "/Textures/";
            string texFolderAbs = Path.Combine(projectRoot, texFolderRel.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(texFolderAbs);

            foreach (var u in allowed)
            {
                // Canonical filename: meshy_baseColor.png or meshy_baseColor_1.png for
                // multi-material PBR sets. Extension comes from the URL path; default
                // to .png for Meshy which always serves PNGs.
                string ext = TryGetUrlExtension(u.Url) ?? ".png";
                string suffix = u.MatIndex == 0 ? "" : $"_{u.MatIndex}";
                string fileName = $"meshy_{u.NameSlug}{suffix}{ext}";
                jobs.Add(new MeshyTextureJob
                {
                    MatIndex = u.MatIndex,
                    UrlKey = u.UrlKey,
                    NameSlug = u.NameSlug,
                    Url = u.Url,
                    AbsPath = Path.Combine(texFolderAbs, fileName),
                    RelPath = texFolderRel + fileName,
                });
            }
            return jobs;
        }

        /// <summary>
        /// Record a successfully-downloaded texture against its material's
        /// <see cref="MeshyTexturePaths"/>, padding the list out to
        /// <paramref name="matIndex"/> so material indices stay aligned with
        /// the upstream entry order. Matches the per-material allocation
        /// behavior of the pre-state-machine code.
        /// </summary>
        private static void RecordTexturePath(
            List<MeshyTexturePaths> list, int matIndex, string urlKey, string relPath)
        {
            while (list.Count <= matIndex) list.Add(new MeshyTexturePaths());
            var entry = list[matIndex];
            switch (urlKey)
            {
                case "base_color": entry.BaseColor = relPath; break;
                case "metallic":   entry.Metallic = relPath;  break;
                case "normal":     entry.Normal = relPath;    break;
                case "roughness":  entry.Roughness = relPath; break;
            }
        }

        private static string TryGetUrlExtension(string url)
        {
            try
            {
                var uri = new Uri(url);
                string ext = Path.GetExtension(uri.AbsolutePath);
                if (string.IsNullOrEmpty(ext)) return null;
                // Filter out anything that doesn't look like a real image extension —
                // Meshy serves .png today, but if a CDN appends a signed-URL token
                // that looks like an extension we don't want to use it as a filename.
                ext = ext.ToLowerInvariant();
                if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".tga") return ext;
                return null;
            }
            catch
            {
                return null;
            }
        }

        private static void BindMeshyTexturesToExtractedMaterials(
            string fbxAssetPath, List<MeshyTexturePaths> meshyTextures)
        {
            // The extracted materials live next to the FBX after import. Unity's
            // default layout is `Assets/<dir>/Materials/<MatName>.mat`, but the
            // FBX may put them right next to itself if "Materials" subfolder
            // creation is off. Search both spots and bind any URP/Lit material
            // we find using meshyTextures[0] (the first PBR set covers the
            // common single-material case; multi-material variants are v0.2.2).
            if (meshyTextures.Count == 0) return;
            var pbr = meshyTextures[0];
            string fbxDir = Path.GetDirectoryName(fbxAssetPath)?.Replace('\\', '/');
            if (string.IsNullOrEmpty(fbxDir)) return;

            var searchDirs = new List<string> { fbxDir + "/Materials", fbxDir };
            var matPaths = new List<string>();
            foreach (var dir in searchDirs)
            {
                string[] guids = AssetDatabase.FindAssets("t:Material", new[] { dir });
                foreach (var guid in guids)
                {
                    string p = AssetDatabase.GUIDToAssetPath(guid);
                    if (!matPaths.Contains(p)) matPaths.Add(p);
                }
            }
            if (matPaths.Count == 0)
            {
                Debug.LogWarning($"[GladeKit] No extracted material found near {fbxAssetPath} to bind Meshy textures.");
                return;
            }

            // Fix the normal texture's import type BEFORE assigning it — Unity
            // refuses to render a non-NormalMap texture in the _BumpMap slot
            // correctly. Other maps stay as default RGB.
            if (!string.IsNullOrEmpty(pbr.Normal))
            {
                var normTexImporter = AssetImporter.GetAtPath(pbr.Normal) as TextureImporter;
                if (normTexImporter != null && normTexImporter.textureType != TextureImporterType.NormalMap)
                {
                    normTexImporter.textureType = TextureImporterType.NormalMap;
                    EditorUtility.SetDirty(normTexImporter);
                    normTexImporter.SaveAndReimport();
                }
            }

            foreach (var matPath in matPaths)
            {
                var material = AssetDatabase.LoadAssetAtPath<Material>(matPath);
                if (material == null) continue;

                // Force URP/Lit on the extracted material so the _BaseMap /
                // _BumpMap properties exist regardless of what shader the FBX
                // referenced. Skip silently if the URP shader isn't available
                // (Built-in pipeline projects keep the FBX's default Standard).
                Shader urpLit = Shader.Find("Universal Render Pipeline/Lit");
                if (urpLit != null && material.shader != urpLit)
                {
                    material.shader = urpLit;
                }

                if (!string.IsNullOrEmpty(pbr.BaseColor))
                {
                    var tex = AssetDatabase.LoadAssetAtPath<Texture2D>(pbr.BaseColor);
                    if (tex != null && material.HasProperty("_BaseMap")) material.SetTexture("_BaseMap", tex);
                }
                if (!string.IsNullOrEmpty(pbr.Normal))
                {
                    var tex = AssetDatabase.LoadAssetAtPath<Texture2D>(pbr.Normal);
                    if (tex != null && material.HasProperty("_BumpMap"))
                    {
                        material.SetTexture("_BumpMap", tex);
                        material.EnableKeyword("_NORMALMAP");
                    }
                }
                EditorUtility.SetDirty(material);
            }
            AssetDatabase.SaveAssets();
        }

        private static bool ConfigureAudioImporter(string assetPath, Dictionary<string, object> options)
        {
            var importer = AssetImporter.GetAtPath(assetPath) as AudioImporter;
            if (importer == null) return false;

            var sample = importer.defaultSampleSettings;
            if (options != null && options.TryGetValue("compressionFormat", out var cfObj))
            {
                string cf = cfObj?.ToString();
                if (string.Equals(cf, "pcm", StringComparison.OrdinalIgnoreCase))
                    sample.compressionFormat = AudioCompressionFormat.PCM;
                else if (string.Equals(cf, "vorbis", StringComparison.OrdinalIgnoreCase))
                    sample.compressionFormat = AudioCompressionFormat.Vorbis;
            }
            if (options != null && options.TryGetValue("forceMono", out var fmObj))
            {
                importer.forceToMono = ToolUtils.ParseBool(fmObj);
            }
            importer.defaultSampleSettings = sample;

            EditorUtility.SetDirty(importer);
            importer.SaveAndReimport();
            return true;
        }

        // ── Sidecar metadata ─────────────────────────────────────────────────

        // Schema v2 (2026-05-14): adds texture_files, material_files,
        // provider_metadata. v1 readers can ignore the new fields — JSON
        // is forward-compat by convention. Bumped version so future migrations
        // have an explicit anchor.
        private const int SidecarSchemaVersion = 2;

        [Serializable]
        private class AssetSidecarData
        {
            public int schema_version = SidecarSchemaVersion;
            public string candidate_id = "";
            public string provider = "";
            public string license = "";
            public string attribution_text = "";
            public string source_url = "";
            public string imported_at = "";
            public string asset_type = "";
            public string target_path = "";
            public List<string> imported_files = new List<string>();
            public List<string> texture_files = new List<string>();
            public List<string> material_files = new List<string>();
            public AssetSidecarProviderMetadata provider_metadata = new AssetSidecarProviderMetadata();
        }

        [Serializable]
        private class AssetSidecarProviderMetadata
        {
            // Meshy-only — empty for static-catalog providers (Kenney).
            public string refined_task_id = "";
            public string model_format = "";
        }

        private static string WriteSidecar(
            string targetPath,
            string candidateId,
            string license,
            string attribution,
            string sourceUrl,
            string assetType,
            string fileExtension,
            List<string> importedFiles)
        {
            string sidecarRel = targetPath.TrimEnd('/') + "/.gladekit-asset.json";
            string projectRoot = Directory.GetParent(Application.dataPath).FullName;
            string sidecarAbs = Path.Combine(projectRoot, sidecarRel.Replace('/', Path.DirectorySeparatorChar));

            string json = BuildSidecarJson(
                targetPath: targetPath,
                candidateId: candidateId,
                license: license,
                attribution: attribution,
                sourceUrl: sourceUrl,
                assetType: assetType,
                fileExtension: fileExtension,
                importedFiles: importedFiles,
                importedAt: DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"));

            Directory.CreateDirectory(Path.GetDirectoryName(sidecarAbs));
            File.WriteAllText(sidecarAbs, json, Encoding.UTF8);
            return sidecarRel;
        }

        /// <summary>
        /// Pure sidecar-JSON builder. Filesystem-free and timestamp-free
        /// (caller supplies <paramref name="importedAt"/>) so unit tests can
        /// assert exact byte output without monkeypatching the clock or
        /// dataPath. JsonUtility handles every string-escape rule (quotes,
        /// backslashes, control chars, unicode); this helper exists purely
        /// to make those guarantees testable from the NUnit suite.
        /// </summary>
        internal static string BuildSidecarJson(
            string targetPath,
            string candidateId,
            string license,
            string attribution,
            string sourceUrl,
            string assetType,
            string fileExtension,
            List<string> importedFiles,
            string importedAt)
        {
            string provider = ProviderFromCandidate(candidateId);
            var data = new AssetSidecarData
            {
                candidate_id = candidateId ?? "",
                provider = provider,
                license = license ?? "UNKNOWN",
                attribution_text = attribution ?? "",
                source_url = sourceUrl ?? "",
                imported_at = importedAt ?? "",
                asset_type = assetType ?? "",
                target_path = targetPath ?? "",
                imported_files = importedFiles ?? new List<string>(),
            };

            // Partition the imported file list into texture / material / other
            // so an auditor can see at a glance which files are PBR sidecars
            // vs the primary asset. Kenney imports leave texture_files /
            // material_files empty (the .zip contents are the imported_files);
            // Meshy populates both because we downloaded textures separately
            // and Unity extracted .mat assets next to the FBX.
            foreach (string path in data.imported_files)
            {
                if (IsTextureFile(path)) data.texture_files.Add(path);
                else if (IsMaterialFile(path)) data.material_files.Add(path);
            }

            if (string.Equals(provider, "meshy", StringComparison.OrdinalIgnoreCase))
            {
                // Candidate id format: "meshy/<refined_task_id>"
                int slash = (candidateId ?? "").IndexOf('/');
                data.provider_metadata.refined_task_id = slash > 0
                    ? candidateId.Substring(slash + 1)
                    : "";
                data.provider_metadata.model_format = (fileExtension ?? "").TrimStart('.');
            }

            // JsonUtility handles all string escaping (quotes, backslashes,
            // unicode, control chars) — same serializer Unity uses internally
            // for ScriptableObjects. Replaces the hand-rolled StringBuilder
            // approach that silently corrupted on a candidate name containing
            // a literal '"'.
            return JsonUtility.ToJson(data, prettyPrint: true);
        }

        private static bool IsTextureFile(string p)
        {
            string ext = Path.GetExtension(p).ToLowerInvariant();
            return ext == ".png" || ext == ".jpg" || ext == ".jpeg" ||
                   ext == ".tga" || ext == ".tiff" || ext == ".bmp";
        }

        private static bool IsMaterialFile(string p)
        {
            return Path.GetExtension(p).Equals(".mat", StringComparison.OrdinalIgnoreCase);
        }

        // ── Helpers ──────────────────────────────────────────────────────────

        private static string TryGetString(Dictionary<string, object> args, string key)
        {
            if (args == null || !args.TryGetValue(key, out var v) || v == null) return "";
            return v.ToString();
        }

        private static bool TryParseFloat(object v, out float f)
        {
            if (v is float ff) { f = ff; return true; }
            if (v is double dd) { f = (float)dd; return true; }
            if (v is int ii) { f = ii; return true; }
            if (v is long ll) { f = ll; return true; }
            if (v is string s && float.TryParse(s, out var pf)) { f = pf; return true; }
            f = 0f; return false;
        }

        private static string DefaultTargetPath(string assetType, string candidateId)
        {
            string slug = SanitizeFileName(candidateId);
            switch (assetType)
            {
                case "sprite_2d": return $"Assets/Sprites/{slug}/";
                case "ui_sprite": return $"Assets/Sprites/UI/{slug}/";
                case "model_3d": return $"Assets/Models/{slug}/";
                case "audio_sfx": return $"Assets/Audio/SFX/{slug}/";
                case "audio_music": return $"Assets/Audio/Music/{slug}/";
                default: return $"Assets/Imported/{slug}/";
            }
        }

        private static string NormalizeTargetPath(string p)
        {
            string n = p.Replace('\\', '/').Trim();
            if (!n.EndsWith("/")) n += "/";
            return n;
        }

        private static string SanitizeFileName(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s)
            {
                if (char.IsLetterOrDigit(c) || c == '-' || c == '_') sb.Append(c);
                else sb.Append('-');
            }
            return sb.ToString();
        }

        private static string ProviderFromCandidate(string id)
        {
            if (string.IsNullOrEmpty(id)) return "";
            int slash = id.IndexOf('/');
            return slash > 0 ? id.Substring(0, slash) : id;
        }

        private static bool IsImageFile(string p)
        {
            string ext = Path.GetExtension(p).ToLowerInvariant();
            return ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".tga" ||
                   ext == ".bmp" || ext == ".gif" || ext == ".psd" || ext == ".tiff";
        }

        private static bool IsModelFile(string p)
        {
            string ext = Path.GetExtension(p).ToLowerInvariant();
            return ext == ".fbx" || ext == ".obj" || ext == ".dae" || ext == ".gltf" ||
                   ext == ".glb" || ext == ".blend";
        }

        private static bool IsAudioFile(string p)
        {
            string ext = Path.GetExtension(p).ToLowerInvariant();
            return ext == ".wav" || ext == ".mp3" || ext == ".ogg" || ext == ".aif" || ext == ".aiff";
        }

        private static void SafeDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { /* best-effort */ }
        }
    }
}
