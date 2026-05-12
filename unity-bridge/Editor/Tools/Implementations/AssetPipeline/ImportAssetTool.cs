using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using UnityEditor;
using UnityEngine;
using UnityEngine.Networking;
using GladeAgenticAI.Services;

namespace GladeAgenticAI.Core.Tools.Implementations.AssetPipeline
{
    /// <summary>
    /// Downloads an external asset (resolved cloud-side), places it under
    /// <c>Assets/&lt;targetPath&gt;/</c>, configures Unity import settings for the
    /// asset type, and writes a <c>.gladekit-asset.json</c> sidecar with license
    /// + attribution metadata for later audit.
    ///
    /// Args (cloud-injected unless marked LLM):
    ///   candidateId         (LLM)     stable id from find_asset, e.g. "kenney/tiny-town"
    ///   targetPath          (LLM)     destination folder under Assets/, e.g. "Assets/Sprites/tiny-town/"
    ///   licenseAcknowledged (LLM)     must be true; license gate
    ///   _resolvedUrl        (cloud)   direct download URL (LLM never sees this)
    ///   _resolvedLicense    (cloud)   normalized license code, e.g. "CC0-1.0"
    ///   _resolvedAttribution(cloud)   attribution string (recorded in sidecar)
    ///   _resolvedArchiveFormat (cloud) "zip" | null  (only zip supported in v0)
    ///   _resolvedFileExtension (cloud) for single-file: ".png" / ".wav" / ".fbx"
    ///   assetType           (LLM)     one of sprite_2d, model_3d, audio_sfx, ui_sprite, audio_music
    ///   importOptions       (LLM)     optional asset-type-specific overrides
    ///
    /// Security — the underscore-prefixed fields MUST be set by the cloud
    /// (or MCP) preprocessor, not by the LLM. The cloud schema for import_asset
    /// does not document them. Three defense layers guard the download:
    ///   1. Cloud/MCP preprocessors strip caller-supplied underscore-prefixed
    ///      fields before resolving against the trusted catalog.
    ///   2. The bridge refuses calls with an empty _resolvedUrl (preprocessor
    ///      didn't run).
    ///   3. The bridge validates _resolvedUrl's host against
    ///      AssetPipelineGuard.IsResolvedUrlHostAllowed for the candidate's
    ///      provider prefix — so even a client bypassing both preprocessors
    ///      can't smuggle in an arbitrary download URL.
    /// </summary>
    public class ImportAssetTool : ITool
    {
        public string Name => "import_asset";

        // 60s timeout matches the cloud-side budget for a single tool round-trip.
        // Most Kenney packs are 1-15MB and download in <5s on broadband.
        private const int DownloadTimeoutSeconds = 60;

        // Cap to avoid a runaway download claiming gigabytes of disk before we notice.
        // Largest legitimate Kenney pack is ~120MB (full 3D voxel sets); cap at 250MB.
        private const long MaxDownloadBytes = 250L * 1024L * 1024L;

