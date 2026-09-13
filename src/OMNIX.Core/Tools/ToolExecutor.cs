using System;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Context;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;
using OMNIX.Core.Security;
using OMNIX.Core.Util;

namespace OMNIX.Core.Tools
{
    /// <summary>
    /// Layer 7 — executes ONLY whitelisted tools. Read tools run directly; write tools first
    /// produce a preview, require explicit user confirmation, then apply through the host
    /// adapter so native Office undo (Ctrl+Z) keeps working.
    ///
    /// Tool execution is cancellation-aware. This is a security boundary, not only a UX feature:
    /// when an Office document/window changes while an AI request is in flight, the request token
    /// is cancelled and no late provider tool call may read from or mutate the newly-active document.
    /// </summary>
    public sealed class ToolExecutor
    {
        /// <summary>UI wires this: returns true when the user confirmed the change.</summary>
        public Func<WritePreview, Task<bool>> WriteConfirmation { get; set; }

        /// <summary>
        /// Compatibility overload used by existing deterministic tests/callers that do not own a
        /// request cancellation token. Interactive gateway execution uses the token-aware overload.
        /// </summary>
        public Task<ToolResult> ExecuteAsync(ToolCall call, IHostAdapter adapter)
        {
            return ExecuteAsync(call, adapter, CancellationToken.None);
        }

        public async Task<ToolResult> ExecuteAsync(ToolCall call, IHostAdapter adapter, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();

            if (call == null || !ToolNames.IsWhitelisted(call.Name))
                return ToolResult.Fail("Tool not whitelisted: " + (call != null ? call.Name : "(null)"));

            try
            {
                ct.ThrowIfCancellationRequested();
                if (ToolNames.IsWriteTool(call.Name))
                    return await ExecuteWriteAsync(call, adapter, ct).ConfigureAwait(true);
                return ExecuteRead(call, adapter, ct);
            }
            catch (OperationCanceledException)
            {
                // Cancellation is a request-scope boundary. Never convert it into a model-visible
                // TOOL ERROR, because the caller must abort the entire tool loop instead.
                throw;
            }
            catch (OmnixException ex)
            {
                return ToolResult.Fail("TOOL ERROR [" + ex.Code + "]: " + ex.Message);
            }
            catch (Exception ex)
            {
                Logger.Error("gateway", "Tool execution failed: " + call.Name, ex);
                return ToolResult.Fail("TOOL ERROR: " + ex.Message);
            }
        }

        private ToolResult ExecuteRead(ToolCall call, IHostAdapter adapter, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();

            switch (call.Name)
            {
                case ToolNames.ReadSelection:
                {
                    ct.ThrowIfCancellationRequested();
                    string text = adapter.ReadSelection();
                    return ToolResult.Ok(UntrustedData.Wrap("READ_SELECTION RESULT", text));
                }
                case ToolNames.ReadDocument:
                case ToolNames.ReadPresentation:
                {
                    ct.ThrowIfCancellationRequested();
                    string text = adapter.ReadDocument(6000);
                    return ToolResult.Ok(UntrustedData.Wrap("READ_DOCUMENT RESULT", text));
                }
                case ToolNames.CaptureChartAsImage:
                {
                    var args = ToolArguments.Parse(call.ArgumentsJson);
                    ct.ThrowIfCancellationRequested();
                    byte[] png = adapter.CaptureChartAsImage(args.Get("chart", ""));
                    if (png == null || png.Length == 0) return ToolResult.Fail("No chart found to capture.");
                    return VisionCaptureResult("Excel chart", call.Name, png);
                }
                case ToolNames.CaptureSlideAsImage:
                {
                    var args = ToolArguments.Parse(call.ArgumentsJson);
                    int slide = 0;
                    int.TryParse(args.Get("slide", "0"), out slide);
                    ct.ThrowIfCancellationRequested();
                    byte[] png = adapter.CaptureSlideAsImage(slide);
                    if (png == null || png.Length == 0) return ToolResult.Fail("No slide available to capture.");
                    return VisionCaptureResult("PowerPoint slide", call.Name, png);
                }
                case ToolNames.CaptureCurrentViewAsImage:
                {
                    ct.ThrowIfCancellationRequested();
                    byte[] png = adapter.CaptureCurrentViewAsImage();
                    if (png == null || png.Length == 0)
                        return ToolResult.Fail("The current Office view could not be captured as an image.");
                    return VisionCaptureResult(adapter.HostDisplayName + " current view/selection", call.Name, png);
                }
                default:
                    return ToolResult.Fail("Unhandled read tool: " + call.Name);
            }
        }

        private static ToolResult VisionCaptureResult(string source, string toolName, byte[] png)
        {
            return new ToolResult
            {
                Success = true,
                ContentForModel = "OMNIX captured the " + source + ". The PNG attached to this tool-result message is the visual source; inspect it directly and combine it with the structured Office context. Do not claim to see anything outside this captured view.",
                UiNote = source + " captured for Vision",
                CapturedPng = png
            };
        }

        private async Task<ToolResult> ExecuteWriteAsync(ToolCall call, IHostAdapter adapter, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();

            WritePreview preview;
            try
            {
                preview = adapter.PrepareWrite(call.Name, call.ArgumentsJson);
            }
            catch (OmnixException ex)
            {
                return ToolResult.Fail("PREVIEW ERROR [" + ex.Code + "]: " + ex.Message);
            }

            // The active Office document may have changed while PrepareWrite inspected it.
            ct.ThrowIfCancellationRequested();

            if (WriteConfirmation == null)
                return ToolResult.Fail("Write confirmation dialog is unavailable; change was NOT applied.");

            bool confirmed;
            try
            {
                confirmed = await WriteConfirmation(preview).ConfigureAwait(true);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Write confirmation handler failed", ex);
                confirmed = false;
            }

            // Confirmation can be modal and long-lived. Re-check cancellation immediately before
            // any mutation so a document/window switch cannot redirect an approved old preview.
            ct.ThrowIfCancellationRequested();

            if (!confirmed)
            {
                return ToolResult.Fail("The user reviewed the preview and CANCELLED the change. Do not retry the same write without asking why.");
            }

            ct.ThrowIfCancellationRequested();
            adapter.ApplyWrite(call.Name, call.ArgumentsJson);
            string hint = Localization.Strings.T("S.Tools.Applied");
            return ToolResult.Ok("CHANGE APPLIED. " + hint, hint);
        }
    }
}
