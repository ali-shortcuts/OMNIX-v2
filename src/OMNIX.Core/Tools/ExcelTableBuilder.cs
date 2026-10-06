using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Excel = Microsoft.Office.Interop.Excel;

namespace OMNIX.Core.Tools
{
    /// <summary>
    /// Additive Excel worksheet/table builder.
    /// Existing sheets are never overwritten. Primitive strings are always literal text.
    /// Formula/date cells require explicit typed objects, so a model cannot accidentally turn
    /// ordinary imported text into executable Excel formulas.
    /// </summary>
    public static class ExcelTableBuilder
    {
        private const int MaxPlanChars = 32000;
        private const int MaxHeaders = 24;
        private const int MaxRows = 50;
        private const int MaxCells = 512;
        private const int MaxFormulaChars = 8192;
        private const int MaxCellTextChars = 500;

        public static JObject ValidatePlan(string json)
        {
            if (string.IsNullOrEmpty(json) || json.Length > MaxPlanChars)
                throw new ArgumentException("Table plan must be nonempty and at most " + MaxPlanChars + " characters.");

            JObject plan;
            using (var reader = new JsonTextReader(new System.IO.StringReader(json)))
            {
                reader.DateParseHandling = DateParseHandling.None;
                plan = JObject.Load(reader);
            }

            ValidateSheetName((string)plan["sheet"]);
            if (plan["title"] != null && (plan["title"].Type != JTokenType.String || ((string)plan["title"]).Length > 200))
                throw new ArgumentException("title must be text of at most 200 characters.");
            int firstRow = HeaderRow(plan);
            if (firstRow < 1 || firstRow > 100) throw new ArgumentException("startRow must be between 1 and 100.");
            if (!string.IsNullOrWhiteSpace((string)plan["title"]) && firstRow < 3)
                throw new ArgumentException("A separate title requires startRow >= 3.");

            var headers = plan["headers"] as JArray;
            var rows = plan["rows"] as JArray;
            if (headers == null || headers.Count < 1 || headers.Count > MaxHeaders || rows == null || rows.Count > MaxRows)
                throw new ArgumentException("Provide 1–" + MaxHeaders + " headers and 0–" + MaxRows + " rows.");

            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var h in headers)
            {
                string text = h.Type == JTokenType.String ? (string)h : null;
                if (string.IsNullOrWhiteSpace(text) || text.Length > 100 || !names.Add(text.Trim()))
                    throw new ArgumentException("Headers must be distinct nonempty text, at most 100 characters.");
            }

            if ((rows.Count + 1) * headers.Count > MaxCells)
                throw new ArgumentException("Create at most " + MaxCells + " cells per table operation; split larger imports into stages.");

            foreach (var token in rows)
            {
                var row = token as JArray;
                if (row == null || row.Count != headers.Count)
                    throw new ArgumentException("Every row must match the headers.");
                foreach (var value in row)
                    ValidateCell(value);
            }

            return plan;
        }

        public static int HeaderRow(JObject plan)
        {
            if (plan["startRow"] != null && plan["startRow"].Type != JTokenType.Integer)
                throw new ArgumentException("startRow must be an integer.");
            return plan["startRow"] != null ? (int)plan["startRow"] :
                string.IsNullOrWhiteSpace((string)plan["title"]) ? 1 : 4;
        }

        private static void ValidateCell(JToken value)
        {
            if (value == null || value.Type == JTokenType.Null) return;

            if (value.Type == JTokenType.String)
            {
                if (value.ToString().Length > MaxCellTextChars)
                    throw new ArgumentException("Cell text exceeds " + MaxCellTextChars + " characters.");
                if (value.ToString().TrimStart().StartsWith("=", StringComparison.Ordinal))
                    throw new ArgumentException("Formula-looking text would not calculate. Use an explicit {formula: ...} cell for calculation, or prefix intentional literal text with an apostrophe.");
                return;
            }

            if (value.Type == JTokenType.Integer)
            {
                if (Math.Abs(Convert.ToDouble(value, CultureInfo.InvariantCulture)) > 999999999999999d)
                    throw new ArgumentException("Use text for identifiers or integers longer than 15 digits to preserve Excel precision.");
                return;
            }

            if (value.Type == JTokenType.Float)
            {
                double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
                if (double.IsNaN(number) || double.IsInfinity(number))
                    throw new ArgumentException("Numbers must be finite.");
                return;
            }

            if (value.Type == JTokenType.Boolean) return;

            var obj = value as JObject;
            if (obj == null)
                throw new ArgumentException("Cells must be text, numbers, booleans, null, or a typed formula/date object.");

            bool hasFormula = obj["formula"] != null;
            bool hasDate = obj["date"] != null;
            if (hasFormula == hasDate)
                throw new ArgumentException("Typed cells must contain exactly one of 'formula' or 'date'.");

            if (hasFormula)
            {
                string formula = (string)obj["formula"];
                if (string.IsNullOrWhiteSpace(formula) || !formula.TrimStart().StartsWith("=", StringComparison.Ordinal))
                    throw new ArgumentException("Formula cells must begin with '='.");
                if (formula.Length > MaxFormulaChars)
                    throw new ArgumentException("Formula exceeds the Excel formula safety limit.");
            }
            else
            {
                string date = (string)obj["date"];
                DateTime parsed;
                if (!DateTime.TryParseExact(date, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out parsed))
                    throw new ArgumentException("Date cells must use ISO yyyy-MM-dd.");
            }

            var format = obj["numberFormat"];
            if (format != null && (format.Type != JTokenType.String || format.ToString().Length > 80))
                throw new ArgumentException("numberFormat must be short text.");
        }