        public string Execute(Dictionary<string, object> args)
        {
            string disabled = AssetPipelineGuard.RejectIfDisabled();
            if (disabled != null) return disabled;

            if (args == null)
                return ToolUtils.CreateErrorResponse("args required");

            // ── LLM-supplied fields ──────────────────────────────────────────
            string candidateId = TryGetString(args, "candidateId");
            if (string.IsNullOrEmpty(candidateId))
                return ToolUtils.CreateErrorResponse("candidateId is required");

            bool licenseAck = ToolUtils.ParseBool(args.TryGetValue("licenseAcknowledged", out var lao) ? lao : null);
            if (!licenseAck)
            {
                return ToolUtils.CreateErrorResponse(
                    "licenseAcknowledged must be true. The user must confirm they accept " +
                    "the asset's license (shown in the find_asset preview) before import.");
            }

            string assetType = TryGetString(args, "assetType");
            if (string.IsNullOrEmpty(assetType))
                return ToolUtils.CreateErrorResponse("assetType is required");

            string targetPath = TryGetString(args, "targetPath");
            if (string.IsNullOrEmpty(targetPath))
                targetPath = DefaultTargetPath(assetType, candidateId);
            targetPath = NormalizeTargetPath(targetPath);
            if (!targetPath.StartsWith("Assets/", StringComparison.OrdinalIgnoreCase))
                return ToolUtils.CreateErrorResponse("targetPath must start with 'Assets/'");

            // ── Cloud-injected fields ────────────────────────────────────────
            string resolvedUrl = TryGetString(args, "_resolvedUrl");
            string resolvedLicense = TryGetString(args, "_resolvedLicense");
            string resolvedAttribution = TryGetString(args, "_resolvedAttribution");
            string archiveFormat = TryGetString(args, "_resolvedArchiveFormat");
            string fileExtension = TryGetString(args, "_resolvedFileExtension");

            if (string.IsNullOrEmpty(resolvedUrl))
            {
                return ToolUtils.CreateErrorResponse(
                    "Resolved download URL missing — the cloud proxy did not preprocess " +
                    "this import_asset call. Did you call find_asset first via the cloud, " +
                    "or are you running the bridge against a stale proxy that doesn't know " +
                    "about asset_pipeline preprocessing?");
            }

            string hostRejection = AssetPipelineGuard.DescribeUrlHostRejection(candidateId, resolvedUrl);
            if (hostRejection != null)
            {
                return ToolUtils.CreateErrorResponse(
                    $"Bridge refused the download: {hostRejection}. " +
                    "This means either (a) the URL was injected by a client bypassing cloud / MCP " +
                    "preprocessing, or (b) the provider's official download host has changed and the " +
                    "bridge allowlist in AssetPipelineGuard.cs needs updating. The bridge will not " +
                    "download from arbitrary hosts.");
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
                return ToolUtils.CreateErrorResponse($"Failed to create target folder {targetPath}: {e.Message}");
            }

            // ── Download to a temp file ──────────────────────────────────────
            string tempFile = Path.Combine(
                Path.GetTempPath(),
                $"gladekit-asset-{Guid.NewGuid():N}{(archiveFormat == "zip" ? ".zip" : (fileExtension ?? ""))}");

            long downloadedBytes;
            try
            {
                downloadedBytes = DownloadToFile(resolvedUrl, tempFile);
            }
            catch (Exception e)
            {
                SafeDelete(tempFile);
                return ToolUtils.CreateErrorResponse($"Download failed: {e.Message}");
            }

            // ── Extract / place ──────────────────────────────────────────────
            List<string> importedFiles;
            try
            {
                if (archiveFormat == "zip")
                    importedFiles = ExtractZipToProject(tempFile, targetPath);
                else
                    importedFiles = PlaceSingleFileInProject(tempFile, targetPath, candidateId, fileExtension);
            }
            catch (Exception e)
            {
                SafeDelete(tempFile);
                return ToolUtils.CreateErrorResponse($"Failed to install asset into project: {e.Message}");
            }
            SafeDelete(tempFile);

            // ── Refresh and configure import settings ────────────────────────
            AssetDatabase.Refresh(ImportAssetOptions.ForceUpdate);

            int configuredCount = 0;
            try
            {
                configuredCount = ConfigureImportSettings(importedFiles, assetType, importOptions);
            }
            catch (Exception e)
            {
                Debug.LogWarning($"[GladeKit] Asset import settings partially failed: {e.Message}");
            }

            // ── Write sidecar metadata ───────────────────────────────────────
            string sidecarPath = WriteSidecar(
                targetPath,
                candidateId,
                resolvedLicense,
                resolvedAttribution,
                resolvedUrl,
                assetType,
                importedFiles);

            AssetDatabase.Refresh();

            var extras = new Dictionary<string, object>
            {
                { "candidateId", candidateId },
                { "targetPath", targetPath },
                { "license", resolvedLicense ?? "UNKNOWN" },
                { "attribution", resolvedAttribution ?? "" },
                { "downloadedBytes", downloadedBytes },
                { "importedFileCount", importedFiles.Count },
                { "importedFiles", importedFiles.Take(50).ToList() }, // cap to keep the response bounded
                { "importedFilesTruncated", importedFiles.Count > 50 },
                { "configuredImportSettings", configuredCount },
                { "sidecarPath", sidecarPath },
            };

            return ToolUtils.CreateSuccessResponse(
                $"Imported {importedFiles.Count} file(s) from {candidateId} to {targetPath}",
                extras);
        }

        // ── Download ─────────────────────────────────────────────────────────

