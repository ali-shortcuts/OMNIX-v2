using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using OMNIX.Core.Storage;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// Chat page (spec Section 5): bubbles, real streaming, real Stop (CancellationToken),
    /// New Chat / Copy / Retry / Stop / Clear, attach-image buttons and the context bar.
    /// Designed for 360px width.
    /// </summary>
    public partial class ChatView : UserControl
    {
        private WorkspaceController _controller;
        private ImageAttachment _pendingImage;

        public ChatView()
        {
            InitializeComponent();
        }

        public void Initialize(WorkspaceController controller)
        {
            _controller = controller;
        }

        // ------------------------------------------------------------- message list

        public ChatBubble AppendTurn(ChatTurn turn)
        {
            var bubble = new ChatBubble(turn);
            MessagesPanel.Children.Add(bubble);
            ScrollToBottom();
            return bubble;
        }

        public void ReloadMessages(IEnumerable<ChatTurn> turns)
        {
            MessagesPanel.Children.Clear();
            foreach (var t in turns)
            {
                var bubble = new ChatBubble(t);
                MessagesPanel.Children.Add(bubble);
            }
            ScrollToBottom();
        }

        private void ScrollToBottom()
        {
            MessagesScroll.UpdateLayout();
            MessagesScroll.ScrollToEnd();
        }

        // ------------------------------------------------------------- state

        public void SetBusy(bool busy)
        {
            SendButton.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
            StopButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            NewChatButton.IsEnabled = !busy;
            ClearButton.IsEnabled = !busy;
            RetryButton.IsEnabled = !busy;
        }

        public void SetContextText(string text)
        {
            ContextText.Text = text ?? "—";
        }

        public void SetStatus(string message)
        {
            StatusText.Text = message ?? "";
            StatusText.SetResourceReference(TextBlock.ForegroundProperty, "B.ForegroundDim");
            StatusBorder.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
        }

        public void ShowError(string message)
        {
            StatusText.Text = message ?? "";
            StatusText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            StatusBorder.Visibility = Visibility.Visible;
        }

        private void OnStatusClose(object sender, RoutedEventArgs e)
        {
            SetStatus("");
        }

        // ------------------------------------------------------------- pending image

        public void SetPendingImage(ImageAttachment image)
        {
            _pendingImage = image;
            if (image != null && image.PngBytes != null)
            {
                var bmp = new BitmapImage();
                using (var ms = new System.IO.MemoryStream(image.PngBytes))
                {
                    bmp.BeginInit();
                    bmp.CacheOption = BitmapCacheOption.OnLoad;
                    bmp.StreamSource = ms;
                    bmp.EndInit();
                }
                bmp.Freeze();
                PendingImage.Source = bmp;
                PendingImageBorder.Visibility = Visibility.Visible;
            }
            else
            {
                PendingImageBorder.Visibility = Visibility.Collapsed;
            }
        }

        private void OnRemovePendingImage(object sender, RoutedEventArgs e)
        {
            SetPendingImage(null);
        }

        public void CancelPending()
        {
            if (_controller != null) _controller.StopStreaming();
        }

        // ------------------------------------------------------------- events

        private void OnSend(object sender, RoutedEventArgs e)
        {
            Send();
        }

        private void OnStop(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.StopStreaming();
        }

        private void OnNewChat(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.NewChat();
        }

        private void OnCopy(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.CopyLastAnswer();
        }

        private void OnRetry(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.RetryLast();
        }

        private void OnClear(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.ClearChat();
        }

        private void OnAttachFromDocument(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.AttachImageFromDocument();
        }

        private void OnUploadImage(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.AttachImageFromDisk();
        }

        private void OnInputKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
            {
                e.Handled = true;
                Send();
            }
        }

        private void Send()
        {
            if (_controller == null) return;
            string text = InputBox.Text;
            InputBox.Clear();
            var image = _pendingImage;
            SetPendingImage(null);
            _controller.SendMessage(text, image);
        }
    }
}
