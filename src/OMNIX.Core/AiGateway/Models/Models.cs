using System;
using System.Collections.Generic;
using System.Linq;
using OMNIX.Core.Errors;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway
{
    public sealed class ProviderCredentials
    {
        public string ApiKey { get; set; }
        public string Model { get; set; }
        public string BaseUrl { get; set; }
    }

    public sealed class ChatRequest
    {
        public string SystemPrompt { get; set; }
        public List<ChatTurn> History { get; set; }
        public ChatTurn UserTurn { get; set; }

        public bool HasImages
        {
            get
            {
                if (UserTurn != null && UserTurn.HasImages) return true;
                if (History != null)
                    foreach (var t in History)
                        if (t != null && t.HasImages) return true;
                return false;
            }
        }
    }

    public sealed class ChatResponse
    {
        public string Text { get; set; }
        public string Model { get; set; }
        public bool WasCancelled { get; set; }
    }

    /// <summary>
    /// Hard provider-boundary budget. Local history storage can retain more messages for UI/history,
    /// but every provider request is rebuilt through this limiter before routing. This prevents a
    /// long Office conversation, old screenshots or one giant message from expanding a request
    /// without bound inside Excel/Word/PowerPoint.
    ///
    /// Historical image bytes are intentionally NOT replayed. The newest/current user turn (and
    /// current tool-result turn) may contain bounded images; older image turns receive an explicit
    /// text marker so the model cannot pretend it still sees an image that was omitted.
    /// </summary>
    public static class ChatRequestBudgeter
    {
        private const int HardMaxHistoryTurns = 80;
        private const int HardMaxHistoryChars = 48 * 1024;
        private const int MaxSingleHistoryTurnChars = 12 * 1024;
        private const int MaxSystemPromptChars = 32 * 1024;
        private const int MaxCurrentTurnChars = 64 * 1024;
        private const int MaxCurrentImages = 4;
        private const int MaxImageBytes = 20 * 1024 * 1024;
        private const int MaxCurrentImageBytesTotal = 24 * 1024 * 1024;
        private const string HistoricalImageMarker = "\n[OMNIX: an earlier image was omitted from provider replay to keep request memory bounded; ask the user to reattach it if visual inspection is required.]";

        public static ChatRequest Apply(ChatRequest source)
        {
            if (source == null)
                throw new OmnixException(ErrorCode.CORE_ERROR,
                    "The AI request is empty.", "ChatRequestBudgeter.Apply received null.", "Retry the request.");
            if (source.UserTurn == null)
                throw new OmnixException(ErrorCode.CORE_ERROR,
                    "The AI request has no current user/tool turn.", "ChatRequest.UserTurn is null.", "Retry the request.");

            var settings = SettingsManager.Instance.Settings;
            int configuredTurns = settings != null ? settings.HistoryMaxMessages : HardMaxHistoryTurns;
            int maxTurns = Math.Max(1, Math.Min(HardMaxHistoryTurns, configuredTurns));

            // ContextMaxTokens is a user-controlled context preference, not an exact tokenizer.
            // Use it only as a conservative character budget hint, then enforce hard caps.
            int configuredTokens = settings != null ? settings.ContextMaxTokens : 3000;
            long hintedChars = (long)Math.Max(1000, configuredTokens) * 8L;
            int maxHistoryChars = (int)Math.Max(8 * 1024L, Math.Min(HardMaxHistoryChars, hintedChars));

            var result = new ChatRequest
            {
                SystemPrompt = TruncatePreservingEnds(source.SystemPrompt, MaxSystemPromptChars),
                History = BuildBoundedHistory(source.History, maxTurns, maxHistoryChars),
                UserTurn = CloneCurrentTurn(source.UserTurn)
            };
            return result;
        }

        private static List<ChatTurn> BuildBoundedHistory(List<ChatTurn> source, int maxTurns, int maxChars)
        {
            var chosenNewestFirst = new List<ChatTurn>();
            if (source == null || source.Count == 0) return chosenNewestFirst;

            int usedChars = 0;
            for (int i = source.Count - 1; i >= 0 && chosenNewestFirst.Count < maxTurns; i--)
            {
                var turn = source[i];
                if (turn == null) continue;

                string text = TruncatePreservingEnds(turn.Text, MaxSingleHistoryTurnChars);
                if (turn.HasImages)
                    text = (text ?? string.Empty) + HistoricalImageMarker;

                int remaining = maxChars - usedChars;
                if (remaining <= 0) break;
                if (text != null && text.Length > remaining)
                    text = TruncatePreservingEnds(text, remaining);

                chosenNewestFirst.Add(new ChatTurn
                {
                    Role = turn.Role,
                    Text = text ?? string.Empty,
                    Images = null,
                    TimestampUtc = turn.TimestampUtc
                });
                usedChars += text != null ? text.Length : 0;
            }

            chosenNewestFirst.Reverse();
            return chosenNewestFirst;
        }

        private static ChatTurn CloneCurrentTurn(ChatTurn turn)
        {
            string text = turn.Text ?? string.Empty;
            if (text.Length > MaxCurrentTurnChars)
                throw OmnixException.Model(
                    "This message is too large for one OMNIX request (maximum 64 KB of text). Split it into smaller messages.");

            List<ImageAttachment> images = null;
            if (turn.Images != null && turn.Images.Count > 0)
            {
                images = new List<ImageAttachment>();
                long totalBytes = 0;
                foreach (var image in turn.Images.Where(i => i != null && i.PngBytes != null && i.PngBytes.Length > 0))
                {
                    if (images.Count >= MaxCurrentImages)
                        throw OmnixException.Model("Too many images in one OMNIX request (maximum 4).");
                    if (image.PngBytes.Length > MaxImageBytes)
                        throw OmnixException.Model("An image exceeds the 20 MB OMNIX safety limit.");
                    totalBytes += image.PngBytes.Length;
                    if (totalBytes > MaxCurrentImageBytesTotal)
                        throw OmnixException.Model("Images in this request exceed the 24 MB combined OMNIX safety limit.");

                    // Share the immutable request byte array instead of duplicating tens of MB in
                    // the Office process. Provider adapters never mutate attachment bytes.
                    images.Add(new ImageAttachment
                    {
                        FileName = SafeLabel(image.FileName, 160),
                        SourceLabel = SafeLabel(image.SourceLabel, 120),
                        PngBytes = image.PngBytes
                    });
                }
            }

            return new ChatTurn
            {
                Role = turn.Role,
                Text = text,
                Images = images,
                TimestampUtc = turn.TimestampUtc
            };
        }

        private static string TruncatePreservingEnds(string value, int maxChars)
        {
            if (string.IsNullOrEmpty(value) || maxChars <= 0) return string.Empty;
            if (value.Length <= maxChars) return value;
            if (maxChars < 96) return value.Substring(value.Length - maxChars, maxChars);

            const string marker = "\n…[OMNIX request history truncated]…\n";
            int available = Math.Max(1, maxChars - marker.Length);
            int head = available / 2;
            int tail = available - head;
            return value.Substring(0, head) + marker + value.Substring(value.Length - tail, tail);
        }

        private static string SafeLabel(string value, int maxChars)
        {
            value = value ?? string.Empty;
            return value.Length <= maxChars ? value : value.Substring(0, maxChars);
        }
    }
}
