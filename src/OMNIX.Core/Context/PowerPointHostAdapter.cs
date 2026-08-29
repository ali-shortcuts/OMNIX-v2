using System;
using System.Text;
using Ppt = Microsoft.Office.Interop.PowerPoint;
using Office = Microsoft.Office.Core;
using OMNIX.Core.Errors;
using OMNIX.Core.Tools;
using OMNIX.Core.Util;

namespace OMNIX.Core.Context
{
    /// <summary>
    /// PowerPoint adapter (spec Section 3, Layer 3): Presentation, current slide as image for
    /// Vision, speaker notes, shapes/text. Write tools: insert_slide, add_speaker_notes.
    /// </summary>
    public sealed class PowerPointHostAdapter : IHostAdapter
    {
        private readonly Ppt.Application _app;
        private readonly Func<int, int> _maxChars;

        public PowerPointHostAdapter(Ppt.Application app, Func<int, int> maxChars)
        {
            _app = app;
            _maxChars = maxChars;
        }

        public HostType Host { get { return HostType.PowerPoint; } }
        public string HostDisplayName { get { return "PowerPoint"; } }

        public OfficeContext ReadContext()
        {
            var ctx = new OfficeContext { Host = HostType.PowerPoint };
            try
            {
                var pres = _app.ActivePresentation;
                if (pres == null) return ctx;
                ctx.DocumentName = pres.Name;
                ctx.DocumentPath = pres.FullName;
                ctx.SlideCount = pres.Slides.Count;

                var win = _app.ActiveWindow;
                if (win != null && win.ViewType == Ppt.PpViewType.ppViewSlide)
                {
                    var slide = win.View.Slide;
                    ctx.CurrentSlideIndex = slide.SlideIndex;
                    ctx.SlideTitle = GetSlideTitle(slide);
                    ctx.NotesPreview = GetNotes(slide);
                    ctx.SelectionAddress = "Slide " + slide.SlideIndex;
                }
                else
                {
                    ctx.CurrentSlideIndex = 0;
                }
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "PowerPointHostAdapter.ReadContext failed", ex);
            }
            return ctx;
        }

