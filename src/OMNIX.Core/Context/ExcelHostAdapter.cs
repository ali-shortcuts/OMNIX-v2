using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Excel = Microsoft.Office.Interop.Excel;
using OMNIX.Core.Errors;
using OMNIX.Core.Tools;
using OMNIX.Core.Util;

namespace OMNIX.Core.Context
{
    /// <summary>
    /// Excel adapter (spec Section 3, Layer 3): Workbook, Worksheet, Selection, Values, Formulas,
    /// Named Ranges, Charts (as image for Vision). All calls assume the Office UI thread.
    ///
    /// Important performance invariant: context reads are bounded BEFORE COM asks Excel for Value2
    /// or Formula arrays. Reading an entire-column / entire-sheet selection into memory and trimming
    /// it afterward can allocate millions of cells and freeze Office, so all bulk reads first resize
    /// to the configured context budget.
    /// </summary>
    public sealed class ExcelHostAdapter : IHostAdapter
    {
        private const int DisplayMaxColumns = 8;
        private const int FormulaCellCap = 60;
        private const int CaptureCellCap = 5000;

        private readonly Excel.Application _app;
        private readonly Func<int> _maxCells;
        private readonly Func<int> _maxChars;

        public ExcelHostAdapter(Excel.Application app, Func<int> maxCells, Func<int> maxChars)
        {
            _app = app;
            _maxCells = maxCells;
            _maxChars = maxChars;
        }

        public HostType Host { get { return HostType.Excel; } }
        public string HostDisplayName { get { return "Excel"; } }

        public OfficeContext ReadContext()
        {
            var ctx = new OfficeContext { Host = HostType.Excel };
            try
            {
                var wb = _app.ActiveWorkbook;
                if (wb == null) return ctx;
                ctx.DocumentName = wb.Name;
                ctx.DocumentPath = wb.FullName;

                var ws = _app.ActiveSheet as Excel.Worksheet;
                if (ws != null) ctx.ContainerName = ws.Name;

                var sel = _app.Selection as Excel.Range;
                if (sel != null)
                {
                    ctx.SelectionAddress = sel.Address[false, false];
                    ctx.SelectionText = TextUtil.Truncate(Convert.ToString(sel.Text), 200);
                    ctx.ValuesPreview = BuildValuesPreview(sel);
                    ctx.FormulasPreview = BuildFormulasPreview(sel);
                }

                ctx.NamedRanges = BuildNamedRanges(wb);
                ctx.ChartsInfo = BuildChartsInfo(ws);
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "ExcelHostAdapter.ReadContext failed", ex);
            }
            return ctx;
        }

