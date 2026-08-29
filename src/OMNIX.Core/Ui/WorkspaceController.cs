using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Context;
using OMNIX.Core.ContextLimiter;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;
using OMNIX.Core.Security;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;
using OMNIX.Core.Tools;
using OMNIX.Core.Ui.Dialogs;
using OMNIX.Core.Ui.Markdown;
using OMNIX.Core.Util;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// Per-window controller: one instance per Office document window (spec Section 5 —
    /// "هر پنجرهٔ باز، Task Pane و Context مخصوص به خودش را دارد"). Owns the WorkspaceView,
    /// the chat history of THIS document, the context bar, streaming and cancellation.
    /// </summary>
    public sealed class WorkspaceController : IDisposable
    {
        private readonly IHostAdapter _adapter;
        private readonly AiGateway _gateway;
        private readonly ChatHistoryStore _historyStore;
        private readonly ToolExecutor _toolExecutor;

        private CancellationTokenSource _cts;
        private List<ChatTurn> _turns = new List<ChatTurn>();
        private string _docKey = "unnamed";
        private bool _busy;

        public WorkspaceView View { get; private set; }

        public AiGateway.AiGateway Gateway { get { return _gateway; } }
        public ProviderRegistry GatewayRegistry { get { return _gateway.Registry; } }

        public WorkspaceController(IHostAdapter adapter, AiGateway gateway, ChatHistoryStore historyStore)
        {
            _adapter = adapter;
            _gateway = gateway;
            _historyStore = historyStore;
            _toolExecutor = new ToolExecutor();
            _toolExecutor.WriteConfirmation = preview =>
                Application.Current != null
                    ? RunOnUiThread(() => OmnixDialogs.ConfirmWritePreview(preview))
                    : Task.FromResult(false);

            _gateway.Privacy.CloudConfirmationCallback = providerName =>
                RunOnUiThread(() =>
                {
                    var t = OmnixDialogs.ConfirmCloudSend(providerName, _adapter.ReadContext().ContextBarText);
                    return t;
                });

            View = new WorkspaceView(this);
            Theming.ThemeManager.Instance.ApplyTo(View);
            View.Resources.MergedDictionaries.Add(Localization.Strings.Dictionary);
            Theming.ThemeManager.Instance.ThemeChanged += OnThemeChanged;
            RefreshContextBar(initial: true);
        }

        // ------------------------------------------------------------------ lifecycle

        public void RefreshContextBar(bool initial = false)
        {
            try
            {
                var ctx = _adapter.ReadContext();
                string newKey = DocKeySanitizer.Sanitize(ctx.DocumentName ?? "unnamed");

                bool docChanged = !string.Equals(newKey, _docKey, StringComparison.OrdinalIgnoreCase);
                _docKey = newKey;

                if ((docChanged || initial) && !_busy)
                {
                    _turns = _historyStore.Load(_docKey);
                    View.Chat.ReloadMessages(_turns);
                }

                View.Chat.SetContextText(ctx.ContextBarText);
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "RefreshContextBar failed", ex);
            }
        }

        public void OnPaneClosing()
        {
            CancelActiveRequest();
        }

        public void Dispose()
        {
            CancelActiveRequest();
            Theming.ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
        }

        private void OnThemeChanged()
        {
            try
            {
                Theming.ThemeManager.Instance.ApplyTo(View);
            }
            catch { }
        }

        // ------------------------------------------------------------------ chat actions

        public async void SendMessage(string text, ImageAttachment image)
        {
            if (_busy) return;
            text = (text ?? "").Trim();
            if (text.Length == 0 && image == null) return;
            if (_adapter.ReadContext().IsEmpty && string.IsNullOrEmpty(SettingsManager.Instance.GetApiKey(SettingsManager.Instance.Settings.SelectedProviderId)))
            {
                // Nothing fatal — the gateway will report a categorized error anyway.
            }

            _busy = true;
            View.Chat.SetBusy(true);

            var userTurn = new ChatTurn
            {
                Role = ChatRole.User,
                Text = text,
                TimestampUtc = DateTime.UtcNow
            };
            if (image != null)
            {
                userTurn.Images = new List<ImageAttachment> { image };
            }

            _turns.Add(userTurn);
            View.Chat.AppendTurn(userTurn);
            Persist();

            var assistantTurn = new ChatTurn
            {
                Role = ChatRole.Assistant,
                Text = "",
                TimestampUtc = DateTime.UtcNow
            };
            var bubble = View.Chat.AppendTurn(assistantTurn);
            bubble.AppendText("…");

            _cts = new CancellationTokenSource();
            var ct = _cts.Token;
            int deltaCount = 0;
            var sb = new System.Text.StringBuilder();

            try
            {
                var request = new ChatRequest
                {
                    SystemPrompt = AiGateway.AiGateway.BuildSystemPrompt(_adapter, _adapter.ReadContext()),
                    History = _turns.Take(_turns.Count - 1).ToList(),
                    UserTurn = userTurn
                };

                var response = await _gateway.ChatAsync(
                    request,
                    _adapter,
                    delta =>
                    {
                        deltaCount++;
                        var app = Application.Current;
                        if (app == null) return;
                        app.Dispatcher.BeginInvoke(new Action(delegate
                        {
                            sb.Append(delta);
                            bubble.ReplaceText(sb.ToString());
                        }));
                    },
                    _toolExecutor,
                    ct).ConfigureAwait(true);

                // A tool round may have produced the final text already — replace cleanly.
                if (!string.IsNullOrEmpty(response.Text) && sb.Length == 0)
                {
                    sb.Append(response.Text);
                }

                assistantTurn.Text = sb.Length > 0 ? sb.ToString() : Localization.Strings.T("S.Chat.Cancelled");
                bubble.ReplaceText(assistantTurn.Text);
                _turns.Add(assistantTurn);
                Persist();
            }
            catch (OperationCanceledException)
            {
                assistantTurn.Text = sb.ToString() + Environment.NewLine + Localization.Strings.T("S.Chat.Cancelled");
                bubble.ReplaceText(assistantTurn.Text);
                _turns.Add(assistantTurn);
                Persist();
            }
            catch (OmnixException ex)
            {
                bubble.ReplaceText("");
                View.Chat.ShowError(ErrorPresenter.Format(ex));
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "SendMessage failed", ex);
                bubble.ReplaceText("");
                View.Chat.ShowError(ErrorPresenter.Format(ex));
            }
            finally
            {
                _busy = false;
                View.Chat.SetBusy(false);
                _cts = null;
            }
        }

        public void StopStreaming()
        {
            CancelActiveRequest();
        }

        private void CancelActiveRequest()
        {
            try
            {
                if (_cts != null)
                {
                    _cts.Cancel();
                }
            }
            catch { }
        }

        public void NewChat()
        {
            CancelActiveRequest();
            _turns = new List<ChatTurn>();
            View.Chat.ReloadMessages(_turns);
            View.Chat.SetStatus(Localization.Strings.T("S.Chat.NewSession"));
        }

        public void ClearChat()
        {
            CancelActiveRequest();
            _turns = new List<ChatTurn>();
            _historyStore.Delete(_docKey);
            View.Chat.ReloadMessages(_turns);
            View.Chat.SetStatus(Localization.Strings.T("S.Chat.Cleared"));
        }

        public void CopyLastAnswer()
        {
            var last = _turns.LastOrDefault(t => t.Role == ChatRole.Assistant && !string.IsNullOrEmpty(t.Text));
            if (last == null)
            {
                View.Chat.SetStatus(Localization.Strings.T("S.Chat.NothingToCopy"));
                return;
            }
            try
            {
                Clipboard.SetText(last.Text);
                View.Chat.SetStatus(Localization.Strings.T("S.Chat.Copied"));
            }
            catch { }
        }

        public void RetryLast()
        {
            var lastUser = _turns.LastOrDefault(t => t.Role == ChatRole.User);
            if (lastUser == null)
            {
                View.Chat.SetStatus(Localization.Strings.T("S.Chat.RetryEmpty"));
                return;
            }

            // Remove trailing turns after (and including) the last assistant answer, keep the user question.
            int idx = _turns.FindLastIndex(t => t.Role == ChatRole.User);
            if (idx >= 0)
            {
                var resend = _turns[idx];
                _turns = _turns.Take(idx).ToList();
                View.Chat.ReloadMessages(_turns);
                ImageAttachment img = resend.HasImages ? resend.Images[0] : null;
                SendMessage(resend.Text, img);
            }
        }

        public void AttachImageFromDocument()
        {
            try
            {
                byte[] png = _adapter.CaptureCurrentViewAsImage();
                if (png == null || png.Length == 0)
                {
                    View.Chat.SetStatus(Localization.Strings.T("S.Chat.NothingToCopy"));
                    return;
                }
                View.Chat.SetPendingImage(new ImageAttachment
                {
                    PngBytes = png,
                    FileName = "document-capture.png",
                    SourceLabel = _adapter.HostDisplayName
                });
            }
            catch (OmnixException ex)
            {
                View.Chat.ShowError(ErrorPresenter.Format(ex));
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "AttachImageFromDocument failed", ex);
                View.Chat.SetStatus("Capture failed");
            }
        }

        public void AttachImageFromDisk()
        {
            try
            {
                var dlg = new System.Windows.Forms.OpenFileDialog
                {
                    Title = Localization.Strings.T("S.Chat.UploadImage"),
                    Filter = "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp"
                };
                if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;
                byte[] bytes = System.IO.File.ReadAllBytes(dlg.FileName);
                View.Chat.SetPendingImage(new ImageAttachment
                {
                    PngBytes = bytes,
                    FileName = System.IO.Path.GetFileName(dlg.FileName),
                    SourceLabel = "file"
                });
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "AttachImageFromDisk failed", ex);
                View.Chat.SetStatus("Upload failed");
            }
        }

        public void SaveSettingsFromUi()
        {
            SettingsManager.Instance.Save();
            View.Chat.SetStatus(Localization.Strings.T("S.Settings.Saved"));
        }

        private void Persist()
        {
            _historyStore.Save(_docKey, _turns);
        }

        private static Task<T> RunOnUiThread<T>(Func<T> action)
        {
            var app = Application.Current;
            if (app == null) return Task.FromResult(default(T));
            return app.Dispatcher.Invoke(action);
        }
    }
}
