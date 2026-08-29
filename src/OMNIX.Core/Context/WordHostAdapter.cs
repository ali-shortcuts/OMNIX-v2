using System;
using System.Text;
using Word = Microsoft.Office.Interop.Word;
using OMNIX.Core.Errors;
using OMNIX.Core.Tools;
using OMNIX.Core.Util;

namespace OMNIX.Core.Context
{
    /// <summary>
    /// Word adapter (spec Section 3, Layer 3): Document, Selection, Paragraphs, Headings, Tables,
    /// Track Changes/Comments. Write tool: rewrite_selected_text with native UndoRecord.
    /// </summary>
    public sealed class WordHostAdapter : IHostAdapter
    {
        private readonly Word.Application _app;
        private readonly Func<int> _maxChars;

        public WordHostAdapter(Word.Application app, Func<int> maxChars)
        {
            _app = app;
            _maxChars = maxChars;
        }

        public HostType Host { get { return HostType.Word; } }
        public string HostDisplayName { get { return "Word"; } }

        public OfficeContext ReadContext()
        {
            var ctx = new OfficeContext { Host = HostType.Word };
            try
            {
                var doc = _app.ActiveDocument;
                if (doc == null) return ctx;
                ctx.DocumentName = doc.Name;
                ctx.DocumentPath = doc.FullName;
                ctx.HasTrackChanges = doc.TrackRevisions;
                ctx.CommentCount = doc.Comments.Count;

                var sel = _app.Selection;
                if (sel != null && sel.Range != null)
                {
                    ctx.SelectionAddress = "chars " + sel.Start + "–" + sel.End;
                    ctx.SelectionText = TextUtil.Truncate(sel.Text ?? "", 200);
                }
                ctx.HeadingsPreview = BuildHeadings(doc);
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "WordHostAdapter.ReadContext failed", ex);
            }
            return ctx;
        }

        public string ReadSelection()
        {
            try
            {
                var sel = _app.Selection;
                if (sel == null) return "(no selection)";
                return "Selection (" + sel.Start + "–" + sel.End + "):\n" + (sel.Text ?? "(empty)");
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "WordHostAdapter.ReadSelection failed", ex);
                return "(unable to read selection)";
            }
        }

        public string ReadDocument(int maxChars)
        {
            try
            {
                var doc = _app.ActiveDocument;
                if (doc == null) return "(no document open)";
                var sb = new StringBuilder();
                sb.AppendLine("Document: " + doc.Name + " (" + doc.Paragraphs.Count + " paragraphs, "
                              + doc.Tables.Count + " tables)");
                if (doc.TrackRevisions) sb.AppendLine("[Track Changes is ON]");
                sb.AppendLine();
                sb.Append(doc.Content.Text);
                return TextUtil.Truncate(sb.ToString(), Math.Min(maxChars, _maxChars()));
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "WordHostAdapter.ReadDocument failed", ex);
                return "(unable to read document)";
            }
        }

        public byte[] CaptureChartAsImage(string chartName) { return null; }

        public byte[] CaptureSlideAsImage(int slideIndexOneBased) { return null; }

        public byte[] CaptureCurrentViewAsImage()
        {
            try
            {
                var sel = _app.Selection;
                if (sel == null || sel.Range == null) return null;
                return TempImageCapture.FromExporter(path =>
                {
                    sel.Range.CopyAsPicture();
                    // The clipboard now holds an enhanced metafile; materialize via System.Windows.Clipboard
                    // into a PNG-like image is unreliable across hosts — instead export through a temp chart
                    // is not available in Word, so we fall back to System.Windows imaging below.
                    System.Windows.IDataObject data = System.Windows.Clipboard.GetDataObject();
                    if (data != null && data.GetDataPresent(System.Windows.DataFormats.Bitmap))
                    {
                        var bmp = data.GetData(System.Windows.DataFormats.Bitmap) as System.Windows.Media.Imaging.BitmapSource;
                        if (bmp != null)
                        {
                            var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                            enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
                            using (var fs = System.IO.File.Create(path))
                                enc.Save(fs);
                            return;
                        }
                    }
                    throw new InvalidOperationException("No bitmap on clipboard after CopyAsPicture.");
                });
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "WordHostAdapter.CaptureCurrentViewAsImage failed", ex);
                return null;
            }
        }

        public WritePreview PrepareWrite(string toolName, string argumentsJson)
        {
            if (toolName != ToolNames.RewriteSelectedText)
                throw new OmnixException(ErrorCode.CORE_ERROR,
                    "Tool '" + toolName + "' is not supported by Word.",
                    "WordHostAdapter.PrepareWrite", "Use rewrite_selected_text.");

            var args = ToolArguments.Parse(argumentsJson);
            var sel = _app.Selection;
            string before = sel != null ? (sel.Text ?? "") : "";
            string after = args.Get("text", args.Get("value", ""));

            return new WritePreview
            {
                ToolName = toolName,
                Title = "Word — rewrite selected text",
                Before = TextUtil.Truncate(before, 4000),
                After = TextUtil.Truncate(after, 4000),
                ArgumentsJson = argumentsJson
            };
        }

        public void ApplyWrite(string toolName, string argumentsJson)
        {
            if (toolName != ToolNames.RewriteSelectedText)
                throw new OmnixException(ErrorCode.CORE_ERROR, "Unknown Word write tool: " + toolName, "", "");

            var args = ToolArguments.Parse(argumentsJson);
            string newText = args.Get("text", args.Get("value", ""));
            var sel = _app.Selection;
            if (sel == null)
                throw new OmnixException(ErrorCode.CORE_ERROR, "No active selection in Word.", toolName, "");

            Word.UndoRecord undo = null;
            try
            {
                undo = _app.UndoRecord;
                if (undo != null) undo.StartCustomRecord("OMNIX rewrite_selected_text");
                sel.Text = newText;
            }
            finally
            {
                if (undo != null)
                {
                    try { undo.EndCustomRecord(); } catch { }
                }
            }
            Logging.Logger.Install("Word write tool applied: rewrite_selected_text (" + newText.Length + " chars)");
        }

        private string BuildHeadings(Word.Document doc)
        {
            var sb = new StringBuilder();
            try
            {
                int count = 0;
                foreach (Word.Paragraph p in doc.Paragraphs)
                {
                    if (count++ >= 200) { sb.AppendLine("…"); break; }
                    string styleName = null;
                    try { styleName = p.Range.ParagraphStyle != null ? ((Word.Style)p.Range.ParagraphStyle).NameLocal : null; }
                    catch { }
                    if (!string.IsNullOrEmpty(styleName) && styleName.StartsWith("Heading", StringComparison.OrdinalIgnoreCase) ||
                        (styleName != null && styleName.StartsWith("عنوان", StringComparison.Ordinal)))
                    {
                        string text = (p.Range.Text ?? "").Trim('\r', '\a');
                        sb.AppendLine(styleName + ": " + text);
                    }
                }
            }
            catch { }
            return sb.Length == 0 ? "(no headings)" : sb.ToString();
        }
    }
}
