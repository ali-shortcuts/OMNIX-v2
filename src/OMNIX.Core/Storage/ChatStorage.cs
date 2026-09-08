using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
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
            get
            {
                return Images != null && Images.Any(i =>
                    i != null && i.PngBytes != null && i.PngBytes.Length > 0);
            }
        }
    }

    /// <summary>
    /// Per-document chat history under %LOCALAPPDATA%\OMNIX\history.
    ///
    /// Privacy/storage rule: raw Office screenshots and uploaded image bytes are request-scoped
    /// memory only. They are deliberately stripped before history is written to disk. Persisting
    /// hundreds of PNGs would both leak document visuals at rest and allow history size to grow far
    /// beyond the message-count cap. Text + non-sensitive image labels remain for conversation UI.
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
                Logger.Error("history", "Failed to load local chat history.", ex);
            }
            return ApplyCaps(list);
        }

        public void Save(string docKey, List<ChatTurn> turns)
        {
            try
            {
                Directory.CreateDirectory(_dir);
                string path = FileFor(docKey);
                var persistable = ApplyCaps(turns).Select(CloneForPersistence).ToList();
                string json = JsonConvert.SerializeObject(persistable, Formatting.Indented);
                string tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                if (File.Exists(path)) File.Delete(path);
                File.Move(tmp, path);
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to save local chat history.", ex);
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
                Logger.Error("history", "Failed to delete local chat history.", ex);
            }
        }

        private List<ChatTurn> ApplyCaps(IEnumerable<ChatTurn> source)
        {
            var list = source != null ? source.Where(t => t != null).ToList() : new List<ChatTurn>();
            var settings = SettingsManager.Instance.Settings;
            DateTime cutoff = DateTime.UtcNow.AddDays(-Math.Max(1, settings.HistoryMaxAgeDays));
            var trimmed = list.Where(t => t.TimestampUtc >= cutoff).ToList();
            int max = Math.Max(10, settings.HistoryMaxMessages);
            if (trimmed.Count > max)
                trimmed = trimmed.Skip(trimmed.Count - max).ToList();
            return trimmed;
        }

        private static ChatTurn CloneForPersistence(ChatTurn turn)
        {
            var clone = new ChatTurn
            {
                Role = turn.Role,
                Text = turn.Text,
                TimestampUtc = turn.TimestampUtc
            };

            // Retain only descriptive metadata. No image bytes are persisted.
            if (turn.Images != null && turn.Images.Count > 0)
            {
                clone.Images = turn.Images
                    .Where(i => i != null)
                    .Select(i => new ImageAttachment
                    {
                        FileName = SafeLabel(i.FileName, 160),
                        SourceLabel = SafeLabel(i.SourceLabel, 80),
                        PngBytes = null
                    })
                    .ToList();
            }
            return clone;
        }

        private static string SafeLabel(string value, int max)
        {
            value = value ?? string.Empty;
            return value.Length <= max ? value : value.Substring(0, max);
        }
    }

    /// <summary>
    /// Produces safe local history keys. StableKey hashes the full document identity so two files
    /// with the same visible name do not share a conversation and the user's document path is not
    /// exposed in a history filename.
    /// </summary>
    public static class DocKeySanitizer
    {
        public static string StableKey(string host, string documentPath, string documentName)
        {
            string hostPart = Sanitize(string.IsNullOrWhiteSpace(host) ? "office" : host).ToLowerInvariant();
            string identity = !string.IsNullOrWhiteSpace(documentPath)
                ? documentPath
                : (documentName ?? "unnamed");

            string digest;
            using (var sha = SHA256.Create())
            {
                byte[] input = Encoding.UTF8.GetBytes(hostPart + "|" + identity);
                byte[] hash = sha.ComputeHash(input);
                // 96 bits is ample for a local non-security identifier and keeps filenames short.
                digest = BitConverter.ToString(hash, 0, 12).Replace("-", "").ToLowerInvariant();
            }
            return hostPart + "-" + digest;
        }

        public static string Sanitize(string docKey)
        {
            if (string.IsNullOrWhiteSpace(docKey)) docKey = "unnamed";
            var invalid = Path.GetInvalidFileNameChars();
            var sb = new StringBuilder();
            foreach (char c in docKey)
                sb.Append(Array.IndexOf(invalid, c) >= 0 ? '_' : c);
            string safe = sb.ToString().Trim();
            if (safe.Length > 60)
            {
                string hash;
                using (var sha = SHA256.Create())
                {
                    byte[] h = sha.ComputeHash(Encoding.UTF8.GetBytes(docKey));
                    hash = BitConverter.ToString(h, 0, 6).Replace("-", "").ToLowerInvariant();
                }
                safe = safe.Substring(0, 50) + "-" + hash;
            }
            return string.IsNullOrEmpty(safe) ? "unnamed" : safe;
        }
    }
}
