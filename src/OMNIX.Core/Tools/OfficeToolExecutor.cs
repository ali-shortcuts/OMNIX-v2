using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Context;

namespace OMNIX.Core.Tools
{
    public static class OfficeToolNames
    {
        public const string ReadContext = "read_context";
        public const string CaptureCurrentView = "capture_current_view_as_image";
        public const string WriteToCell = "write_to_cell";
        public const string InsertFormula = "insert_formula";
        public const string RewriteSelectedText = "rewrite_selected_text";
        public const string InsertSlide = "insert_slide";

        private static readonly HashSet<string> Allowed = new HashSet<string>(StringComparer.Ordinal)
        {
            ReadContext,
            CaptureCurrentView,
            WriteToCell,
            InsertFormula,
            RewriteSelectedText,
            InsertSlide
        };

        private static readonly HashSet<string> Writes = new HashSet<string>(StringComparer.Ordinal)
        {
            WriteToCell,
            InsertFormula,
            RewriteSelectedText,
            InsertSlide
        };

        public static bool IsAllowed(string name) => !string.IsNullOrWhiteSpace(name) && Allowed.Contains(name);
        public static bool IsWrite(string name) => !string.IsNullOrWhiteSpace(name) && Writes.Contains(name);
    }

    public sealed class OfficeToolCall
    {
        public string Name { get; set; }
        public OfficeMutation Mutation { get; set; }
        public ContextRequest ContextRequest { get; set; }
    }

    public sealed class OfficeToolResult
    {
        public bool Success { get; set; }
        public bool UserDenied { get; set; }
        public OfficeContext Context { get; set; }
        public byte[] Png { get; set; }
        public OfficeMutationPreview Preview { get; set; }
        public string Message { get; set; }
    }

    /// <summary>
    /// The only shared-core route for model-requested Office capabilities.
    /// No shell, process, registry, or arbitrary filesystem capability is exposed here.
    /// Every write is previewed and explicitly approved before the host adapter can mutate Office.
    /// </summary>
    public sealed class OfficeToolExecutor
    {
        public Func<OfficeMutationPreview, Task<bool>> ConfirmMutationAsync { get; set; }

        public async Task<OfficeToolResult> ExecuteAsync(
            OfficeToolCall call,
            IOfficeHostAdapter adapter,
            CancellationToken cancellationToken)
        {
            if (call == null) throw new ArgumentNullException(nameof(call));
            if (adapter == null) throw new ArgumentNullException(nameof(adapter));
            if (!OfficeToolNames.IsAllowed(call.Name))
                throw new InvalidOperationException("Office tool is not whitelisted: " + (call.Name ?? "(null)"));

            cancellationToken.ThrowIfCancellationRequested();

            if (call.Name == OfficeToolNames.ReadContext)
            {
                OfficeContext context = await adapter.CaptureContextAsync(
                    call.ContextRequest ?? new ContextRequest(), cancellationToken).ConfigureAwait(true);
                return new OfficeToolResult { Success = true, Context = context };
            }

            if (call.Name == OfficeToolNames.CaptureCurrentView)
            {
                byte[] png = await adapter.CaptureCurrentViewPngAsync(cancellationToken).ConfigureAwait(true);
                return new OfficeToolResult
                {
                    Success = png != null && png.Length > 0,
                    Png = png,
                    Message = png == null || png.Length == 0 ? "The current Office view could not be captured." : null
                };
            }

            if (!OfficeToolNames.IsWrite(call.Name))
                throw new InvalidOperationException("Unhandled Office tool: " + call.Name);
            if (call.Mutation == null)
                throw new InvalidOperationException("Write tool requires a mutation payload.");
            if (!string.Equals(call.Mutation.Tool, call.Name, StringComparison.Ordinal))
                throw new InvalidOperationException("Tool name and mutation tool must match exactly.");

            OfficeMutationPreview preview = await adapter.PreviewMutationAsync(call.Mutation, cancellationToken).ConfigureAwait(true);
            if (ConfirmMutationAsync == null)
                return new OfficeToolResult
                {
                    Success = false,
                    Preview = preview,
                    Message = "Write confirmation is unavailable; no Office change was applied."
                };

            bool approved = await ConfirmMutationAsync(preview).ConfigureAwait(true);
            if (!approved)
                return new OfficeToolResult
                {
                    Success = false,
                    UserDenied = true,
                    Preview = preview,
                    Message = "The user denied the proposed Office change."
                };

            cancellationToken.ThrowIfCancellationRequested();
            await adapter.ApplyMutationAsync(call.Mutation, cancellationToken).ConfigureAwait(true);
            return new OfficeToolResult
            {
                Success = true,
                Preview = preview,
                Message = "Office change applied after explicit approval."
            };
        }
    }
}
