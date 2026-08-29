using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using OMNIX.Core.Storage;
using OMNIX.Core.Ui.Markdown;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// One chat message (spec Section 5): user and AI bubbles with different colors and
    /// alignment; AI answers are rendered as Markdown (real tables, highlighted code blocks,
    /// monospace Excel formulas). Streaming appends text into the existing bubble.
    /// </summary>
    public sealed class ChatBubble : Border
    {
        private readonly RichTextBox _body;
        private readonly TextBlock _header;
        private readonly Image _image;
        private readonly FlowDocument _doc;
        private string _rawText = "";

        public bool IsUser { get; private set; }

        public ChatBubble(ChatTurn turn)
        {
            IsUser = turn.Role == ChatRole.User;
            CornerRadius = new CornerRadius(10);
            Padding = new Thickness(8, 6, 8, 6);
            Margin = new Thickness(IsUser ? 28 : 4, 3, IsUser ? 4 : 28, 3);
            MaxWidth = 420;

            if (IsUser)
            {
                Background = Find("B.BubbleUser");
                HorizontalAlignment = HorizontalAlignment.Right;
            }
            else
            {
                Background = Find("B.BubbleAi");
                HorizontalAlignment = HorizontalAlignment.Left;
            }

            var stack = new StackPanel();

            _header = new TextBlock
            {
                FontSize = 10,
                FontWeight = FontWeights.SemiBold,
                Opacity = 0.8,
                Margin = new Thickness(0, 0, 0, 2)
            };
            _header.Text = (IsUser ? Localization.Strings.T("S.Chat.You") : Localization.Strings.T("S.Chat.Assistant"))
                           + "  ·  " + turn.TimestampUtc.ToLocalTime().ToString("HH:mm");
            stack.Children.Add(_header);

            _doc = new FlowDocument
            {
                PagePadding = new Thickness(0),
                ColumnWidth = double.PositiveInfinity
            };
            _doc.SetCurrentValue(System.Windows.Documents.TextElement.FontFamilyProperty, new FontFamily("Segoe UI"));
            _doc.SetCurrentValue(System.Windows.Documents.TextElement.FontSizeProperty, 12.0);
            _doc.SetCurrentValue(TextElement.ForegroundProperty,
                IsUser ? Find("B.BubbleUserForeground") : Find("B.BubbleAiForeground"));

            _body = new RichTextBox
            {
                Document = _doc,
                BorderThickness = new Thickness(0),
                Background = Brushes.Transparent,
                IsReadOnly = true,
                IsReadOnlyCaretVisible = false,
                Padding = new Thickness(0),
                VerticalContentAlignment = VerticalAlignment.Top,
                Cursor = Cursors.IBeam
            };
            // Width-adaptive wrapping inside the narrow pane (no horizontal scrolling).
            _body.Document.PageWidth = double.NaN;
            _body.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
            _body.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
            _body.IsDocumentEnabled = true;
            stack.Children.Add(_body);

            _image = new Image
            {
                MaxHeight = 160,
                Margin = new Thickness(0, 4, 0, 0),
                Stretch = Stretch.Uniform,
                Visibility = Visibility.Collapsed
            };
            stack.Children.Add(_image);

            Child = stack;

            if (turn.HasImages && turn.Images[0].PngBytes != null)
                SetImage(turn.Images[0].PngBytes);

            AppendMarkdown(turn.Text ?? "");
        }

        public void SetImage(byte[] png)
        {
            if (png == null) return;
            try
            {
                var image = new System.Windows.Media.Imaging.BitmapImage();
                using (var ms = new System.IO.MemoryStream(png))
                {
                    image.BeginInit();
                    image.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
                    image.StreamSource = ms;
                    image.EndInit();
                }
                image.Freeze();
                _image.Source = image;
                _image.Visibility = Visibility.Visible;
            }
            catch { }
        }

        /// <summary>Streaming: appends chunk text and re-renders the markdown view.</summary>
        public void AppendText(string chunk)
        {
            _rawText += chunk ?? "";
            AppendMarkdown(_rawText);
            ScrollToEndSafe();
        }

        public void ReplaceText(string fullText)
        {
            _rawText = fullText ?? "";
            AppendMarkdown(_rawText);
            ScrollToEndSafe();
        }

        private void AppendMarkdown(string text)
        {
            MarkdownRenderer.Render(_doc, text);
        }

        private void ScrollToEndSafe()
        {
            _body.ScrollToEnd();
        }

        private static Brush Find(string key)
        {
            object v = Application.Current != null ? Application.Current.TryFindResource(key) : null;
            return v as Brush ?? Brushes.Transparent;
        }
    }
}
