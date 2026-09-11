using System;
using System.Text;
using OMNIX.Core.Security;

namespace OMNIX.Core.Context
{
    public static class ContextLimiter
    {
        public static string BuildProviderPayload(OfficeContext context, int maxCharacters)
        {
            if (context == null) return string.Empty;
            int limit = Math.Max(512, Math.Min(maxCharacters, 32000));
            var sb = new StringBuilder(Math.Min(limit, 8192));

            Append(sb, "Host: ", context.Host, limit);
            Append(sb, "Document: ", context.DocumentName, limit);
            Append(sb, "Container: ", context.ActiveContainer, limit);
            Append(sb, "Selection: ", context.SelectionText, limit);

            if (context.Items != null)
            {
                foreach (OfficeContextItem item in context.Items)
                {
                    if (sb.Length >= limit) break;
                    Append(sb, "[" + (item.Kind ?? "Item") + "] ", item.Address, limit);
                    Append(sb, " Text=", item.Text, limit);
                    if (!string.IsNullOrWhiteSpace(item.Formula)) Append(sb, " Formula=", item.Formula, limit);
                    sb.AppendLine();
                }
            }

            string bounded = sb.ToString();
            if (bounded.Length > limit) bounded = bounded.Substring(0, limit);
            return UntrustedData.Wrap("OFFICE CONTEXT", bounded);
        }

        private static void Append(StringBuilder sb, string prefix, string value, int limit)
        {
            if (sb.Length >= limit || string.IsNullOrEmpty(value)) return;
            string safe = value.Replace("\0", string.Empty);
            int remaining = limit - sb.Length - prefix.Length;
            if (remaining <= 0) return;
            if (safe.Length > remaining) safe = safe.Substring(0, remaining);
            sb.Append(prefix).Append(safe).AppendLine();
        }
    }
}
