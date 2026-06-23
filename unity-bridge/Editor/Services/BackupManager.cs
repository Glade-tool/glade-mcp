using System;
using System.IO;
using UnityEngine;
using UnityEditor;

namespace GladeAgenticAI.Services
{
    /// <summary>
    /// Manages backup files for GladeKit
    /// </summary>
    public static class BackupManager
    {
        private static readonly string BackupRootPath = Path.Combine(Application.dataPath, "..", ".gladekit-backups");

        /// <summary>
        /// Build the per-turn backup subdirectory name. Turn ids already arrive
        /// prefixed with "turn-" (e.g. "turn-1780445512211-5pkwwr"), so prepend
        /// the prefix only when it is absent — otherwise we produce
        /// "turn-turn-…", a path the caller never looks under.
        ///
        /// This MUST match the convention the calling client uses to compute
        /// backup paths, and the Godot bridge's _turn_subdir. Backups are
        /// written here and restored by path; if the write path and the
        /// caller-computed path disagree, File.Exists is false at revert time,
        /// the restore is skipped, and undo silently does nothing while still
        /// reporting success.
        /// </summary>
        public static string TurnSubdir(string turnId)
        {
            if (string.IsNullOrEmpty(turnId)) return "turn-";
            return turnId.StartsWith("turn-") ? turnId : $"turn-{turnId}";
        }

        /// <summary>
        /// Deletes all backup files (accessible via Window > GladeKit > Delete Backup Files)
        /// </summary>
        [MenuItem("Window/GladeKit/Delete Backup Files")]
        public static void DeleteAllBackups()
        {
            // Show confirmation dialog
            if (!EditorUtility.DisplayDialog(
                "Delete Backup Files",
                "Are you sure you cannot get these back? This will permanently delete all GladeKit backup files.",
                "Delete",
                "Cancel"))
            {
                return;
            }

            try
            {
                // Check if backup directory exists
                if (!Directory.Exists(BackupRootPath))
                {
                    EditorUtility.DisplayDialog(
                        "Delete Backup Files",
                        "No backup files found. The backup directory does not exist.",
                        "OK");
                    Debug.Log("[BackupManager] No backup directory found to delete");
                    return;
                }

                // Count files before deletion for logging
                int fileCount = Directory.GetFiles(BackupRootPath, "*", SearchOption.AllDirectories).Length;
                int dirCount = Directory.GetDirectories(BackupRootPath, "*", SearchOption.AllDirectories).Length;

                // Delete the entire backup directory
                Directory.Delete(BackupRootPath, true);

                Debug.Log($"[BackupManager] Successfully deleted all backup files. Removed {fileCount} files and {dirCount} directories.");
                
                EditorUtility.DisplayDialog(
                    "Delete Backup Files",
                    $"Successfully deleted all backup files.\n\nRemoved {fileCount} files and {dirCount} directories.",
                    "OK");
            }
            catch (Exception e)
            {
                Debug.LogError($"[BackupManager] Failed to delete backup files: {e.Message}");
                EditorUtility.DisplayDialog(
                    "Delete Backup Files",
                    $"Failed to delete backup files:\n\n{e.Message}",
                    "OK");
            }
        }
    }
}