        public string ReadSelection()
        {
            try
            {
                var sel = _app.Selection as Excel.Range;
                if (sel == null) return "(no range selected)";
                var sb = new StringBuilder();
                sb.AppendLine("Range: " + sel.Address[false, false] + " on sheet '" + ActiveSheetName() + "'");
                sb.AppendLine("Rows=" + sel.Rows.Count + " Columns=" + sel.Columns.Count);
                sb.AppendLine("Values:");
                sb.Append(BuildValuesTable(sel, _maxCells()));
                sb.AppendLine("Formulas (first cells):");
                sb.Append(BuildFormulasPreview(sel));
                return sb.ToString();
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "ExcelHostAdapter.ReadSelection failed", ex);
                return "(unable to read selection)";
            }
        }

        public string ReadDocument(int maxChars)
        {
            try
            {
                var wb = _app.ActiveWorkbook;
                if (wb == null) return "(no workbook open)";
                var sb = new StringBuilder();
                sb.AppendLine("Workbook: " + wb.Name);
                foreach (Excel.Worksheet ws in wb.Worksheets)
                {
                    var used = ws.UsedRange;
                    sb.AppendLine();
                    sb.AppendLine("--- Sheet '" + ws.Name + "' used range: " + used.Address[false, false] + " ---");
                    // BuildValuesTable resizes before Value2 is requested, so a corrupted/oversized
                    // UsedRange cannot force a full-sheet COM array allocation.
                    sb.Append(BuildValuesTable(used, 200));
                    if (sb.Length >= Math.Min(maxChars, _maxChars())) break;
                }
                return TextUtil.Truncate(sb.ToString(), Math.Min(maxChars, _maxChars()));
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "ExcelHostAdapter.ReadDocument failed", ex);
                return "(unable to read workbook)";
            }
        }

        public byte[] CaptureChartAsImage(string chartName)
        {
            try
            {
                var ws = _app.ActiveSheet as Excel.Worksheet;
                if (ws == null) return null;
                Excel.Chart chart = null;
                if (!string.IsNullOrEmpty(chartName))
                {
                    foreach (Excel.ChartObject co in (Excel.ChartObjects)ws.ChartObjects())
                    {
                        if (string.Equals(co.Name, chartName, StringComparison.OrdinalIgnoreCase))
                        {
                            chart = co.Chart;
                            break;
                        }
                    }
                }
                if (chart == null)
                {
                    try { chart = _app.ActiveChart; } catch { }
                }
                if (chart == null) return null;

                return TempImageCapture.FromExporter(path => chart.Export(path, "PNG", true));
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "ExcelHostAdapter.CaptureChartAsImage failed", ex);
                return null;
            }
        }

        public byte[] CaptureSlideAsImage(int slideIndexOneBased)
        {
            return null; // Excel has no slides
        }

        public byte[] CaptureCurrentViewAsImage()
        {
            // Prefer the active chart. For a huge range selection, capture the visible window range
            // instead of asking Excel/clipboard to render an entire column/sheet into one bitmap.
            try
            {
                var chartImg = CaptureChartAsImage(null);
                if (chartImg != null && chartImg.Length > 0) return chartImg;

                var sel = _app.Selection as Excel.Range;
                if (sel == null) return null;

                Excel.Range captureRange = FirstArea(sel);
                try
                {
                    if (Convert.ToDouble(captureRange.Cells.CountLarge) > CaptureCellCap)
                    {
                        var win = _app.ActiveWindow;
                        var visible = win != null ? win.VisibleRange : null;
                        if (visible != null)
                        {
                            captureRange = FirstArea(visible);
                            Logging.Logger.Gateway("Excel Vision capture: huge selection replaced with bounded current visible range.");
                        }
                    }
                }
                catch { }

                // Keep the final clipboard image bounded even on extreme zoom / unusually large windows.
                int totalRows, totalCols, shownRows, shownCols, areaCount;
                captureRange = CreateBoundedReadRange(
                    captureRange, CaptureCellCap, 80,
                    out totalRows, out totalCols, out shownRows, out shownCols, out areaCount);

                return TempImageCapture.FromExporter(path =>
                {
                    captureRange.CopyPicture(Excel.XlPictureAppearance.xlScreen, Excel.XlCopyPictureFormat.xlPicture);
                    var wb = _app.ActiveWorkbook;
                    Excel.Chart tempChart = (Excel.Chart)wb.Charts.Add();
                    try
                    {
                        tempChart.Paste();
                        tempChart.Export(path, "PNG", true);
                    }
                    finally
                    {
                        tempChart.Delete();
                    }
                });
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "ExcelHostAdapter.CaptureCurrentViewAsImage failed", ex);
                return null;
            }
        }

        public WritePreview PrepareWrite(string toolName, string argumentsJson)
        {
            switch (toolName)
            {
                case ToolNames.WriteToCell:
                case ToolNames.InsertFormula:
                case ToolNames.HighlightRange:
                    return ExcelWrite.Prepare(this, toolName, argumentsJson);
                default:
                    throw new OmnixException(ErrorCode.CORE_ERROR,
                        "Tool '" + toolName + "' is not supported by Excel.",
                        "ExcelHostAdapter.PrepareWrite", "Use a supported tool.");
            }
        }

        public void ApplyWrite(string toolName, string argumentsJson)
        {
            ExcelWrite.Apply(this, toolName, argumentsJson);
        }

        // ------------------------------------------------------------------ helpers

        internal Excel.Application App { get { return _app; } }
        internal int MaxCells { get { return _maxCells(); } }

        internal string ActiveSheetName()
        {
            var ws = _app.ActiveSheet as Excel.Worksheet;
            return ws != null ? ws.Name : "?";
        }

        private string BuildValuesPreview(Excel.Range sel)
        {
            int cap = Math.Max(1, _maxCells());
            var table = BuildValuesTable(sel, cap);
            return TextUtil.Truncate(table, _maxChars());
        }

        private string BuildFormulasPreview(Excel.Range sel)
        {
            var sb = new StringBuilder();
            int cap = Math.Max(1, Math.Min(FormulaCellCap, _maxCells()));
            try
            {
                int totalRows, totalCols, shownRows, shownCols, areaCount;
                Excel.Range part = CreateBoundedReadRange(
                    sel, cap, DisplayMaxColumns,
                    out totalRows, out totalCols, out shownRows, out shownCols, out areaCount);

                AppendFormulas(part, shownRows, shownCols, sb);
                if (areaCount > 1)
                    sb.AppendLine("…[multi-area selection: showing first area only]");
                if (shownRows < totalRows || shownCols < totalCols)
                    sb.AppendLine("…[formulas truncated: shown " + shownRows + "×" + shownCols +
                                  " of " + totalRows + "×" + totalCols + "]");
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "BuildFormulasPreview failed", ex);
            }
            return TextUtil.Truncate(sb.ToString(), 1200);
        }

        private static void AppendFormulas(Excel.Range range, int rows, int cols, StringBuilder sb)
        {
            object raw = range.Formula;
            if (rows == 1 && cols == 1)
            {
                sb.AppendLine(raw == null ? "" : Convert.ToString(raw));
                return;
            }

            var formulas = raw as object[,];
            if (formulas == null) return;
            for (int r = 1; r <= rows; r++)
            {
                var line = new List<string>();
                for (int c = 1; c <= cols; c++)
                {
                    object v = formulas[r, c];
                    line.Add(v == null ? "" : Convert.ToString(v));
                }
                sb.AppendLine(string.Join(" | ", line));
            }
        }

        internal string BuildValuesTable(Excel.Range range, int cellCap)
        {
            var sb = new StringBuilder();
            try
            {
                int totalRows, totalCols, shownRows, shownCols, areaCount;
                Excel.Range part = CreateBoundedReadRange(
                    range, Math.Max(1, cellCap), DisplayMaxColumns,
                    out totalRows, out totalCols, out shownRows, out shownCols, out areaCount);

                object raw = part.Value2;
                if (shownRows == 1 && shownCols == 1)
                {
                    sb.AppendLine(part.Address[false, false] + " = " + SafeText(raw));
                }
                else
                {
                    var vals = raw as object[,];
                    if (vals != null)
                    {
                        for (int r = 1; r <= shownRows; r++)
                        {
                            var line = new List<string>();
                            for (int c = 1; c <= shownCols; c++)
                                line.Add(SafeText(vals[r, c]));
                            sb.AppendLine(string.Join(" | ", line));
                        }
                    }
                }

                if (areaCount > 1)
                    sb.AppendLine("…[multi-area selection: showing first area only]");
                if (shownRows < totalRows || shownCols < totalCols)
                    sb.AppendLine("…[" + totalRows + " rows × " + totalCols +
                                  " cols in first area — shown " + shownRows + "×" + shownCols + "]");
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "BuildValuesTable failed", ex);
            }
            return sb.ToString();
        }

        /// <summary>
        /// Returns a rectangular first-area range whose cell count is within cellCap. Crucially,
        /// callers must use the returned range for Value2/Formula access rather than reading the
        /// original range and trimming the resulting COM array afterward.
        /// </summary>
        private static Excel.Range CreateBoundedReadRange(
            Excel.Range range,
            int cellCap,
            int maxColumns,
            out int totalRows,
            out int totalCols,
            out int shownRows,
            out int shownCols,
            out int areaCount)
        {
            if (range == null) throw new ArgumentNullException("range");

            Excel.Range source = FirstArea(range);
            areaCount = 1;
            try { areaCount = Math.Max(1, range.Areas.Count); } catch { }

            totalRows = Math.Max(1, source.Rows.Count);
            totalCols = Math.Max(1, source.Columns.Count);
            int safeCap = Math.Max(1, cellCap);
            int safeMaxColumns = Math.Max(1, maxColumns);

            shownCols = Math.Min(totalCols, Math.Min(safeMaxColumns, safeCap));
            shownRows = Math.Min(totalRows, Math.Max(1, safeCap / Math.Max(1, shownCols)));

            if (shownRows == totalRows && shownCols == totalCols)
                return source;
            return source.Resize[shownRows, shownCols];
        }

        private static Excel.Range FirstArea(Excel.Range range)
        {
            if (range == null) return null;
            try
            {
                if (range.Areas != null && range.Areas.Count > 1)
                    return range.Areas[1];
            }
            catch { }
            return range;
        }

        private static string SafeText(object v)
        {
            if (v == null) return "";
            return Convert.ToString(v) ?? "";
        }

        private string BuildNamedRanges(Excel.Workbook wb)
        {
            var sb = new StringBuilder();
            try
            {
                int i = 0;
                foreach (Excel.Name n in wb.Names)
                {
                    if (i++ >= 50) { sb.AppendLine("…"); break; }
                    sb.AppendLine(n.Name + " = " + n.RefersTo);
                }
            }
            catch { }
            return sb.Length == 0 ? "(none)" : sb.ToString();
        }

        private string BuildChartsInfo(Excel.Worksheet ws)
        {
            if (ws == null) return "(none)";
            var names = new List<string>();
            try
            {
                foreach (Excel.ChartObject co in (Excel.ChartObjects)ws.ChartObjects())
                    names.Add(co.Name);
            }
            catch { }
            return names.Count == 0 ? "(no charts)" : string.Join(", ", names);
        }
    }

    /// <summary>Excel write-tool plumbing (write_to_cell / insert_formula / highlight_range).</summary>
    internal static class ExcelWrite
    {
        public static WritePreview Prepare(ExcelHostAdapter adapter, string toolName, string argumentsJson)
        {
            var args = ToolArguments.Parse(argumentsJson);
            string address = args.Get("address", args.Get("range", ""));
            if (string.IsNullOrEmpty(address))
                throw new OmnixException(ErrorCode.CORE_ERROR, "Missing target address.",
                    toolName + " requires 'address'.", "Provide an A1-style address like A1 or A1:C5.");

            var app = adapter.App;
            var ws = app.ActiveSheet as Excel.Worksheet;
            if (ws == null)
                throw new OmnixException(ErrorCode.CORE_ERROR, "No worksheet is active.", toolName, "Open a worksheet.");

            Excel.Range target = ws.Range[address];
            string before = "";
            if (toolName == ToolNames.HighlightRange)
            {
                int old = Convert.ToInt32(target.Interior.ColorIndex);
                before = "Current Interior.ColorIndex: " + old;
            }
            else
            {
                object current = toolName == ToolNames.InsertFormula ? target.Formula : target.Value2;
                before = target.Address[false, false] + " currently = " + (current == null ? "(empty)" : Convert.ToString(current));
            }

            string after;
            if (toolName == ToolNames.WriteToCell)
                after = target.Address[false, false] + " will contain: " + args.Get("value", "");
            else if (toolName == ToolNames.InsertFormula)
                after = target.Address[false, false] + " formula will be: " + args.Get("formula", args.Get("value", ""));
            else
                after = target.Address[false, false] + " will be highlighted yellow.";

            return new WritePreview
            {
                ToolName = toolName,
                Title = "Excel — " + toolName,
                Before = before,
                After = after,
                ArgumentsJson = argumentsJson
            };
        }

        public static void ApplyWrite(ExcelHostAdapter adapter, string toolName, string argumentsJson)
        {
            var args = ToolArguments.Parse(argumentsJson);
            string address = args.Get("address", args.Get("range", ""));
            var ws = adapter.App.ActiveSheet as Excel.Worksheet;
            if (ws == null)
                throw new OmnixException(ErrorCode.CORE_ERROR, "No worksheet is active.", toolName, "Open a worksheet.");
            Excel.Range target = ws.Range[address];

            switch (toolName)
            {
                case ToolNames.WriteToCell:
                    target.Value2 = args.Get("value", "");
                    break;
                case ToolNames.InsertFormula:
                    target.Formula = args.Get("formula", args.Get("value", ""));
                    break;
                case ToolNames.HighlightRange:
                    // BGR int for Office: yellow (255,235,59) -> 0x3BEBFF
                    target.Interior.Color = 0x3BEBFF;
                    break;
                default:
                    throw new OmnixException(ErrorCode.CORE_ERROR, "Unknown Excel write tool: " + toolName, "", "");
            }
            Logging.Logger.Install("Excel write tool applied: " + toolName + " -> " + address);
        }
    }
}
