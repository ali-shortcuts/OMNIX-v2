using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Context;
using XL = Microsoft.Office.Interop.Excel;

namespace OMNIX.Excel
{
    public sealed class ExcelHostAdapter : IOfficeHostAdapter
    {
        private readonly XL.Application _application;

        public ExcelHostAdapter(XL.Application application)
        {
            _application = application ?? throw new ArgumentNullException(nameof(application));
        }

        public string HostName => "Excel";

        public Task<OfficeContext> CaptureContextAsync(ContextRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            request = request ?? new ContextRequest();

            var context = new OfficeContext { Host = HostName };
            XL.Workbook workbook = _application.ActiveWorkbook;
            XL.Worksheet sheet = _application.ActiveSheet as XL.Worksheet;
            XL.Range selection = _application.Selection as XL.Range;

            if (workbook != null)
            {
                context.DocumentName = workbook.Name;
                try { context.DocumentPath = workbook.FullName; } catch { context.DocumentPath = workbook.Name; }
            }
            if (sheet != null) context.ActiveContainer = sheet.Name;

            var items = new List<OfficeContextItem>();
            if (selection != null)
            {
                string address = selection.Address[false, false, XL.XlReferenceStyle.xlA1];
                object raw = selection.Value2;
                object formulas = request.IncludeFormulas ? selection.Formula : null;
                int rows = Math.Min(selection.Rows.Count, request.MaxItems);
                int cols = Math.Min(selection.Columns.Count, Math.Max(1, request.MaxItems / Math.Max(1, rows)));
                int emitted = 0;

                for (int r = 1; r <= rows && emitted < request.MaxItems; r++)
                {
                    for (int c = 1; c <= cols && emitted < request.MaxItems; c++)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        XL.Range cell = selection.Cells[r, c] as XL.Range;
                        string text = Convert.ToString(cell?.Value2) ?? string.Empty;
                        string formula = request.IncludeFormulas ? Convert.ToString(cell?.Formula) ?? string.Empty : null;
                        if (text.Length > request.MaxCharacters) text = text.Substring(0, request.MaxCharacters);
                        items.Add(new OfficeContextItem
                        {
                            Kind = "Cell",
                            Address = cell?.Address[false, false, XL.XlReferenceStyle.xlA1],
                            Text = text,
                            Formula = formula
                        });
                        emitted++;
                    }
                }

                context.SelectionText = address + " (" + selection.Rows.Count + "x" + selection.Columns.Count + ")";
            }

            context.Items = items;
            return Task.FromResult(context);
        }

        public Task<byte[]> CaptureCurrentViewPngAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<byte[]>(null);
        }

        public Task<OfficeMutationPreview> PreviewMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateMutation(mutation);
            XL.Range target = _application.Range[mutation.Target];
            string before = Convert.ToString(target.Value2) ?? string.Empty;
            string after = mutation.Tool == "insert_formula" ? mutation.Formula : mutation.Value;
            return Task.FromResult(new OfficeMutationPreview
            {
                Host = HostName,
                Tool = mutation.Tool,
                Target = mutation.Target,
                Before = before,
                After = after,
                IsDestructive = !string.IsNullOrEmpty(before)
            });
        }

        public Task ApplyMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateMutation(mutation);
            XL.Range target = _application.Range[mutation.Target];
            if (target.Cells.CountLarge != 1) throw new InvalidOperationException("Excel write tools may target exactly one cell.");

            if (mutation.Tool == "insert_formula")
            {
                if (string.IsNullOrWhiteSpace(mutation.Formula) || !mutation.Formula.StartsWith("=", StringComparison.Ordinal))
                    throw new InvalidOperationException("Formula must start with '='.");
                target.Formula = mutation.Formula;
            }
            else if (mutation.Tool == "write_to_cell")
            {
                target.Value2 = mutation.Value ?? string.Empty;
            }
            else
            {
                throw new InvalidOperationException("Unsupported Excel mutation tool: " + mutation.Tool);
            }

            return Task.CompletedTask;
        }

        private static void ValidateMutation(OfficeMutation mutation)
        {
            if (mutation == null) throw new ArgumentNullException(nameof(mutation));
            if (string.IsNullOrWhiteSpace(mutation.Target)) throw new InvalidOperationException("Excel mutation target is required.");
            if (mutation.Target.IndexOf(',', StringComparison.Ordinal) >= 0) throw new InvalidOperationException("Multi-area Excel targets are not allowed.");
            if (mutation.Tool != "write_to_cell" && mutation.Tool != "insert_formula")
                throw new InvalidOperationException("Excel mutation tool is not whitelisted.");
            if ((mutation.Value?.Length ?? 0) > 32767) throw new InvalidOperationException("Excel cell value is too large.");
            if ((mutation.Formula?.Length ?? 0) > 8192) throw new InvalidOperationException("Excel formula is too large.");
        }
    }
}
