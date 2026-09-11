using System;
using System.Windows;
using System.Windows.Controls;

namespace OMNIX.Core.Ui
{
    public partial class WorkspaceView : UserControl
    {
        public WorkspaceView()
        {
            InitializeComponent();
            SendButton.Click += (_, __) => SubmitPrompt();
            PromptBox.KeyDown += (sender, e) =>
            {
                if (e.Key == System.Windows.Input.Key.Enter &&
                    (System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Shift) == 0)
                {
                    e.Handled = true;
                    SubmitPrompt();
                }
            };
        }

        public event EventHandler<string> PromptSubmitted;
        public event EventHandler SettingsRequested;

        public void SetContextSummary(string summary)
        {
            ContextText.Text = string.IsNullOrWhiteSpace(summary) ? "No Office context yet" : summary;
        }

        public void AddMessage(string author, string text)
        {
            MessagesPanel.Children.Add(new TextBlock
            {
                Text = (author ?? "OMNIX") + ": " + (text ?? string.Empty),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 8)
            });
        }

        private void SubmitPrompt()
        {
            string prompt = PromptBox.Text?.Trim();
            if (string.IsNullOrWhiteSpace(prompt)) return;
            PromptBox.Clear();
            PromptSubmitted?.Invoke(this, prompt);
        }

        private void OnSettingsRequested(object sender, RoutedEventArgs e)
        {
            SettingsRequested?.Invoke(this, EventArgs.Empty);
        }
    }
}
