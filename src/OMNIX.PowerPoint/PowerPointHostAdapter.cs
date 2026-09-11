using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Office.Core;
using OMNIX.Core.Context;
using Ppt = Microsoft.Office.Interop.PowerPoint;

namespace OMNIX.PowerPoint
{
    public sealed class PowerPointHostAdapter : IOfficeHostAdapter
    {
        private readonly Ppt.Application _application;

        public PowerPointHostAdapter(Ppt.Application application)
        {
            _application = application ?? throw new ArgumentNullException(nameof(application));
        }

        public string HostName => "PowerPoint";

        public Task<OfficeContext> CaptureContextAsync(ContextRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            request = request ?? new ContextRequest();

            var context = new OfficeContext { Host = HostName };
            Ppt.Presentation presentation = _application.ActivePresentation;
            if (presentation != null)
            {
                context.DocumentName = presentation.Name;
                try { context.DocumentPath = presentation.FullName; } catch { context.DocumentPath = presentation.Name; }
            }

            var items = new List<OfficeContextItem>();
            Ppt.Slide slide = null;
            try { slide = _application.ActiveWindow?.View?.Slide as Ppt.Slide; } catch { }
            if (slide != null)
            {
                context.ActiveContainer = "Slide " + slide.SlideIndex;
                int emitted = 0;
                foreach (Ppt.Shape shape in slide.Shapes)
                {
                    if (emitted >= request.MaxItems) break;
                    cancellationToken.ThrowIfCancellationRequested();
                    string text = string.Empty;
                    try
                    {
                        if (shape.HasTextFrame == MsoTriState.msoTrue && shape.TextFrame.HasText == MsoTriState.msoTrue)
                            text = shape.TextFrame.TextRange.Text ?? string.Empty;
                    }
                    catch { }
                    if (string.IsNullOrWhiteSpace(text)) continue;
                    if (text.Length > request.MaxCharacters) text = text.Substring(0, request.MaxCharacters);
                    items.Add(new OfficeContextItem
                    {
                        Kind = "ShapeText",
                        Address = "Slide " + slide.SlideIndex + "/" + shape.Name,
                        Text = text
                    });
                    emitted++;
                }
                context.SelectionText = string.Join("\n", items.ConvertAll(i => i.Text));
            }

            context.Items = items;
            return Task.FromResult(context);
        }

        public Task<byte[]> CaptureCurrentViewPngAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Ppt.Slide slide = null;
            try { slide = _application.ActiveWindow?.View?.Slide as Ppt.Slide; } catch { }
            if (slide == null) return Task.FromResult<byte[]>(null);

            string temp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "omnix-slide-" + Guid.NewGuid().ToString("N") + ".png");
            try
            {
                slide.Export(temp, "PNG", 1600, 900);
                byte[] bytes = System.IO.File.ReadAllBytes(temp);
                return Task.FromResult(bytes);
            }
            finally
            {
                try { if (System.IO.File.Exists(temp)) System.IO.File.Delete(temp); } catch { }
            }
        }

        public Task<OfficeMutationPreview> PreviewMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateMutation(mutation);
            return Task.FromResult(new OfficeMutationPreview
            {
                Host = HostName,
                Tool = mutation.Tool,
                Target = string.IsNullOrWhiteSpace(mutation.Target) ? "new slide" : mutation.Target,
                Before = string.Empty,
                After = mutation.Value ?? string.Empty,
                IsDestructive = false
            });
        }

        public Task ApplyMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateMutation(mutation);
            Ppt.Presentation presentation = _application.ActivePresentation
                ?? throw new InvalidOperationException("No active PowerPoint presentation.");

            int index = presentation.Slides.Count + 1;
            if (!string.IsNullOrWhiteSpace(mutation.Target) && int.TryParse(mutation.Target, out int requested))
                index = Math.Max(1, Math.Min(requested, presentation.Slides.Count + 1));

            Ppt.Slide slide = presentation.Slides.Add(index, Ppt.PpSlideLayout.ppLayoutText);
            string value = mutation.Value ?? string.Empty;
            string[] parts = value.Split(new[] { "\n" }, 2, StringSplitOptions.None);
            if (slide.Shapes.Title != null) slide.Shapes.Title.TextFrame.TextRange.Text = parts[0];
            if (slide.Shapes.Placeholders.Count >= 2)
                slide.Shapes.Placeholders[2].TextFrame.TextRange.Text = parts.Length > 1 ? parts[1] : string.Empty;
            return Task.CompletedTask;
        }

        private static void ValidateMutation(OfficeMutation mutation)
        {
            if (mutation == null) throw new ArgumentNullException(nameof(mutation));
            if (mutation.Tool != "insert_slide")
                throw new InvalidOperationException("PowerPoint mutation tool is not whitelisted.");
            if ((mutation.Value?.Length ?? 0) > 20000)
                throw new InvalidOperationException("PowerPoint slide content is too large.");
        }
    }
}
