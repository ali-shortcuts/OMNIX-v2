using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using OMNIX.Core.Context;

namespace OMNIX.Core.Reference
{
    // Names and official links, not a replacement calculation engine or a capability claim.
    public static class OfficeReference
    {
        private static readonly Lazy<Dictionary<string, string>> Excel =
            new Lazy<Dictionary<string, string>>(() =>
            {
                using (var stream = typeof(OfficeReference).Assembly.GetManifestResourceStream("OMNIX.ExcelFunctions.json"))
                using (var reader = new StreamReader(stream))
                    return JsonConvert.DeserializeObject<Dictionary<string, string>>(reader.ReadToEnd());
            });

        public static string Search(string host, string query, int offset = 0, string language = "en")
        {
            HostType type;
            if (!Enum.TryParse(host, true, out type) || (type != HostType.Excel && type != HostType.Word && type != HostType.PowerPoint))
                return "Choose Excel, Word or PowerPoint.";
            string catalog = OfficeCapabilityRegistry.Search(type, query, offset);
            string label = language == "fa" ? "ابزارهای پیاده‌سازی‌شده در OMNIX (با توجه به اجازه و نسخهٔ Office):" : "Implemented OMNIX tools (subject to Office permissions/version):";
            string recipes = type == HostType.Excel ? FormulaGuidance(query) : "";
            string templates="";
            if(offset==0 && type!=HostType.Excel)
                templates="\n"+(language=="fa"?"الگوها: ":"Templates: ")+(type==HostType.Word?"report · letter · meeting":"briefing · training · sales");
            return SearchReference(host, query, offset, language) + recipes + templates + "\n\n" + label + "\n" + catalog;
        }

        private static string FormulaGuidance(string query)
        {
            var recipes = new Dictionary<string,string> {
                {"SUM", "جمع | =SUM(G5:G14) | Sum only data rows; keep the total outside the summed range to avoid a circular reference."},
                {"MAX", "بیشترین | =MAX(D5:D14) | Check that amounts are numeric, not text."},
                {"AVERAGE", "میانگین | =AVERAGE(D5:D14) | Decide whether missing values mean zero or unknown before calculating."},
                {"SUMIFS", "جمع شرطی | =SUMIFS(G5:G14,C5:C14,\"Paid\") | Sum and criteria ranges must align row for row; use the document's actual status labels."},
                {"COUNTIFS", "شمارش شرطی | =COUNTIFS(C5:C14,\"Paid\") | Counts matching rows, not units sold; use SUMIFS for quantities."},
                {"DSUM", "جمع دیتابیس | =DSUM(A4:G14,\"Amount\",J1:J2) | Database includes its header; criteria header must exactly match a database column; criteria stay outside the data table."},
                {"IFERROR", "خطای فرمول | =IFERROR(D5/E5,\"\") | Do not hide an unexplained calculation error. Decide what zero/blank denominators mean first."},
                {"INDEX", "جستجو | =INDEX(B5:B14,MATCH(J5,A5:A14,0)) | MATCH with 0 requests an exact key; verify key uniqueness and report missing IDs."},
                {"ROUND", "گرد کردن | =ROUND(D5*F5,2) | Confirm the currency's rounding rule; numeric display formatting alone does not round stored values."}
            };
            string q=(query??" ").Trim();
            var matches=recipes.Where(p => q.Length==0 || p.Key.IndexOf(q,StringComparison.OrdinalIgnoreCase)>=0 || p.Value.IndexOf(q,StringComparison.OrdinalIgnoreCase)>=0).Take(9);
            return "\n\nFormula task guidance (adapt ranges to the actual sheet):\n" + string.Join("\n",matches.Select(p=>p.Key+" — "+p.Value));
        }

