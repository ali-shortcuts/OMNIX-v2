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
    /// Privacy/storage rules:
    /// - history is DPAPI protected for the current Windows user before it reaches disk;
    /// - legacy plaintext .json history is migrated once and deleted only after an encrypted
    ///   replacement has been durably written;
    /// - raw Office screenshots and uploaded image bytes are request-scoped memory only and are
    ///   stripped before persistence;
    /// - history is bounded by age, message count, per-turn text, total text and file size.
    ///
    /// A single process-wide I/O gate prevents two Office windows from racing a replace/migration
    /// for the same document history file.
    /// </summary>
    public sealed class ChatHistoryStore
    {
        private const long MaxHistoryFileBytes = 8L * 1024L * 1024L;
        private const long MaxProtectedHistoryFileBytes = 9L * 1024L * 1024L;
        private const int MaxPersistedTextChars = 2 * 1024 * 1024;
        private const int MaxPersistedTurnChars = 128 * 1024;
        private const string TruncatedMarker = "\n…[OMNIX local history truncated]…\n";

        private static readonly object IoGate = new object();
        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("OMNIXH01");
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("OMNIX::history::v1::DPAPI");

        private readonly string _dir;

        public ChatHistoryStore()
        {
            _dir = Path.Combine(Logger.BaseDir, "history");
            Directory.CreateDirectory(_dir);
        }

        private static string FileFor(string docKey)
        {
            return Path.Combine(Logger.BaseDir, "history", DocKeySanitizer.Sanitize(docKey) + ".dat");
        }

        private static string LegacyFileFor(string docKey)
        {
            return Path.Combine(Logger.BaseDir, "history", DocKeySanitizer.Sanitize(docKey) + ".json");
        }

        public List<ChatTurn> Load(string docKey)
        {
            lock (IoGate)
            {
                return LoadLocked(docKey);
            }
        }

        private List<ChatTurn> LoadLocked(string docKey)
        {
            try
            {
                string encryptedPath = FileFor(docKey);
                if (File.Exists(encryptedPath))
                    return ApplyCaps(LoadEncrypted(encryptedPath));

                string legacyPath = LegacyFileFor(docKey);
                if (!File.Exists(legacyPath))
                    return new List<ChatTurn>();

                var legacy = ApplyCaps(LoadLegacyJson(legacyPath));
                if (SaveLocked(docKey, legacy))
                {
                    TryDelete(legacyPath);
                    Logger.Startup("legacy plaintext chat history migrated to current-user DPAPI storage");
                }
                else
                {
                    Logger.Error("history",
                        "Legacy history was loaded but encrypted migration did not complete; plaintext source was preserved to avoid data loss.",
                        null);
                }
                return legacy;
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to load local chat history.", ex);
                return new List<ChatTurn>();
            }
        }

        private static List<ChatTurn> LoadEncrypted(string path)
        {
            var file = new FileInfo(path);
            if (file.Length > MaxProtectedHistoryFileBytes)
                throw new InvalidDataException("Encrypted history file exceeded the 9 MB safety limit.");

            byte[] blob = File.ReadAllBytes(path);
            if (blob.Length <= Magic.Length || !StartsWith(blob, Magic))
                throw new InvalidDataException("Encrypted history header is invalid.");

            byte[] protectedPayload = new byte[blob.Length - Magic.Length];
            Buffer.BlockCopy(blob, Magic.Length, protectedPayload, 0, protectedPayload.Length);
            byte[] plain = null;
            try
            {
                plain = ProtectedData.Unprotect(protectedPayload, Entropy, DataProtectionScope.CurrentUser);
                if (plain.LongLength > MaxHistoryFileBytes)
                    throw new InvalidDataException("Decrypted history payload exceeded the 8 MB safety limit.");

                string json = Encoding.UTF8.GetString(plain);
                return JsonConvert.DeserializeObject<List<ChatTurn>>(json) ?? new List<ChatTurn>();
            }
            finally
            {
                Array.Clear(protectedPayload, 0, protectedPayload.Length);
                if (plain != null) Array.Clear(plain, 0, plain.Length);
                Array.Clear(blob, 0, blob.Length);
            }
        }

        private static List<ChatTurn> LoadLegacyJson(string path)
        {
            var file = new FileInfo(path);
            if (file.Length > MaxHistoryFileBytes)
                throw new InvalidDataException("Legacy history file exceeded the 8 MB safety limit.");

            byte[] encoded = File.ReadAllBytes(path);
            try
            {
                string json = Encoding.UTF8.GetString(encoded);
                return JsonConvert.DeserializeObject<List<ChatTurn>>(json) ?? new List<ChatTurn>();
            }
            finally
            {
                Array.Clear(encoded, 0, encoded.Length);
            }
        }

        public void Save(string docKey, List<ChatTurn> turns)
        {
            lock (IoGate)
            {
                SaveLocked(docKey, turns);
            }
        }

        private bool SaveLocked(string docKey, List<ChatTurn> turns)
        {
            string tmp = null;
            byte[] plain = null;
            byte[] protectedPayload = null;
            byte[] fileBytes = null;
            try
            {
                Directory.CreateDirectory(_dir);
                string path = FileFor(docKey);
                var persistable = ApplyCaps(turns).Select(CloneForPersistence).ToList();
                string json = JsonConvert.SerializeObject(persistable, Formatting.None);
                plain = Encoding.UTF8.GetBytes(json);
                if (plain.LongLength > MaxHistoryFileBytes)
                {
                    Logger.Error("history", "Bounded history serialization still exceeded the file safety limit; save skipped.", null);
                    return false;
                }

                protectedPayload = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
                fileBytes = Concat(Magic, protectedPayload);
                if (fileBytes.LongLength > MaxProtectedHistoryFileBytes)
                {
                    Logger.Error("history", "Protected history serialization exceeded the encrypted file safety limit; save skipped.", null);
                    return false;
                }

                tmp = path + ".tmp";
                using (var stream = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    stream.Write(fileBytes, 0, fileBytes.Length);
                    stream.Flush(true);
                }

                if (File.Exists(path))
                {
                    // Same-volume atomic replacement prevents delete-then-move gaps that can lose
                    // the previous encrypted history if Office exits during a save.
                    File.Replace(tmp, path, null);
                }
                else
                {
                    File.Move(tmp, path);
                }
                tmp = null;

                // A normal save also cleans up a stale pre-migration plaintext file, but only after
                // the encrypted replacement is successfully committed.
                TryDelete(LegacyFileFor(docKey));
                return true;
            }
            catch (Exception ex)
            {
                Logger.Error("history", "Failed to save encrypted local chat history.", ex);
                return false;
            }
            finally
            {
                if (!string.IsNullOrEmpty(tmp)) TryDelete(tmp);
                if (plain != null) Array.Clear(plain, 0, plain.Length);
                if (protectedPayload != null) Array.Clear(protectedPayload, 0, protectedPayload.Length);
                if (fileBytes != null) Array.Clear(fileBytes, 0, fileBytes.Length);
            }
        }

        public void Delete(string docKey)
        {
            lock (IoGate)
            {
                try
                {
                    TryDelete(FileFor(docKey));
                    TryDelete(LegacyFileFor(docKey));
                }
                catch (Exception ex)
                {
                    Logger.Error("history", "Failed to delete local chat history.", ex);
                }
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

        private static bool StartsWith(byte[] blob, byte[] prefix)
        {
            if (blob == null || prefix == null || blob.Length < prefix.Length) return false;
            for (int i = 0; i < prefix.Length; i++)
                if (blob[i] != prefix[i]) return false;
            return true;
        }

        private static byte[] Concat(byte[] a, byte[] b)
        {
            var result = new byte[a.Length + b.Length];
            Buffer.BlockCopy(a, 0, result, 0, a.Length);
            Buffer.BlockCopy(b, 0, result, a.Length, b.Length);
            return result;
        }

        private static void TryDelete(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            try { if (File.Exists(path)) File.Delete(path); } catch { }
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
