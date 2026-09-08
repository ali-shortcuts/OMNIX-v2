using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Context;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;
using OMNIX.Core.Tools;
using OMNIX.Core.Ui.Dialogs;
using OMNIX.Core.Util;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// Per-window controller: every Office document window owns its own WorkspaceView, AI Gateway,
    /// provider adapters, privacy-session approval, cancellation token and conversation state.
    ///
    /// The per-window gateway is intentional: provider adapters keep request configuration in
    /// memory. Sharing one mutable adapter/gateway across two Office windows can race credentials,
    /// model selection and AskBeforeSending callbacks. Isolation prevents one document window from
    /// borrowing another window's provider state or cloud-consent session.
    /// </summary>
    public sealed class WorkspaceController : IDisposable
    {
        private readonly IHostAdapter _adapter;
        private readonly AiGateway.AiGateway _gateway;
        private readonly ChatHistoryStore _historyStore;
        private readonly ToolExecutor _toolExecutor;

        private CancellationTokenSource _cts;
        private List<ChatTurn> _turns = new List<ChatTurn>();
        private string _docKey = "unnamed";
        private bool _busy;
        private bool _disposed;

        public WorkspaceView View { get; private set; }
        public AiGateway.AiGateway Gateway { get { return _gateway; } }
        public ProviderRegistry GatewayRegistry { get { return _gateway.Registry; } }

        public WorkspaceController(IHostAdapter adapter, ChatHistoryStore historyStore)
        {
            if (adapter == null) throw new ArgumentNullException("adapter");
            if (historyStore == null) throw new ArgumentNullException("historyStore");

            _adapter = adapter;
            _historyStore = historyStore;

            // Per-workspace registry/adapters/gateway: no mutable provider state is shared between
            // two open documents. Local runtime discovery is asynchronous and never blocks pane UI.
            _gateway = new AiGateway.AiGateway(new ProviderRegistry());
            ObserveBackground(_gateway.ProbeLocalAsync(), "initial local provider probe");

            _toolExecutor = new ToolExecutor();
            _toolExecutor.WriteConfirmation = preview =>
                Application.Current != null
                    ? RunOnUiThread(() => OmnixDialogs.ConfirmWritePreview(preview))
                    : Task.FromResult(false);

            // This callback now belongs only to THIS workspace's PrivacyGate, so "remember for this
            // session" cannot silently approve a different document window.
            _gateway.Privacy.CloudConfirmationCallback = providerName =>
                RunOnUiThread(() =>
                {
                    var ctx = _adapter.ReadContext();
                    return OmnixDialogs.ConfirmCloudSend(providerName, ctx.ContextBarText);
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
            if (_disposed) return;
            try
            {
                var ctx = _adapter.ReadContext();
                string newKey = DocKeySanitizer.StableKey(
                    ctx.Host.ToString(),
                    ctx.DocumentPath,
                    ctx.DocumentName);

                bool docChanged = !string.Equals(newKey, _docKey, StringComparison.OrdinalIgnoreCase);
                _docKey = newKey;

                if ((docChanged || initial) && !_busy)
                {
                    _turns = _historyStore.Load(_docKey);
                    View.Chat.ReloadMessages(_turns);
                    if (docChanged) _gateway.Privacy.ResetSession();
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
            if (_disposed) return;
            _disposed = true;
            CancelActiveRequest();
            _gateway.Privacy.ResetSession();
            _gateway.Privacy.CloudConfirmationCallback = null;
            Theming.ThemeManager.Instance.ThemeChanged -= OnThemeChanged;
            try { if (_cts != null) _cts.Dispose(); } catch { }
            _cts = null;
        }

        private void OnThemeChanged()
        {
            if (_disposed) return;
            try { Theming.ThemeManager.Instance.ApplyTo(View); } catch { }
        }

        // ------------------------------------------------------------------ chat actions

        public async void SendMessage(string text, ImageAttachment image)
        {
            if (_disposed || _busy) return;
            text = (text ?? "").Trim();
            if (text.Length == 0 && image == null) return;

            _busy = true;
            View.Chat.SetBusy(true);

            var userTurn = new ChatTurn
            {
                Role = ChatRole.User,
                Text = text,
                TimestampUtc = DateTime.UtcNow
            };
            if (image != null && image.PngBytes != null && image.PngBytes.Length > 0)
                userTurn.Images = new List<ImageAttachment> { image };

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

            if (_cts != null)
            {
                try { _cts.Dispose(); } catch { }
            }
            _cts = new CancellationTokenSource();
            var ct = _cts.Token;
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
                        var app = Application.Current;
                        if (app == null || _disposed) return;
                        app.Dispatcher.BeginInvoke(new Action(delegate
                        {
                            if (_disposed) return;
                            sb.Append(delta);
                            bubble.ReplaceText(sb.ToString());
                        }));
                    },
                    _toolExecutor,
                    ct).ConfigureAwait(true);

                if (response != null && !string.IsNullOrEmpty(response.Text) && sb.Length == 0)
                    sb.Append(response.Text);

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
                if (!_disposed) View.Chat.SetBusy(false);
                if (_cts != null)
                {
                    try { _cts.Dispose(); } catch { }
                    _cts = null;
                }
            }
        }

        public void StopStreaming()
        {
            CancelActiveRequest();
        }

        private void CancelActiveRequest()
        {
            try { if (_cts != null) _cts.Cancel(); } catch { }
        }

        public void NewChat()
        {
            if (_disposed) return;
            CancelActiveRequest();
            _turns = new List<ChatTurn>();
            _gateway.Privacy.ResetSession();
            View.Chat.ReloadMessages(_turns);
            View.Chat.SetStatus(Localization.Strings.T("S.Chat.NewSession"));
        }

        public void ClearChat()
        {
            if (_disposed) return;
            CancelActiveRequest();
            _turns = new List<ChatTurn>();
            _historyStore.Delete(_docKey);
            _gateway.Privacy.ResetSession();
            View.Chat.ReloadMessages(_turns);
            View.Chat.SetStatus(Localization.Strings.T("S.Chat.Cleared"));
        }

        public void CopyLastAnswer()
        {
            if (_disposed) return;
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
            if (_disposed) return;
            int idx = _turns.FindLastIndex(t => t.Role == ChatRole.User);
            if (idx < 0)
            {
                View.Chat.SetStatus(Localization.Strings.T("S.Chat.RetryEmpty"));
                return;
            }

            var resend = _turns[idx];
            _turns = _turns.Take(idx).ToList();
            View.Chat.ReloadMessages(_turns);
            ImageAttachment img = resend.HasImages ? resend.Images.FirstOrDefault(i => i != null && i.PngBytes != null && i.PngBytes.Length > 0) : null;
            SendMessage(resend.Text, img);
        }

        public void AttachImageFromDocument()
        {
            if (_disposed) return;
            try
            {
                byte[] png = _adapter.CaptureCurrentViewAsImage();
                if (png == null || png.Length == 0)
                {
                    View.Chat.SetStatus("No capturable Office view is available.");
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
            if (_disposed) return;
            try
            {
                var dlg = new System.Windows.Forms.OpenFileDialog
                {
                    Title = Localization.Strings.T("S.Chat.UploadImage"),
                    Filter = "Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp"
                };
                if (dlg.ShowDialog() != System.Windows.Forms.DialogResult.OK) return;

                var info = new System.IO.FileInfo(dlg.FileName);
                if (info.Length > 20L * 1024L * 1024L)
                {
                    View.Chat.SetStatus("Image is too large (maximum 20 MB).\nChoose a smaller image.");
                    return;
                }

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
            if (_disposed) return;
            SettingsManager.Instance.Save();
            _gateway.Privacy.ResetSession();
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
            return Task.FromResult(app.Dispatcher.Invoke(action));
        }

        private static async void ObserveBackground(Task task, string operation)
        {
            if (task == null) return;
            try { await task.ConfigureAwait(false); }
            catch (Exception ex) { Logger.Error("gateway", "Background " + operation + " failed", ex); }
        }
    }
}
