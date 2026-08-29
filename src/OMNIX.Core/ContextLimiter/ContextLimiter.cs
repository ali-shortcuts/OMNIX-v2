using System;
using System.Linq;
using System.Text;
using OMNIX.Core.Context;
using OMNIX.Core.Security;
using OMNIX.Core.Settings;
using OMNIX.Core.Util;

namespace OMNIX.Core.ContextLimiter
{
    /// <summary>Spec Layer 4: rough token estimation (chars/4 heuristic, CJK-aware).</summary>
    public static class TokenEstimator
    {
        public static int EstimateTokens(string text)
        {
            if (string.IsNullOrEmpty(text)) return 0;
            int cjk = 0;
            foreach (char c in text)
            {
                if (c >= 0x2E80 && c <= 0x9FFF) cjk++;
            }
            int other = text.Length - cjk;
            return cjk + other / 4;
        }
    }

    /// <summary>Spec Layer 4: splits oversized payloads into manageable chunks.</summary>
    public static class Chunker
    {
        public static string[] SplitByChars(string text, int maxCharsPerChunk)
        {
            if (string.IsNullOrEmpty(text)) return new string[0];
            if (text.Length <= maxCharsPerChunk) return new[] { text };

            var parts = new System.Collections.Generic.List<string>();
            int start = 0;
            while (start < text.Length)
            {
                int len = Math.Min(maxCharsPerChunk, text.Length - start);
                // Prefer breaking at a newline so tables/rows stay intact.
                int cut = start + len;
                if (cut < text.Length)
                {
                    int nl = text.LastIndexOf('\n', cut, len);
                    if (nl > start) len = nl - start + 1;
                }
                parts.Add(text.Substring(start, len));
                start += len;
            }
            return parts.ToArray();
        }
    }

    /// <summary>
    /// Spec Layer 4: deterministic local summarizer (no AI call): keeps the structure —
    /// headings/first rows/selection stats — and marks truncation honestly.
    /// </summary>
    public static class Summarizer
    {
        public static string Summarize(string text, int maxChars)
        {
            if (string.IsNullOrEmpty(text)) return string.Empty;
            if (text.Length <= maxChars) return text;
            string[] lines = text.Split('\n');
            var keep = new StringBuilder();
            int budget = maxChars;
            foreach (string raw in lines)
            {
                string line = raw.TrimEnd();
                if (line.Length == 0) continue;
                bool structural = line.StartsWith("#") || line.StartsWith("---") || line.StartsWith("•");
                if (structural || keep.Length < maxChars / 3)
                {
                    string piece = line + Environment.NewLine;
                    if (piece.Length > budget) break;
                    keep.Append(piece);
                    budget -= piece.Length;
                }
            }
            keep.AppendLine("…[SUMMARY MODE: " + (lines.Length) + " lines condensed — full data exceeded the context cap]");
            return keep.ToString();
        }
    }

    /// <summary>
    /// Builds the UNTRUSTED context payload for a request. NEVER lets a whole workbook/document
    /// pass through unfiltered — selection first, document overview second, caps enforced.
    /// </summary>
    public static class ContextLimiter
    {
        public static string BuildContextPayload(IHostAdapter adapter, OfficeContext ctx)
        {
            var settings = SettingsManager.Instance.Settings;
            var sb = new StringBuilder();

            sb.AppendLine("Host: " + adapter.HostDisplayName);
            sb.AppendLine("Document: " + (ctx.DocumentName ?? "(unnamed)"));
            if (!string.IsNullOrEmpty(ctx.ContainerName)) sb.AppendLine("Container: " + ctx.ContainerName);
            if (ctx.Host == HostType.PowerPoint)
            {
                sb.AppendLine("Slide: " + ctx.CurrentSlideIndex + " / " + ctx.SlideCount);
                if (!string.IsNullOrEmpty(ctx.SlideTitle)) sb.AppendLine("Slide title: " + ctx.SlideTitle);
            }
            if (!string.IsNullOrEmpty(ctx.SelectionAddress))
                sb.AppendLine("Current selection: " + ctx.SelectionAddress);

            // 1) Selection is the most relevant signal — full detail within caps.
            string selection = adapter.ReadSelection();
            if (!string.IsNullOrEmpty(selection))
            {
                int selTokens = TokenEstimator.EstimateTokens(selection);
                if (selTokens > settings.ContextMaxTokens / 2)
                    selection = Summarizer.Summarize(selection, settings.ContextMaxChars / 2);
                sb.AppendLine();
                sb.AppendLine(UntrustedData.Wrap("CURRENT SELECTION", selection));
            }

            // 2) A compact overview of the whole document (capped much harder).
            if (ctx.Host == HostType.Excel)
            {
                sb.AppendLine();
                sb.AppendLine("Named ranges: " + (ctx.NamedRanges ?? "(none)"));
                sb.AppendLine("Charts: " + (ctx.ChartsInfo ?? "(none)"));
                if (!string.IsNullOrEmpty(ctx.ValuesPreview))
                    sb.AppendLine(UntrustedData.Wrap("SELECTION VALUES", ctx.ValuesPreview));
            }
            else if (ctx.Host == HostType.Word)
            {
                sb.AppendLine("Headings: " + (ctx.HeadingsPreview ?? "(none)"));
                sb.AppendLine("Track Changes: " + TextUtil.YesNo(ctx.HasTrackChanges) +
                              " | Comments: " + ctx.CommentCount);
            }
            else if (ctx.Host == HostType.PowerPoint)
            {
                if (!string.IsNullOrEmpty(ctx.NotesPreview))
                    sb.AppendLine("Speaker notes: " + TextUtil.Truncate(ctx.NotesPreview, 400));
            }

            string whole = sb.ToString();
            if (TokenEstimator.EstimateTokens(whole) > settings.ContextMaxTokens)
                whole = Summarizer.Summarize(whole, settings.ContextMaxChars);
            return whole;
        }
    }
}
