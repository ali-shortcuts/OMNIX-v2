using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using Newtonsoft.Json;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;

namespace OMNIX.Core.Storage
{
    public enum ChatRole
    {
        User,
        Assistant,
        System
    }

    public sealed class ImageAttachment
    {
        public string FileName { get; set; }
        public byte[] PngBytes { get; set; }
        public string SourceLabel { get; set; }
    }

    public sealed class ChatTurn
    {
        public ChatRole Role { get; set; }
        public string Text { get; set; }
        public List<ImageAttachment> Images { get; set; }
        public DateTime TimestampUtc { get; set; }

        public bool HasImages
        {
            get { return Images != null && Images.Count > 0; }
        }
    }

    /// <summary>
    /// Layer 8 (Storage): per-document chat history as local JSON files under
    /// %LOCALAPPDATA%\OMNIX\history\&lt;docKey&gt;.json, with hard caps
    /// (max messages / max age) so memory and disk never grow unbounded (spec Section 5 + Layer 8).
    /// </summary>
    public sealed class ChatHistoryStore
    {
        private readonly string _dir;

        public ChatHistoryStore()
        {
            _dir = Path.Combine(Logger.BaseDir, "history");
            Directory.CreateDirectory(_dir);
        }

        private static string FileFor(string docKey)
        {
            return Path.Combine(Logger.BaseDir, "history", DocKeySanitizer.Sanitize(docKey) + ".json");
        }

        public List<ChatTurn> Load(string docKey)
        {
            var list = new List<ChatTurn>();
            try
            {
                string path = FileFor(docKey);
                if (!File.Exists(path)) return list;
                string json = File.ReadAllText(path);
                var loaded = JsonConvert.DeserializeObject<List<ChatTurn>>(json);
                if (loaded != null) list.AddRange(loaded);
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to load history for " + docKey, ex);
            }
            return ApplyCaps(list);
        }

        public void Save(string docKey, List<ChatTurn> turns)
        {
            try
            {
                Directory.CreateDirectory(_dir);
                string path = FileFor(docKey);
                string json = JsonConvert.SerializeObject(ApplyCaps(turns), Formatting.Indented);
                string tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Delete(path);
                File.Move(tmp, path);
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to save history for " + docKey, ex);
            }
        }

        public void Delete(string docKey)
        {
            try
            {
                string path = FileFor(docKey);
                if (File.Exists(path)) File.Delete(path);
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to delete history for " + docKey, ex);
            }
        }

        private List<ChatTurn> ApplyCaps(List<ChatTurn> list)
        {
            var settings = SettingsManager.Instance.Settings;
            DateTime cutoff = DateTime.UtcNow.AddDays(-Math.Max(1, settings.HistoryMaxAgeDays));
            var trimmed = list.Where(t => t.TimestampUtc >= cutoff).ToList();
            int max = Math.Max(10, settings.HistoryMaxMessages);
            if (trimmed.Count > max)
                trimmed = trimmed.Skip(trimmed.Count - max).ToList();
            return trimmed;
        }
    }

    /// <summary>Sanitizes document names into safe file keys (no invalid chars, length-capped with hash suffix).</summary>
    public static class DocKeySanitizer
    {
        public static string Sanitize(string docKey)
        {
            if (string.IsNullOrWhiteSpace(docKey)) docKey = "unnamed";
            var invalid = Path.GetInvalidFileNameChars();
            var sb = new System.Text.StringBuilder();
            foreach (char c in docKey)
                sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
            string safe = sb.ToString().Trim();
            if (safe.Length > 60)
            {
                string hash;
                using (var sha = SHA1.Create())
                {
                    byte[] h = sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(docKey));
                    hash = BitConverter.ToString(h, 0, 6).Replace("-", "").ToLowerInvariant();
                }
                safe = safe.Substring(0, 50) + "-" + hash;
            }
            return string.IsNullOrEmpty(safe) ? "unnamed" : safe;
        }
    }
}