        private static string SearchReference(string host, string query, int offset, string language)
        {
            query = (query ?? "").Trim();
            bool fa = string.Equals(language, "fa", StringComparison.OrdinalIgnoreCase);

            if (string.Equals(host, "Word", StringComparison.OrdinalIgnoreCase))
            {
                if (fa)
                    return "راهنمای Word\n" +
                           "فرمول‌های جدول در Word به‌صورت Field هستند و موتور فرمول Excel نیستند. " +
                           "Microsoft این ۱۸ تابع را برای فرمول جدول Word مستند کرده است: " +
                           "ABS, AND, AVERAGE, COUNT, DEFINED, FALSE, IF, INT, MAX, MIN, MOD, NOT, OR, PRODUCT, ROUND, SIGN, SUM, TRUE.\n" +
                           "نمونه: =SUM(ABOVE). بعد از تغییر داده‌ها، Fieldها باید Update شوند.\n" +
                           "منبع رسمی: https://support.microsoft.com/en-us/word/use-a-formula-in-a-word-table\n" +
                           "این راهنما به‌تنهایی دسترسی اجرایی تازه‌ای به Word ایجاد نمی‌کند؛ قابلیت‌های واقعی فقط از ابزارهای تأییدشده OMNIX می‌آیند.";

                return "Word table formulas are fields, not an Excel workbook. Microsoft lists 18 functions: " +
                       "ABS, AND, AVERAGE, COUNT, DEFINED, FALSE, IF, INT, MAX, MIN, MOD, NOT, OR, PRODUCT, ROUND, SIGN, SUM, TRUE. " +
                       "Example: =SUM(ABOVE). Update fields after editing data. Supported functions and examples: " +
                       "https://support.microsoft.com/en-us/word/use-a-formula-in-a-word-table\n" +
                       "Use the implemented capability catalog below for Word editing, tables, layout and fields. Reference entries are not additional execution permissions.";
            }

            if (string.Equals(host, "PowerPoint", StringComparison.OrdinalIgnoreCase))
            {
                if (fa)
                    return "راهنمای PowerPoint\n" +
                           "PowerPoint شامل اسلایدها، Shapeها، Notes و چیدمان بصری است و مانند Excel کاتالوگ تابع Worksheet ندارد. " +
                           "OMNIX می‌تواند ساختار اسلاید، متن Shapeها و Notes را بخواند و از ابزارهای نوشتنی تأییدشده استفاده کند. " +
                           "این صفحهٔ راهنما به‌تنهایی دسترسی به همه فرمان‌های Ribbon نمی‌دهد.";

                return "PowerPoint: slides, shapes, notes and visual layout. There is no Excel-style worksheet function catalog for slide text. " +
                       "Use the implemented capability catalog below for slides, shapes, tables, notes and layout. Only listed operations can be executed.";
            }

            var matches = Excel.Value
                .Where(p => p.Key.IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)
                .OrderBy(p => p.Key, StringComparer.Ordinal)
                .ToList();

            offset = Math.Max(0, offset);
            var page = matches.Skip(offset).Take(40).Select(p => p.Key + " — " + p.Value);
            string next = offset + 40 < matches.Count ? (offset + 40).ToString() : (fa ? "پایان" : "none");

            if (fa)
            {
                return "مرجع Excel\n" +
                       Excel.Value.Count + " نام تابع از فهرست رسمی Microsoft نمایه شده است. " +
                       "در دسترس بودن هر تابع به نسخهٔ نصب‌شدهٔ Excel بستگی دارد؛ این عدد به معنی پشتیبانی قطعی همهٔ توابع روی سیستم شما نیست.\n" +
                       "نتایج: " + matches.Count + "؛ شروع صفحه: " + offset + "؛ صفحهٔ بعد: " + next + "\n" +
                       "نمونه‌ها: =MAX(D2:D10) ؛ =SUM(G2:G10) ؛ =DSUM(A1:D20,\"Amount\",F1:F2)\n" +
                       "نام توابع همان نام رسمی انگلیسی Excel باقی می‌ماند تا فرمول‌ها دقیق باشند.\n\n" +
                       string.Join("\n", page);
            }

            return "Excel reference: " + Excel.Value.Count +
                   " names indexed from Microsoft on 2026-09-21. Availability depends on Excel version; this is not an installed-function count.\n" +
                   "Matches: " + matches.Count + "; offset: " + offset + "; nextOffset: " + next + "\n" +
                   "Examples: =MAX(D2:D10); =SUM(G2:G10); =DSUM(A1:D20,\"Amount\",F1:F2). DSUM requires matching criteria headers.\n" +
                   string.Join("\n", page);
        }
    }
}