        public string ReadSelection()
        {
            try
            {
                var pres = _app.ActivePresentation;
                var win = _app.ActiveWindow;
                var slide = win.View.Slide;
                var sb = new StringBuilder();
                sb.AppendLine("Slide " + slide.SlideIndex + " of " + pres.Slides.Count);
                sb.AppendLine("Title: " + GetSlideTitle(slide));
                sb.AppendLine("Shapes text:");
                AppendShapesText(slide, sb);
                sb.AppendLine("Speaker notes: " + GetNotes(slide));
                return TextUtil.Truncate(sb.ToString(), _maxChars());
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "PowerPointHostAdapter.ReadSelection failed", ex);
                return "(unable to read slide)";
            }
        }

        public string ReadDocument(int maxChars)
        {
            try
            {
                var pres = _app.ActivePresentation;
                if (pres == null) return "(no presentation open)";
                var sb = new StringBuilder();
                sb.AppendLine("Presentation: " + pres.Name + " (" + pres.Slides.Count + " slides)");
                for (int i = 1; i <= pres.Slides.Count && sb.Length < maxChars; i++)
                {
                    var slide = pres.Slides[i];
                    sb.AppendLine();
                    sb.AppendLine("--- Slide " + i + " ---");
                    sb.AppendLine("Title: " + GetSlideTitle(slide));
                    AppendShapesText(slide, sb);
                }
                return TextUtil.Truncate(sb.ToString(), Math.Min(maxChars, _maxChars()));
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "PowerPointHostAdapter.ReadDocument failed", ex);
                return "(unable to read presentation)";
            }
        }

        public byte[] CaptureChartAsImage(string chartName) { return null; }

        public byte[] CaptureSlideAsImage(int slideIndexOneBased)
        {
            try
            {
                var pres = _app.ActivePresentation;
                if (pres == null) return null;
                Ppt.Slide slide = slideIndexOneBased >= 1 ? pres.Slides[slideIndexOneBased] : null;
                if (slide == null)
                {
                    var win = _app.ActiveWindow;
                    slide = win != null ? win.View.Slide : null;
                }
                if (slide == null) return null;
                return TempImageCapture.FromExporter(path => slide.Export(path, "PNG", 1280, 720));
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("startup-debug", "PowerPointHostAdapter.CaptureSlideAsImage failed", ex);
                return null;
            }
        }

        public byte[] CaptureCurrentViewAsImage()
        {
            return CaptureSlideAsImage(0);
        }

        public WritePreview PrepareWrite(string toolName, string argumentsJson)
        {
            var args = ToolArguments.Parse(argumentsJson);
            switch (toolName)
            {
                case ToolNames.InsertSlide:
                    return new WritePreview
                    {
                        ToolName = toolName,
                        Title = "PowerPoint — insert slide",
                        Before = "Presentation currently has " + ActiveSlideCount() + " slides.",
                        After = "A new slide will be added at position " + args.Get("index", "") +
                                " with title: " + args.Get("title", "(empty)") +
                                (string.IsNullOrEmpty(args.Get("body", "")) ? "" : " and body text."),
                        ArgumentsJson = argumentsJson
                    };
                case ToolNames.AddSpeakerNotes:
                    int idx = ParseInt(args.Get("slide", "0"), 0);
                    return new WritePreview
                    {
                        ToolName = toolName,
                        Title = "PowerPoint — add speaker notes",
                        Before = "Current notes of slide " + (idx > 0 ? idx.ToString() : "(current)") + ": " +
                                 GetNotes(GetSlide(idx)),
                        After = "New notes: " + TextUtil.Truncate(args.Get("notes", ""), 500),
                        ArgumentsJson = argumentsJson
                    };
                default:
                    throw new OmnixException(ErrorCode.CORE_ERROR,
                        "Tool '" + toolName + "' is not supported by PowerPoint.",
                        "PowerPointHostAdapter.PrepareWrite", "Use insert_slide or add_speaker_notes.");
            }
        }

        public void ApplyWrite(string toolName, string argumentsJson)
        {
            var args = ToolArguments.Parse(argumentsJson);
            var pres = _app.ActivePresentation;
            if (pres == null)
                throw new OmnixException(ErrorCode.CORE_ERROR, "No presentation open.", toolName, "");

            switch (toolName)
            {
                case ToolNames.InsertSlide:
                {
                    int count = pres.Slides.Count;
                    int index = ParseInt(args.Get("index", (count + 1).ToString()), count + 1);
                    if (index < 1) index = 1;
                    if (index > count + 1) index = count + 1;
                    var slide = pres.Slides.Add(index, Ppt.PpSlideLayout.ppLayoutText);
                    string title = args.Get("title", "");
                    string body = args.Get("body", "");
                    if (!string.IsNullOrEmpty(title) && slide.Shapes.Placeholders.Count >= 1)
                        slide.Shapes.Placeholders[1].TextFrame.TextRange.Text = title;
                    if (!string.IsNullOrEmpty(body) && slide.Shapes.Placeholders.Count >= 2)
                        slide.Shapes.Placeholders[2].TextFrame.TextRange.Text = body;
                    break;
                }
                case ToolNames.AddSpeakerNotes:
                {
                    int idx = ParseInt(args.Get("slide", "0"), 0);
                    Ppt.Slide slide = GetSlide(idx);
                    if (slide == null)
                        throw new OmnixException(ErrorCode.CORE_ERROR, "Cannot resolve target slide.", toolName, "");
                    slide.NotesPage.Shapes.Placeholders[2].TextFrame.TextRange.Text = args.Get("notes", "");
                    break;
                }
                default:
                    throw new OmnixException(ErrorCode.CORE_ERROR, "Unknown PowerPoint write tool: " + toolName, "", "");
            }
            Logging.Logger.Install("PowerPoint write tool applied: " + toolName);
        }

        // ------------------------------------------------------------------ helpers

        private Ppt.Slide GetSlide(int indexOneBased)
        {
            var pres = _app.ActivePresentation;
            if (pres == null) return null;
            if (indexOneBased >= 1 && indexOneBased <= pres.Slides.Count) return pres.Slides[indexOneBased];
            var win = _app.ActiveWindow;
            return win != null ? win.View.Slide : null;
        }

        private int ActiveSlideCount()
        {
            var pres = _app.ActivePresentation;
            return pres != null ? pres.Slides.Count : 0;
        }

        private static int ParseInt(string s, int fallback)
        {
            int v;
            return int.TryParse(s, out v) ? v : fallback;
        }

        private static string GetSlideTitle(Ppt.Slide slide)
        {
            try
            {
                if (slide.Shapes.Title != null)
                    return slide.Shapes.Title.TextFrame.TextRange.Text;
            }
            catch { }
            return "(no title)";
        }

        private static string GetNotes(Ppt.Slide slide)
        {
            try
            {
                return slide.NotesPage.Shapes.Placeholders[2].TextFrame.TextRange.Text ?? "";
            }
            catch { return ""; }
        }

        private static void AppendShapesText(Ppt.Slide slide, StringBuilder sb)
        {
            foreach (Ppt.Shape shape in slide.Shapes)
            {
                try
                {
                    if (shape.HasTextFrame == Office.MsoTriState.msoTrue && shape.TextFrame.HasText == Office.MsoTriState.msoTrue)
                        sb.AppendLine("• [" + shape.Name + "] " + shape.TextFrame.TextRange.Text);
                }
                catch { }
            }
        }
    }
}
