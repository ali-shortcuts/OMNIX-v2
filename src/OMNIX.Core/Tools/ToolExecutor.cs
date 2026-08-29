using System;
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
    /// adapter so native Office undo (Ctrl+Z) keeps working (spec Phase 15).
    /// </summary>
    public sealed class ToolExecutor
    {
        /// <summary>UI wires this: returns true when the user confirmed the change.</summary>
        public Func<WritePreview, Task<bool>> WriteConfirmation { get; set; }

        public async Task<ToolResult> ExecuteAsync(ToolCall call, IHostAdapter adapter)
        {
            if (call == null || !ToolNames.IsWhitelisted(call.Name))
                return ToolResult.Fail("Tool not whitelisted: " + (call != null ? call.Name : "(null)"));

            try
            {
                if (ToolNames.IsWriteTool(call.Name))
                    return await ExecuteWriteAsync(call, adapter).ConfigureAwait(true);
                return ExecuteRead(call, adapter);
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

        private ToolResult ExecuteRead(ToolCall call, IHostAdapter adapter)
        {
            switch (call.Name)
            {
                case ToolNames.ReadSelection:
                {
                    string text = adapter.ReadSelection();
                    return ToolResult.Ok(UntrustedData.Wrap("READ_SELECTION RESULT", text));
                }
                case ToolNames.ReadDocument:
                case ToolNames.ReadPresentation:
                {
                    string text = adapter.ReadDocument(6000);
                    return ToolResult.Ok(UntrustedData.Wrap("READ_DOCUMENT RESULT", text));
                }
                case ToolNames.CaptureChartAsImage:
                {
                    var args = ToolArguments.Parse(call.ArgumentsJson);
                    byte[] png = adapter.CaptureChartAsImage(args.Get("chart", ""));
                    if (png == null) return ToolResult.Fail("No chart found to capture.");
                    // The image cannot be fed back through this text channel; it is offered to the user in chat.
                    return new ToolResult
                    {
                        Success = true,
                        ContentForModel = "Chart image captured (" + png.Length + " bytes). Tell the user you captured it and to use the 'Attach image' button for visual analysis.",
                        UiNote = "Chart captured",
                        CapturedPng = png
                    };
                }
                case ToolNames.CaptureSlideAsImage:
                {
                    var args = ToolArguments.Parse(call.ArgumentsJson);
                    int slide = 0;
                    int.TryParse(args.Get("slide", "0"), out slide);
                    byte[] png = adapter.CaptureSlideAsImage(slide);
                    if (png == null) return ToolResult.Fail("No slide available to capture.");
                    return new ToolResult
                    {
                        Success = true,
                        ContentForModel = "Slide image captured (" + png.Length + " bytes). Tell the user you captured it and to use the 'Attach image' button for visual analysis.",
                        UiNote = "Slide captured",
                        CapturedPng = png
                    };
                }
                default:
                    return ToolResult.Fail("Unhandled read tool: " + call.Name);
            }
        }

        private async Task<ToolResult> ExecuteWriteAsync(ToolCall call, IHostAdapter adapter)
        {
            WritePreview preview;
            try
            {
                preview = adapter.PrepareWrite(call.Name, call.ArgumentsJson);
            }
            catch (OmnixException ex)
            {
                return ToolResult.Fail("PREVIEW ERROR [" + ex.Code + "]: " + ex.Message);
            }

            if (WriteConfirmation == null)
                return ToolResult.Fail("Write confirmation dialog is unavailable; change was NOT applied.");

            bool confirmed;
            try
            {
                confirmed = await WriteConfirmation(preview).ConfigureAwait(true);
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Write confirmation handler failed", ex);
                confirmed = false;
            }

            if (!confirmed)
            {
                return ToolResult.Fail("The user reviewed the preview and CANCELLED the change. Do not retry the same write without asking why.");
            }

            adapter.ApplyWrite(call.Name, call.ArgumentsJson);
            string hint = Localization.Strings.T("S.Tools.Applied");
            return ToolResult.Ok("CHANGE APPLIED. " + hint, hint);
        }
    }
}
