using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Context;
using Wd = Microsoft.Office.Interop.Word;

namespace OMNIX.Word
{
    public sealed class WordHostAdapter : IOfficeHostAdapter
    {
        private readonly Wd.Application _application;

        public WordHostAdapter(Wd.Application application)
        {
            _application = application ?? throw new ArgumentNullException(nameof(application));
        }

        public string HostName => "Word";

        public Task<OfficeContext> CaptureContextAsync(ContextRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            request = request ?? new ContextRequest();

            var context = new OfficeContext { Host = HostName };
            Wd.Document document = _application.ActiveDocument;
            Wd.Selection selection = _application.Selection;

            if (document != null)
            {
                context.DocumentName = document.Name;
                try { context.DocumentPath = document.FullName; } catch { context.DocumentPath = document.Name; }
            }

            var items = new List<OfficeContextItem>();
            if (selection != null && selection.Range != null)
            {
                string text = selection.Range.Text ?? string.Empty;
                if (text.Length > request.MaxCharacters) text = text.Substring(0, request.MaxCharacters);
                context.SelectionText = text;
                items.Add(new OfficeContextItem
                {
                    Kind = "Selection",
                    Address = selection.Range.Start + ":" + selection.Range.End,
                    Text = text
                });
            }

            if (document != null && items.Count < request.MaxItems)
            {
                int count = Math.Min(document.Paragraphs.Count, Math.Min(request.MaxItems - items.Count, 50));
                for (int i = 1; i <= count; i++)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    Wd.Paragraph paragraph = document.Paragraphs[i];
                    string text = paragraph.Range.Text ?? string.Empty;
                    if (text.Length > 800) text = text.Substring(0, 800);
                    items.Add(new OfficeContextItem
                    {
                        Kind = "Paragraph",
                        Address = paragraph.Range.Start + ":" + paragraph.Range.End,
                        Text = text
                    });
                }
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
            Wd.Selection selection = _application.Selection;
            if (selection == null || selection.Range == null || selection.Range.Start == selection.Range.End)
                throw new InvalidOperationException("Word rewrite requires a non-empty selection.");

            string before = selection.Range.Text ?? string.Empty;
            return Task.FromResult(new OfficeMutationPreview
            {
                Host = HostName,
                Tool = mutation.Tool,
                Target = selection.Range.Start + ":" + selection.Range.End,
                Before = before,
                After = mutation.Value ?? string.Empty,
                IsDestructive = true
            });
        }

        public Task ApplyMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ValidateMutation(mutation);
            Wd.Selection selection = _application.Selection;
            if (selection == null || selection.Range == null || selection.Range.Start == selection.Range.End)
                throw new InvalidOperationException("Word rewrite requires a non-empty selection.");
            selection.Range.Text = mutation.Value ?? string.Empty;
            return Task.CompletedTask;
        }

        private static void ValidateMutation(OfficeMutation mutation)
        {
            if (mutation == null) throw new ArgumentNullException(nameof(mutation));
            if (mutation.Tool != "rewrite_selected_text")
                throw new InvalidOperationException("Word mutation tool is not whitelisted.");
            if ((mutation.Value?.Length ?? 0) > 100000)
                throw new InvalidOperationException("Word replacement is too large.");
        }
    }
}
