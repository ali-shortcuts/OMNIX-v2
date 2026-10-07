using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Documents;
using OMNIX.Core.Ui.Markdown;
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
        private readonly List<Action> _refreshConversation = new List<Action>();
        private sealed class ConversationPart
        {
            public Section Content;
            public string Text = "";
            public Paragraph StreamingParagraph;
        }
        private bool _reloading;
        private bool _busy;
        private string _lastOperationPhase;
        private readonly Queue<string> _operationHistory = new Queue<string>();

        public ChatView()
        {
            InitializeComponent();
            Loaded += (sender,args)=>Theming.ThemeManager.Instance.ThemeChanged+=RefreshConversationTheme;
            Unloaded += (sender,args)=>Theming.ThemeManager.Instance.ThemeChanged-=RefreshConversationTheme;
        }

        public void Initialize(WorkspaceController controller)
        {
            _controller = controller;
        }

        private void RefreshConversationTheme() {
            Dispatcher.BeginInvoke(new Action(()=> {if(IsLoaded) foreach(var refresh in _refreshConversation.ToArray()) refresh();}));
        }
        public ContextMenu ActionsMenu { get { return (ContextMenu)FindResource("WorkspaceActions"); } }
        private WorkspaceView Workspace() {
            DependencyObject node=this;
            while(node!=null && !(node is WorkspaceView)) node=VisualTreeHelper.GetParent(node);
            return node as WorkspaceView;
        }
        private void OnMenuSettings(object sender,RoutedEventArgs e) { var view=Workspace();if(view!=null) view.ShowSettingsTab(); }
        private void OnMenuAbout(object sender,RoutedEventArgs e) { var view=Workspace();if(view!=null) view.ShowAboutTab(); }
        private void OnMenuLearn(object sender,RoutedEventArgs e) { var view=Workspace();if(view!=null) view.ShowLearnTab(); }

        // ------------------------------------------------------------- message list

        public ChatBubble AppendTurn(ChatTurn turn)
        {
            var bubble = new ChatBubble(turn);
            MessagesPanel.Children.Add(bubble);
            var header=new Paragraph(new Run((turn.Role==ChatRole.User?Localization.Strings.T("S.Chat.You"):Localization.Strings.T("S.Chat.Assistant"))+" · "+turn.TimestampUtc.ToLocalTime().ToString("HH:mm"))) {FontSize=11,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,10,0,3)};
            header.SetResourceReference(TextElement.ForegroundProperty,"B.ForegroundDim");
            var content=new Section {Margin=new Thickness(0,0,0,10)};
            ConversationBox.Document.Blocks.Add(header);ConversationBox.Document.Blocks.Add(content);
            var part = new ConversationPart { Content = content };
            Action<string,bool> render=(text,streaming)=>RenderConversationPart(part,text,streaming);
            bubble.TextUpdated+=render;render(turn.Text??"",false);
            _refreshConversation.Add(()=>render(bubble.RawText,false));
            if(turn.HasImages && turn.Images[0].PngBytes!=null) {
                try {
                    var bitmap=new BitmapImage();
                    using(var source=new System.IO.MemoryStream(turn.Images[0].PngBytes)) {
                        bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.StreamSource=source;bitmap.EndInit();bitmap.Freeze();
                    }
                    ConversationBox.Document.Blocks.Add(new BlockUIContainer(new Image {Source=bitmap,MaxHeight=120,Stretch=Stretch.Uniform}));
                } catch {}
            }
            if(!_reloading) ScrollToBottom();
            return bubble;
        }

        public void ReloadMessages(IEnumerable<ChatTurn> turns)
        {
            MessagesPanel.Children.Clear();
            _refreshConversation.Clear();
            ConversationBox.Document.Blocks.Clear();
            _reloading=true;
            try {foreach(var turn in turns) AppendTurn(turn);} finally {_reloading=false;}
            ScrollToBottom();
        }

        private void RenderConversationPart(ConversationPart part,string text,bool streaming)
        {
            var content = part.Content;
            text = text ?? "";
            ConversationBox.Document.Foreground=(Brush)FindResource("B.Foreground");
            bool follow=!_reloading && ConversationBox.Selection.IsEmpty && ConversationBox.VerticalOffset+ConversationBox.ViewportHeight>=ConversationBox.ExtentHeight-36;
            content.FlowDirection=System.Text.RegularExpressions.Regex.IsMatch(text??"",@"^[^A-Za-z\u0600-\u06ff]*[\u0600-\u06ff]")?FlowDirection.RightToLeft:FlowDirection.LeftToRight;
            if(streaming) {
                if(part.StreamingParagraph != null && text.StartsWith(part.Text, StringComparison.Ordinal))
                {
                    // Keep the existing text/selection and append only this transport batch.
                    string added = text.Substring(part.Text.Length);
                    if(added.Length > 0) part.StreamingParagraph.Inlines.Add(new Run(added));
                }
                else {
                    content.Blocks.Clear();
                    part.StreamingParagraph = new Paragraph(new Run(text)) {Margin=new Thickness(0)};
                    content.Blocks.Add(part.StreamingParagraph);
                }
            }
            else {
                content.Blocks.Clear();
                part.StreamingParagraph = null;
                var doc=new FlowDocument();doc.SetResourceReference(TextElement.ForegroundProperty,"B.Foreground");
                // Resolve the pane brush explicitly for Markdown tables/code in VSTO.
                doc.Foreground=(Brush)FindResource("B.Foreground");
                foreach(string key in new[]{"B.Foreground","B.ForegroundDim","B.Border","B.Accent","B.Link","B.CodeBackground","B.CodeKeyword","B.CodeString","B.CodeComment","B.CodeNumber"}) {
                    var brush=TryFindResource(key) as Brush;if(brush!=null) doc.Resources[key]=brush;
                }
                MarkdownRenderer.Render(doc,text);
                while(doc.Blocks.FirstBlock!=null) {var block=doc.Blocks.FirstBlock;doc.Blocks.Remove(block);content.Blocks.Add(block);}
            }
            part.Text = text;
            if(follow) ConversationBox.ScrollToEnd();
        }

        private void ScrollToBottom()
        {
            if(ConversationBox.Selection.IsEmpty) ConversationBox.ScrollToEnd();
            MessagesScroll.UpdateLayout();
            MessagesScroll.ScrollToEnd();
        }

        // ------------------------------------------------------------- state

        public void SetBusy(bool busy)
        {
            _busy = busy;
            ExecutionLesson.Text = ""; ExecutionLesson.Visibility = Visibility.Collapsed;
            if (busy)
            {
                _lastOperationPhase = "preparing";
                _operationHistory.Clear();
                ExecutionHistory.Clear();
                ExecutionText.Text = OMNIX.Core.Settings.SettingsManager.Instance.Settings.UiLanguage == "fa" ? "در حال آماده‌سازی" : "Preparing";
                ExecutionText.SetResourceReference(TextBlock.ForegroundProperty, "B.Foreground");
                ExecutionBorder.Visibility = Visibility.Visible;
            }
            else if (_operationHistory.Count == 0 || _lastOperationPhase == "preparing" || _lastOperationPhase == "waiting" || _lastOperationPhase == "processing")
            {
                ExecutionText.Text = OMNIX.Core.Settings.SettingsManager.Instance.Settings.UiLanguage == "fa" ? "درخواست پایان یافت" : "Request ended";
            }
            if(!busy) ExecutionBorder.Visibility=Visibility.Collapsed;
            SendButton.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
            StopButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
            foreach(var item in ActionsMenu.Items.OfType<MenuItem>())
                if(new[]{"NewChatButton","ClearButton","RetryButton"}.Contains(item.Name)) item.IsEnabled=!busy;
        }

        public void ShowOperation(string operation, string phase)
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.BeginInvoke(new Action(() => ShowOperation(operation, phase)));
                return;
            }
            if (!_busy) return;
            _lastOperationPhase = phase;
            bool fa = OMNIX.Core.Settings.SettingsManager.Instance.Settings.UiLanguage == "fa";
            string label;
            switch (phase)
            {
                case "preparing": label = fa ? "آماده‌سازی" : "Preparing"; break;
                case "waiting": label = fa ? "انتظار مدل" : "Waiting for model"; break;
                case "processing": label = fa ? "پردازش" : "Processing"; break;
                case "inspect": label = fa ? "بررسی" : "Inspecting"; break;
                case "preview": label = fa ? "پیش‌نمایش" : "Preview"; break;
                case "apply": label = fa ? "اجرا" : "Applying"; break;
                case "verify": label = fa ? "بررسی نتیجه" : "Verifying"; break;
                case "verified": label = fa ? "طرح تأیید شد" : "Plan verified"; break;
                case "incomplete": label = fa ? "طرح هنوز کامل نیست" : "Plan incomplete"; break;
                case "complete": label = fa ? "ابزار اجرا شد" : "Tool completed"; break;
                case "cancelled": label = fa ? "متوقف شد" : "Stopped"; break;
                default: label = fa ? "خطای ابزار" : "Tool failed"; break;
            }
            string line = label + " · " + operation;
            ExecutionText.Text = line;
            string lesson = TeachingLesson(phase,fa);
            bool teaching = OMNIX.Core.Settings.SettingsManager.Instance.Settings.ExecutionTeachingMode && !string.IsNullOrEmpty(lesson);
            ExecutionLesson.Text = teaching ? lesson : "";
            ExecutionLesson.Visibility = teaching ? Visibility.Visible : Visibility.Collapsed;
            ExecutionText.SetResourceReference(TextBlock.ForegroundProperty,
                phase == "failed" || phase == "incomplete" ? "B.Danger" : phase == "verified" ? "B.Success" : "B.Foreground");
            _operationHistory.Enqueue(DateTime.Now.ToString("HH:mm:ss") + "  " + line);
            while (_operationHistory.Count > 80) _operationHistory.Dequeue();
            ExecutionHistory.Text = string.Join(Environment.NewLine, _operationHistory);
            ExecutionHistory.ScrollToEnd();
            ExecutionBorder.Visibility = Visibility.Visible;
        }

        internal static string TeachingLesson(string phase,bool fa)
        {
            switch(phase)
            {
                case "inspect": return fa ? "مقصد واقعی پیش از تغییر بررسی می‌شود." : "Inspect the actual target before changing it.";
                case "preview": return fa ? "محدوده و تغییر پیشنهادی آماده می‌شود." : "Prepare the target range and proposed change.";
                case "apply": return fa ? "ابزار واقعی Office تغییر را اجرا می‌کند." : "The actual Office tool applies the change.";
                case "verify": return fa ? "محتوا و فرمول‌ها با معیارهای طرح مقایسه می‌شوند." : "Compare actual content and formulas with the plan criteria.";
                case "incomplete": return fa ? "معیارهای طرح هنوز کامل نیست؛ همان مقصد نیاز به اصلاح دارد." : "Some plan criteria still fail; inspect and repair the existing target.";
                case "verified": return fa ? "همهٔ معیارهای ثبت‌شدهٔ طرح در این بررسی موفق شدند." : "All recorded plan criteria passed this check.";
                case "complete": return fa ? "این ابزار پایان یافت؛ تکمیل کل درخواست جدا بررسی می‌شود." : "This tool ended; completion of the whole request is checked separately.";
                default: return "";
            }
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

        private void OnTranscript(object sender, RoutedEventArgs e)
        {
            bool cards=MessagesScroll.Visibility!=Visibility.Visible;
            MessagesScroll.Visibility=cards?Visibility.Visible:Visibility.Collapsed;
            ConversationBox.Visibility=cards?Visibility.Collapsed:Visibility.Visible;
            if(!cards) ConversationBox.Focus();
        }

        private void OnImportText(object sender, RoutedEventArgs e)
        {
            var picker = new Microsoft.Win32.OpenFileDialog { Filter = "Text files (*.txt)|*.txt", Multiselect = false };
            if (picker.ShowDialog() != true) return;
            try
            {
                if (new System.IO.FileInfo(picker.FileName).Length > 262144)
                { ShowError("Text file is too large. Split it into smaller files."); return; }
                string content = System.IO.File.ReadAllText(picker.FileName, new System.Text.UTF8Encoding(false, true));
                if (InputBox.Text.Length + content.Length > 65536)
                { ShowError("Combined text exceeds 65,536 characters. Nothing was removed."); return; }
                InputBox.AppendText(content);
                InputBox.Focus();
            }
            catch { ShowError("Could not read this text file. Use UTF-8 text."); }
        }

        private void OnCopy(object sender, RoutedEventArgs e)
        {
            if (_controller != null) _controller.CopyConversation();
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
            if (_controller == null || _busy) return;
            string text = InputBox.Text;
            if (string.IsNullOrWhiteSpace(text) && _pendingImage == null) return;
            if (text.Length > 64 * 1024)
            {
                ShowError("Message exceeds 65,536 characters. Your draft has been preserved; split it into smaller messages.");
                return;
            }
            InputBox.Clear();
            var image = _pendingImage;
            SetPendingImage(null);
            _controller.SendMessage(text, image);
        }
    }
}