        private static long DownloadToFile(string url, string destPath)
        {
            // UnityWebRequest is the Unity-idiomatic, guaranteed-available HTTP
            // client (no asmdef gymnastics for System.Net.Http). DownloadHandlerFile
            // streams directly to disk so a large pack doesn't sit in RAM.
            // Sync wait via tight isDone polling — the Editor freezes briefly.
            // v1 should move to a coroutine + polling pattern so the UI stays live.
            using (var request = UnityWebRequest.Get(url))
            {
                request.downloadHandler = new DownloadHandlerFile(destPath) { removeFileOnAbort = true };
                request.timeout = DownloadTimeoutSeconds;

                var op = request.SendWebRequest();
                long deadline = Environment.TickCount + (DownloadTimeoutSeconds * 1000);
                while (!op.isDone)
                {
                    if (Environment.TickCount > deadline)
                    {
                        request.Abort();
                        throw new TimeoutException(
                            $"Download exceeded {DownloadTimeoutSeconds}s timeout: {url}");
                    }
                    // Brief yield so the editor isn't 100% spinning.
                    Thread.Sleep(50);
                }

#if UNITY_2020_2_OR_NEWER
                if (request.result != UnityWebRequest.Result.Success)
                {
                    throw new InvalidOperationException(
                        $"Download failed: {request.error} (response {request.responseCode})");
                }
#else
                if (request.isHttpError || request.isNetworkError)
                {
                    throw new InvalidOperationException(
                        $"Download failed: {request.error} (response {request.responseCode})");
                }
#endif

                long size = new FileInfo(destPath).Length;
                if (size > MaxDownloadBytes)
                {
                    SafeDelete(destPath);
                    throw new InvalidOperationException(
                        $"Download size {size} exceeds cap of {MaxDownloadBytes} bytes");
                }
                return size;
            }
        }

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
            List<string> importedFiles, string assetType, Dictionary<string, object> options)
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
                        if (ConfigureModelImporter(p, options)) configured++;
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

        private static bool ConfigureModelImporter(string assetPath, Dictionary<string, object> options)
        {
            var importer = AssetImporter.GetAtPath(assetPath) as ModelImporter;
            if (importer == null) return false;

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
            return true;
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

        private static string WriteSidecar(
            string targetPath,
            string candidateId,
            string license,
            string attribution,
            string sourceUrl,
            string assetType,
            List<string> importedFiles)
        {
            string sidecarRel = targetPath.TrimEnd('/') + "/.gladekit-asset.json";
            string projectRoot = Directory.GetParent(Application.dataPath).FullName;
            string sidecarAbs = Path.Combine(projectRoot, sidecarRel.Replace('/', Path.DirectorySeparatorChar));

            var sb = new StringBuilder();
            sb.Append("{\n");
            sb.Append("  \"schema_version\": 1,\n");
            sb.Append($"  \"candidate_id\": \"{ToolUtils.EscapeJsonString(candidateId)}\",\n");
            sb.Append($"  \"provider\": \"{ToolUtils.EscapeJsonString(ProviderFromCandidate(candidateId))}\",\n");
            sb.Append($"  \"license\": \"{ToolUtils.EscapeJsonString(license ?? "UNKNOWN")}\",\n");
            sb.Append($"  \"attribution_text\": \"{ToolUtils.EscapeJsonString(attribution ?? "")}\",\n");
            sb.Append($"  \"source_url\": \"{ToolUtils.EscapeJsonString(sourceUrl ?? "")}\",\n");
            sb.Append($"  \"imported_at\": \"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ}\",\n");
            sb.Append($"  \"asset_type\": \"{ToolUtils.EscapeJsonString(assetType ?? "")}\",\n");
            sb.Append($"  \"target_path\": \"{ToolUtils.EscapeJsonString(targetPath)}\",\n");
            sb.Append("  \"imported_files\": [");
            for (int i = 0; i < importedFiles.Count; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append($"\n    \"{ToolUtils.EscapeJsonString(importedFiles[i])}\"");
            }
            sb.Append("\n  ]\n");
            sb.Append("}\n");

            Directory.CreateDirectory(Path.GetDirectoryName(sidecarAbs));
            File.WriteAllText(sidecarAbs, sb.ToString(), Encoding.UTF8);
            return sidecarRel;
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
