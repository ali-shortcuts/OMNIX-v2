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
    /// memory only and are stripped before disk persistence. History is bounded by age, message
    /// count, per-turn text, total text and input-file size. This prevents a long assistant answer
    /// or corrupted history file from consuming unbounded memory when Office starts.
    /// </summary>
    public sealed class ChatHistoryStore
    {
        private const long MaxHistoryFileBytes = 8L * 1024L * 1024L;
        private const int MaxPersistedTextChars = 2 * 1024 * 1024;
        private const int MaxPersistedTurnChars = 128 * 1024;
        private const string TruncatedMarker = "\n…[OMNIX local history truncated]…\n";

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

                var file = new FileInfo(path);
                if (file.Length > MaxHistoryFileBytes)
                {
                    Logger.Error("history",
                        "History file exceeded the 8 MB safety limit and was not loaded: " + file.Name,
                        null);
                    return list;
                }

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
            string tmp = null;
            try
            {
                Directory.CreateDirectory(_dir);
                string path = FileFor(docKey);
                var persistable = ApplyCaps(turns).Select(CloneForPersistence).ToList();
                string json = JsonConvert.SerializeObject(persistable, Formatting.Indented);
                byte[] encoded = Encoding.UTF8.GetBytes(json);
                if (encoded.LongLength > MaxHistoryFileBytes)
                {
                    Logger.Error("history", "Bounded history serialization still exceeded the file safety limit; save skipped.", null);
                    return;
                }

                tmp = path + ".tmp";
                File.WriteAllBytes(tmp, encoded);
                if (File.Exists(path))
                {
                    // Same-volume atomic replacement on supported Windows; avoids delete-then-move
                    // gaps that can lose the previous history if Office exits mid-save.
                    File.Replace(tmp, path, null);
                }
                else
                {
                    File.Move(tmp, path);
                }
                tmp = null;
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to save local chat history.", ex);
            }
            finally
            {
                if (!string.IsNullOrEmpty(tmp))
                {
                    try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                }
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
            return ApplyTextBudget(trimmed);
        }

        private static List<ChatTurn> ApplyTextBudget(List<ChatTurn> source)
        {
            var newestFirst = new List<ChatTurn>();
            int remaining = MaxPersistedTextChars;

            for (int i = source.Count - 1; i >= 0 && remaining > 0; i--)
            {
                var turn = source[i];
                if (turn == null) continue;

                int cap = Math.Min(MaxPersistedTurnChars, remaining);
                string text = TruncatePreservingEnds(turn.Text, cap);
                newestFirst.Add(new ChatTurn
                {
                    Role = turn.Role,
                    Text = text,
                    Images = turn.Images,
                    TimestampUtc = turn.TimestampUtc
                });
                remaining -= text != null ? text.Length : 0;
            }

            newestFirst.Reverse();
            return newestFirst;
        }

        private static ChatTurn CloneForPersistence(ChatTurn turn)
        {
            var clone = new ChatTurn
            {
                Role = turn.Role,
                Text = turn.Text,
                TimestampUtc = turn.TimestampUtc
            };

            // Retain descriptive metadata only. No image bytes are persisted.
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

        private static string TruncatePreservingEnds(string value, int maxChars)
        {
            value = value ?? string.Empty;
            if (maxChars <= 0) return string.Empty;
            if (value.Length <= maxChars) return value;
            if (maxChars <= TruncatedMarker.Length + 2) return value.Substring(value.Length - maxChars, maxChars);

            int available = maxChars - TruncatedMarker.Length;
            int head = available / 2;
            int tail = available - head;
            return value.Substring(0, head) + TruncatedMarker + value.Substring(value.Length - tail, tail);
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