        private static void ValidateSheetName(string name)
        {
            if (string.IsNullOrWhiteSpace(name) || name.Length > 31 ||
                name.IndexOfAny(new[] { ':', '\\', '/', '?', '*', '[', ']' }) >= 0 ||
                name.StartsWith("'") || name.EndsWith("'") || name.Any(char.IsControl))
                throw new ArgumentException("Use a valid new worksheet name (1–31 characters).");
        }

        private static Excel.Workbook RequireEditableWorkbook(Excel.Application app)
        {
            var wb = app.ActiveWorkbook;
            if (wb == null || wb.ReadOnly || wb.ProtectStructure)
                throw new InvalidOperationException("An editable workbook with unprotected structure is required.");
            return wb;
        }

        private static bool SheetExists(Excel.Workbook wb, string name)
        {
            foreach (object item in wb.Sheets)
            {
                string existing = item is Excel.Worksheet
                    ? ((Excel.Worksheet)item).Name
                    : ((Excel.Chart)item).Name;
                if (string.Equals(existing, name, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static string ResolveUniqueSheetName(Excel.Workbook wb, string preferred)
        {
            if (!SheetExists(wb, preferred)) return preferred;
            for (int n = 2; n <= 999; n++)
            {
                string suffix = " (" + n + ")";
                int baseLength = Math.Max(1, 31 - suffix.Length);
                string candidate = (preferred.Length > baseLength ? preferred.Substring(0, baseLength) : preferred) + suffix;
                if (!SheetExists(wb, candidate)) return candidate;
            }
            throw new InvalidOperationException("Could not resolve a unique worksheet name.");
        }

        public static WritePreview Prepare(Excel.Application app, string json)
        {
            var plan = ValidatePlan(json);
            var wb = RequireEditableWorkbook(app);
            string requested = (string)plan["sheet"];
            bool uniqueName = plan["uniqueName"] != null && (bool)plan["uniqueName"];
            string resolved = requested;

            if (SheetExists(wb, requested))
            {
                if (!uniqueName)
                    throw new InvalidOperationException("That sheet already exists. Existing data will not be overwritten.");
                resolved = ResolveUniqueSheetName(wb, requested);
            }

            // Bind the exact previewed name into the approved arguments. Apply must not silently
            // choose a different destination after the user has reviewed the preview.
            plan["sheet"] = resolved;
            plan["uniqueName"] = false;
            plan["startRow"] = HeaderRow(plan);

            var headers = (JArray)plan["headers"];
            var rows = (JArray)plan["rows"];
            int formulas = rows.SelectMany(r => (JArray)r).Count(v => v is JObject && ((JObject)v)["formula"] != null);
            int dates = rows.SelectMany(r => (JArray)r).Count(v => v is JObject && ((JObject)v)["date"] != null);

            return new WritePreview
            {
                ToolName = ToolNames.CreateDataTable,
                Title = "Create Excel sheet: " + resolved,
                Before = "All existing worksheets remain unchanged. A new sheet will be added.",
                After = "Sheet '" + resolved + "'; header row " + HeaderRow(plan) + "; title: " + ((string)plan["title"] ?? "none") + "; " + headers.Count + " columns, " + rows.Count +
                        " data rows, " + formulas + " real Excel formulas, " + dates +
                        " typed dates. A styled table and fitted columns will be created.",
                ArgumentsJson = plan.ToString(Formatting.None)
            };
        }

        public static void Apply(Excel.Application app, string json)
        {
            var plan = ValidatePlan(json);
            var wb = RequireEditableWorkbook(app);
            string sheetName = (string)plan["sheet"];
            if (SheetExists(wb, sheetName))
                throw new InvalidOperationException("The approved target sheet now exists. Nothing was overwritten; inspect the workbook and retry.");

            var headers = (JArray)plan["headers"];
            var rows = (JArray)plan["rows"];
            Excel.Worksheet created = null;
            bool completed = false;
            bool events = app.EnableEvents;
            object previousSheet = app.ActiveSheet;

            try
            {
                app.EnableEvents = false;
                created = (Excel.Worksheet)wb.Worksheets.Add(After: wb.Sheets[wb.Sheets.Count]);
                created.Name = sheetName;

                int headerRow = HeaderRow(plan);
                string title = (string)plan["title"];
                if (!string.IsNullOrWhiteSpace(title))
                {
                    var heading = created.Range["A1"].Resize[Math.Min(2, HeaderRow(plan) - 1), headers.Count];
                    heading.Merge();
                    heading.NumberFormat = "@";
                    heading.Value2 = title;
                    heading.Font.Size = 18;
                    heading.Font.Bold = true;
                    heading.HorizontalAlignment = Excel.XlHAlign.xlHAlignCenter;
                    heading.RowHeight = 32;
                    heading.Borders.LineStyle = Excel.XlLineStyle.xlContinuous;
                }
                int dataRowCount = Math.Max(1, rows.Count);
                var area = ((Excel.Range)created.Cells[headerRow, 1]).Resize[dataRowCount + 1, headers.Count];

                var headerValues=new object[1,headers.Count];
                for(int c=0;c<headers.Count;c++) headerValues[0,c]=(string)headers[c];
                var headerRange=((Excel.Range)created.Cells[headerRow,1]).Resize[1,headers.Count];
                headerRange.NumberFormat="@";
                headerRange.Value2=headerValues;
                var batches=ExcelCellBatch.Build(plan);
                foreach(var batch in batches)
                {
                    var target=((Excel.Range)created.Cells[headerRow+1+batch.Row,batch.Column+1]).Resize[batch.Count,1];
                    target.NumberFormat=batch.NumberFormat;
                    if(batch.IsFormula) target.Formula=batch.Values;
                    else target.Value2=batch.Values;
                }

                var table = created.ListObjects.Add(
                    Excel.XlListObjectSourceType.xlSrcRange,
                    area,
                    Type.Missing,
                    Excel.XlYesNoGuess.xlYes,
                    Type.Missing);
                table.TableStyle = "TableStyleMedium2";

                ((Excel.Range)created.Cells[headerRow, 1]).Resize[1, headers.Count].WrapText = true;
                var header = ((Excel.Range)created.Cells[headerRow, 1]).Resize[1, headers.Count];
                header.HorizontalAlignment = Excel.XlHAlign.xlHAlignCenter;
                header.VerticalAlignment = Excel.XlVAlign.xlVAlignCenter;
                area.VerticalAlignment = Excel.XlVAlign.xlVAlignCenter;
                area.Columns.AutoFit();
                for (int c = 1; c <= headers.Count; c++)
                {
                    var column = (Excel.Range)created.Columns[c];
                    if (Convert.ToDouble(column.ColumnWidth) > 36d) column.ColumnWidth = 36d;
                    else if (Convert.ToDouble(column.ColumnWidth) < 10d) column.ColumnWidth = 10d;
                }
                ((Excel.Range)created.Cells[headerRow, 1]).Resize[1, headers.Count].EntireRow.AutoFit();

                if(rows.Count>0)
                {
                    var data=((Excel.Range)created.Cells[headerRow+1,1]).Resize[rows.Count,headers.Count];
                    // Two bounded bulk reads; formula type is checked once per semantic batch.
                    ExcelCellBatch.Verify(plan,data.Value2,data.Formula,batch=>
                    {
                        var target=((Excel.Range)created.Cells[headerRow+1+batch.Row,batch.Column+1]).Resize[batch.Count,1];
                        object value=target.HasFormula;
                        return value is bool?(bool?)value:null;
                    });
                }

                if (table.ListColumns.Count != headers.Count ||
                    table.ListRows.Count != dataRowCount)
                    throw new InvalidOperationException("Table dimensions did not match the approved plan.");

                object storedHeaders=headerRange.Value2;
                for (int c = 0; c < headers.Count; c++)
                {
                    if (!Agent.OfficePostconditions.ValuesEqual(ExcelCellBatch.MatrixCell(storedHeaders,0,c,1,headers.Count),headers[c]))
                        throw new InvalidOperationException("Table header verification failed.");
                }

                completed = true;
            }
            catch (Exception failure)
            {
                if (created != null)
                {
                    bool alerts = app.DisplayAlerts;
                    try
                    {
                        app.DisplayAlerts = false;
                        created.Delete();
                    }
                    catch (Exception cleanup)
                    {
                        throw new InvalidOperationException(
                            "Sheet creation failed and its new worksheet could not be removed. Inspect the new sheet before retrying.",
                            new AggregateException(failure, cleanup));
                    }
                    finally
                    {
                        app.DisplayAlerts = alerts;
                    }
                }
                throw;
            }
            finally
            {
                try
                {
                    var ws = previousSheet as Excel.Worksheet;
                    var chart = previousSheet as Excel.Chart;
                    if (completed && created != null)
                    {
                        created.Activate();
                        created.Range["A1"].Select();
                    }
                    else if (ws != null) ws.Activate();
                    else if (chart != null) chart.Activate();
                }
                finally
                {
                    app.EnableEvents = events;
                }
            }
        }

    }
}
