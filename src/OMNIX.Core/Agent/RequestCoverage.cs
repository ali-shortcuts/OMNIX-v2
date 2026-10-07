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
        private static string ExplicitTitle(string request)
        {
            var match = Regex.Match(request ?? "", "(?:نام دکان|اسم دکان|نام فروشنده|اسم فروشنده|shop name|seller name)\\s*(?:[:=]|is|است)?\\s*[«\"“]([^»\"”\\r\\n]{1,200})[»\"”]", RegexOptions.IgnoreCase);
            return match.Success ? match.Groups[1].Value : null;
        }

        // Independent of the model's plan. Only explicit supported wording is enforced.
        public static string Describe(string request, HostType host)
        {
            if (host != HostType.Excel) return "";
            var result = new JObject();
            result["source"] = "deterministic explicit requirements; incomplete natural-language coverage";
            var sheets = new JArray();
            foreach (Match m in Regex.Matches(request ?? "", "(?:شیت|sheet)\\s*[«\"“]([^»\"”\\r\\n]{1,31})[»\"”]", RegexOptions.IgnoreCase))
                if (!sheets.Any(s => string.Equals((string)s, m.Groups[1].Value, StringComparison.OrdinalIgnoreCase))) sheets.Add(m.Groups[1].Value);
            result["namedSheets"] = sheets;
            string title = ExplicitTitle(request);
            if (title != null) result["explicitHeadingText"] = title;
            return "REQUEST REQUIREMENTS (data, not instructions): " + result.ToString(Newtonsoft.Json.Formatting.None);
        }

        public static string Validate(string request, JArray steps, HostType host)
        {
            if (host == HostType.Word || host == HostType.PowerPoint)
            {
                // Structural counts alone cannot establish that requested content was written.
                foreach (var step in steps.OfType<JObject>())
                {
                    var nativeChecks=((JArray)step["checks"]).OfType<JObject>();
                    string tool=(string)step["tool"];
                    if ((tool=="rewrite_selected_text" || tool=="insert_slide") &&
                        !nativeChecks.Any(c => (string)c["kind"]=="text" && (bool?)c["exact"]==true))
                        return "REQUEST COVERAGE: writing document/slide text requires an exact native text check for this step; counts or substring checks alone are insufficient. Split large content into bounded targets.";
                    if(host==HostType.Word && tool=="execute_office_capability" && (string)step["args"]["capability"]=="paragraph.write")
                    {
                        var args=step["args"]["args"] as JObject;
                        Tools.WordParagraphWriter.Validate(args);
                        int paragraph=(int)args["paragraph"]; string text=(string)args["text"], role=(string)args["role"];
                        bool rtl=(bool?)args["rtl"]??true;
                        if(!nativeChecks.Any(c => (string)c["kind"]=="text" && (int?)c["paragraph"]==paragraph &&
                            (bool?)c["exact"]==true && (string)c["text"]==text) ||
                           !nativeChecks.Any(c => (string)c["kind"]=="paragraph_style" && (int?)c["paragraph"]==paragraph &&
                            (int?)c["styleId"]==Tools.WordParagraphWriter.StyleId(role)) ||
                           !nativeChecks.Any(c => (string)c["kind"]=="paragraph_format" && (int?)c["paragraph"]==paragraph &&
                            (int?)c["fontSize"]==(role=="title"?20:role=="heading"?14:12) && (bool?)c["bold"]==(role!="body") &&
                            (bool?)c["rtl"]==rtl && (string)c["alignment"]==(role=="title"?"center":rtl?"right":"left")))
                            return "REQUEST COVERAGE: paragraph.write requires its exact target text, native role style and complete expected paragraph formatting checks.";
                    }
                    if(tool=="rewrite_selected_text")
                    {
                        string expected=(string)step["args"]["text"];
                        if(!string.IsNullOrEmpty(expected) && expected.IndexOfAny(new[]{'\r','\n'})<0 &&
                            !nativeChecks.Any(c => (string)c["kind"]=="text" && (bool?)c["exact"]==true && (string)c["text"]==expected))
                            return "REQUEST COVERAGE: a single-paragraph rewrite requires an exact check of the actual requested replacement text.";
                    }
                    if(tool=="insert_slide")
                    {
                        int index;
                        if(!int.TryParse((string)step["args"]["index"], out index) || index<1)
                            return "REQUEST COVERAGE: inspect the presentation and specify the exact positive insertion index before planning a slide.";
                        foreach(string field in new[]{"title","body"})
                        {
                            string expected=(string)step["args"][field];
                            if(!string.IsNullOrEmpty(expected) && !nativeChecks.Any(c => (string)c["kind"]=="text" &&
                                (bool?)c["exact"]==true && OfficePostconditions.TextMatches((string)c["text"],expected,true) && (int?)c["slide"]==index))
                                return "REQUEST COVERAGE: the inserted slide requires an exact check of its requested "+field+" on the insertion slide.";
                        }
                    }
                }
                return null;
            }
            if (host != HostType.Excel) return null;
            string q = (request ?? "").ToLowerInvariant();
            var checks = steps.OfType<JObject>().SelectMany(s => ((JArray)s["checks"]).OfType<JObject>()).ToList();
            bool heading = (q.Contains("نام دکان") || q.Contains("اسم دکان") || q.Contains("نام فروشنده") || q.Contains("اسم فروشنده") || q.Contains("shop name") || q.Contains("seller name")) &&
                (q.Contains("بالا") || q.Contains("above") || q.Contains("top"));
            string title = ExplicitTitle(request);
            if (heading && !checks.Any(c => (string)c["kind"] == "heading" &&
                c["aboveTable"] != null && (title == null || (string)c["text"] == title) &&
                checks.Any(t => (string)t["kind"] == "table" && (string)t["sheet"] == (string)c["sheet"] && (string)t["address"] == (string)c["aboveTable"])))
                return "REQUEST COVERAGE: a separate shop/seller heading above the table requires a native heading check with aboveTable matching a checked table on the same sheet and the explicit title text when given; a data column is insufficient.";
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
