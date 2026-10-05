using System;
using System.Linq;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Context;

namespace OMNIX.Core.Agent
{
    // Conservative, deterministic obligations from explicit wording. Not a general NLP judge.
    public static class RequestCoverage
    {
        public static string Validate(string request, JArray steps, HostType host)
        {
            if (host != HostType.Excel) return null;
            string q = (request ?? "").ToLowerInvariant();
            var checks = steps.OfType<JObject>().SelectMany(s => ((JArray)s["checks"]).OfType<JObject>()).ToList();
            bool heading = (q.Contains("نام دکان") || q.Contains("اسم دکان") || q.Contains("نام فروشنده") || q.Contains("اسم فروشنده") || q.Contains("shop name") || q.Contains("seller name")) &&
                (q.Contains("بالا") || q.Contains("above") || q.Contains("top"));
            if (heading && !checks.Any(c => (string)c["kind"] == "heading"))
                return "REQUEST COVERAGE: a separate shop/seller heading above the table requires a native heading check; a data column is insufficient.";
            bool formula = !q.Contains("بدون فرمول") && !q.Contains("بدون فورمول") && !q.Contains("no formula") && (Regex.IsMatch(q, @"(?:فرمول|فورمول|formula).{0,35}(?:بساز|اضافه|بنویس|add|insert|create)") ||
                Regex.IsMatch(q, @"(?:add|insert|create).{0,35}formula"));
            if (formula && !checks.Any(c => (string)c["kind"] == "formula"))
                return "REQUEST COVERAGE: the explicitly requested formula requires an exact formula and computed-result check.";
            foreach (Match m in Regex.Matches(request ?? "", "(?:شیت|sheet)\\s*[«\"“]([^»\"”\\r\\n]{1,31})[»\"”]", RegexOptions.IgnoreCase))
                if (!checks.Any(c => string.Equals((string)c["sheet"], m.Groups[1].Value, StringComparison.OrdinalIgnoreCase)))
                    return "REQUEST COVERAGE: an explicitly named sheet lacks native acceptance checks. Include every requested sheet; do not drop goals.";
            return null;
        }
    }
}
