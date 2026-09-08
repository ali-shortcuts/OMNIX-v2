using System;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;
using OMNIX.Core.Theming;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// Settings page: provider dropdown, DPAPI-protected API key, dynamic models,
    /// categorized diagnostics, verified official provider setup links, explicit access/free-tier
    /// information, local AI probing, Privacy Mode, appearance and history limits.
    /// </summary>
    public partial class SettingsView : UserControl
    {
        private WorkspaceController _controller;
        private bool _loading;

        private static readonly string[] AllowedOfficialHosts =
        {
            "ai.google.dev",
            "aistudio.google.com",
            "groq.com",
            "console.groq.com",
            "openrouter.ai",
            "mistral.ai",
            "www.mistral.ai",
            "docs.mistral.ai",
            "console.mistral.ai",
            "cerebras.ai",
            "www.cerebras.ai",
            "inference-docs.cerebras.ai",
            "cloud.cerebras.ai",
            "ollama.com",
            "docs.ollama.com",
            "lmstudio.ai"
        };

        public SettingsView()
        {
            InitializeComponent();
        }

        public void Initialize(WorkspaceController controller)
        {
            _controller = controller;
        }

        public void OnShown()
        {
            if (!_loading) LoadFromSettings();
        }

        private void LoadFromSettings()
        {
            _loading = true;
            try
            {
                var settings = SettingsManager.Instance.Settings;
                var registry = _controller != null ? _controller.GatewayRegistry : null;

                ProviderCombo.ItemsSource = registry != null ? registry.All.Select(p => p.Info).ToList() : null;
                var selected = registry != null ? registry.Get(settings.SelectedProviderId) : null;
                if (selected != null)
                {
                    ProviderCombo.SelectedItem = selected.Info;
                    UpdateProviderUi(selected.Info);
                    TestResultText.Text = BuildProviderSummary(selected.Info);
                }

                string model;
                ModelCombo.Text = settings.Models != null && settings.Models.TryGetValue(settings.SelectedProviderId ?? "", out model) ? model : "";

                ApiKeyBox.Clear();
                if (selected == null) KeyStateText.Visibility = Visibility.Collapsed;

                var cp = settings.CustomProvider;
                CustomNameBox.Text = cp != null ? cp.Name : "";
                CustomBaseUrlBox.Text = cp != null ? cp.BaseUrl : "";

                PrivacyLocalOnly.IsChecked = settings.Privacy == PrivacyMode.LocalOnly;
                PrivacyCloudAllowed.IsChecked = settings.Privacy == PrivacyMode.CloudAllowed;
                PrivacyAsk.IsChecked = settings.Privacy == PrivacyMode.AskBeforeSending;

                ThemeCombo.SelectedIndex = (int)settings.Theme;
                PreferLocalCheck.IsChecked = settings.PreferLocalWhenAvailable;
                MaxMessagesBox.Text = settings.HistoryMaxMessages.ToString();
                MaxDaysBox.Text = settings.HistoryMaxAgeDays.ToString();

                UpdateLocalStatusText();
            }
            finally
            {
                _loading = false;
            }
        }

        private AiGateway.AiGateway Gateway
        {
            get { return _controller != null ? _controller.Gateway : null; }
        }

        private void UpdateLocalStatusText()
        {
            var registry = _controller != null ? _controller.GatewayRegistry : null;
            if (registry == null) return;
            string ollama = registry.IsLocalAvailable("ollama") ? Localization.Strings.T("S.Settings.Available") : Localization.Strings.T("S.Settings.NotAvailable");
            string lm = registry.IsLocalAvailable("lmstudio") ? Localization.Strings.T("S.Settings.Available") : Localization.Strings.T("S.Settings.NotAvailable");
            LocalStatusText.Text = "Ollama (11434): " + ollama + "\nLM Studio (1234): " + lm;
        }

        private void UpdateProviderUi(ProviderInfo info)
        {
            if (info == null) return;

            bool needsKey = info.RequiresApiKey;
            bool hasKey = needsKey && SettingsManager.Instance.HasApiKey(info.Id);

            ApiKeyLabel.Visibility = needsKey ? Visibility.Visible : Visibility.Collapsed;
            ApiKeyBox.Visibility = needsKey ? Visibility.Visible : Visibility.Collapsed;

            if (needsKey)
            {
                KeyStateText.SetResourceReference(TextBlock.TextProperty, "S.Settings.ApiKeyStored");
                KeyStateText.Visibility = hasKey ? Visibility.Visible : Visibility.Collapsed;
            }
            else
            {
                KeyStateText.SetResourceReference(TextBlock.TextProperty, "S.Settings.NoApiKeyRequired");
                KeyStateText.Visibility = Visibility.Visible;
            }

            GetApiKeyButton.Visibility = needsKey && !string.IsNullOrWhiteSpace(info.ApiKeyUrl)
                ? Visibility.Visible : Visibility.Collapsed;
            ProviderDocsButton.Visibility = !string.IsNullOrWhiteSpace(info.DocumentationUrl)
                ? Visibility.Visible : Visibility.Collapsed;

            bool hasOfficialLink = GetApiKeyButton.Visibility == Visibility.Visible ||
                                   ProviderDocsButton.Visibility == Visibility.Visible;
            ProviderLinksPanel.Visibility = hasOfficialLink ? Visibility.Visible : Visibility.Collapsed;
            ProviderLinkNote.Visibility = hasOfficialLink ? Visibility.Visible : Visibility.Collapsed;
        }

        private static string BuildProviderSummary(ProviderInfo info)
        {
            if (info == null) return string.Empty;
            string access;
            switch (info.AccessProfile)
            {
                case ProviderAccessProfile.LocalNoCost:
                    access = "Access: Local / no cloud token charge.";
                    break;
                case ProviderAccessProfile.FreeTierAvailable:
                    access = "Access: Free tier/mode currently available; provider limits apply.";
                    break;
                case ProviderAccessProfile.FreeModelsAvailable:
                    access = "Access: Free models currently available; provider capacity/limits can change.";
                    break;
                case ProviderAccessProfile.CustomEndpoint:
                    access = "Access: Defined by your custom endpoint.";
                    break;
                case ProviderAccessProfile.AccountDependent:
                    access = "Access: Account/plan dependent; see the provider's current terms.";
                    break;
                default:
                    access = "Access: Unknown until provider/account details are checked.";
                    break;
            }

            string text = access;
            if (!string.IsNullOrWhiteSpace(info.AccessNotes)) text += "\n" + info.AccessNotes;
            if (!string.IsNullOrWhiteSpace(info.Notes)) text += "\n" + info.Notes;
            return text;
        }

        private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_loading) return;
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info == null) return;

            var settings = SettingsManager.Instance.Settings;
            settings.SelectedProviderId = info.Id;
            string model;
            ModelCombo.Text = settings.Models != null && settings.Models.TryGetValue(info.Id, out model) ? model : info.DefaultModel;

            ApiKeyBox.Clear();
            UpdateProviderUi(info);
            TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.ForegroundDim");
            TestResultText.Text = BuildProviderSummary(info);
        }

        private void OnGetApiKey(object sender, RoutedEventArgs e)
        {
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info == null || string.IsNullOrWhiteSpace(info.ApiKeyUrl)) return;
            OpenVerifiedOfficialUrl(info.ApiKeyUrl, info.Id, "API key page");
        }

        private void OnProviderDocs(object sender, RoutedEventArgs e)
        {
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info == null || string.IsNullOrWhiteSpace(info.DocumentationUrl)) return;
            OpenVerifiedOfficialUrl(info.DocumentationUrl, info.Id, "documentation");
        }

        private void OpenVerifiedOfficialUrl(string url, string providerId, string purpose)
        {
            try
            {
                Uri uri;
                if (!Uri.TryCreate(url, UriKind.Absolute, out uri) ||
                    !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
                    !AllowedOfficialHosts.Any(h => string.Equals(uri.Host, h, StringComparison.OrdinalIgnoreCase)))
                {
                    Logger.Error("ui", "Blocked non-official provider URL: " + url, null);
                    TestResultText.Text = "Blocked an unverified provider link. No page was opened.";
                    TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
                    return;
                }

                Process.Start(new ProcessStartInfo
                {
                    FileName = uri.AbsoluteUri,
                    UseShellExecute = true
                });
                Logger.Gateway("Opened verified official " + purpose + " for provider=" + providerId + " host=" + uri.Host);
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Failed to open official provider link", ex);
                TestResultText.Text = "Could not open the provider's official page: " + ex.Message;
                TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            }
        }

        private async void OnLoadModels(object sender, RoutedEventArgs e)
        {
            var gateway = Gateway;
            if (gateway == null) return;
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info == null) return;

            TestResultText.Text = "Loading models…";
            SaveProviderFields();
            try
            {
                var adapter = gateway.Registry.Get(info.Id);
                if (adapter == null) return;
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(25)))
                {
                    adapter.Configure(gateway.Router.BuildCredentials(info.Id));
                    var models = await adapter.ListModelsAsync(cts.Token);
                    if (models == null || models.Count == 0)
                    {
                        TestResultText.Text = "No models returned.";
                        return;
                    }
                    string current = ModelCombo.Text;
                    ModelCombo.ItemsSource = models.Take(300).ToList();
                    if (!string.IsNullOrEmpty(current) && models.Contains(current)) ModelCombo.Text = current;

                    TestResultText.Text = models.Count + " models loaded.";
                    if (info.AccessProfile == ProviderAccessProfile.FreeModelsAvailable)
                        TestResultText.Text += " Free options are prioritized at the top of the list.";
                    TestResultText.Text += "\n" + BuildProviderSummary(info);
                }
            }
            catch (OmnixException ex)
            {
                TestResultText.Text = Errors.ErrorPresenter.Format(ex);
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "LoadModels failed", ex);
                TestResultText.Text = "Loading models failed: " + ex.Message;
            }
        }

        private async void OnTestConnection(object sender, RoutedEventArgs e)
        {
            var gateway = Gateway;
            if (gateway == null) return;
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info == null) return;

            SaveProviderFields();
            TestButton.IsEnabled = false;
            TestResultText.Text = "Testing…";
            try
            {
                var adapter = gateway.Registry.Get(info.Id);
                if (adapter == null) return;
                adapter.Configure(gateway.Router.BuildCredentials(info.Id));
                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
                {
                    // Keep the first probe throwing so AUTH/NETWORK/PROVIDER errors remain categorized.
                    var models = await adapter.ListModelsAsync(cts.Token);
                    bool ok = models != null && models.Count > 0;

                    // Custom provider has one additional job: its TestConnection implementation
                    // performs the small Vision capability probe and persists the result. We call it
                    // only after the categorized model-list probe already succeeded.
                    if (ok && string.Equals(info.Id, "custom", StringComparison.OrdinalIgnoreCase))
                        ok = await adapter.TestConnectionAsync(cts.Token);

                    TestResultText.Text = ok ? Localization.Strings.T("S.Settings.TestOk")
                                             : Localization.Strings.T("S.Settings.TestFailed");
                    TestResultText.SetResourceReference(TextBlock.ForegroundProperty,
                        ok ? "B.Success" : "B.Danger");

                    if (ok && adapter.SupportsVisionNow())
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionSupported");
                    else if (ok && info.Vision == VisionSupport.DependsOnModel)
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionUnknown");
                    else if (ok)
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionNotSupported");

                    if (ok) TestResultText.Text += "\n" + BuildProviderSummary(info);
                }
            }
            catch (OmnixException ex)
            {
                TestResultText.Text = Errors.ErrorPresenter.Format(ex);
                TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            }
            catch (OperationCanceledException)
            {
                TestResultText.Text = Errors.ErrorPresenter.Format(OmnixException.Timeout(info.DisplayName + " connection test timed out."));
                TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "TestConnection failed", ex);
                TestResultText.Text = Localization.Strings.T("S.Settings.TestFailed") + " — " + ex.Message;
                TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            }
            finally
            {
                TestButton.IsEnabled = true;
            }
        }

        private async void OnProbeLocal(object sender, RoutedEventArgs e)
        {
            var gateway = Gateway;
            if (gateway == null) return;
            ProbeButton.IsEnabled = false;
            LocalStatusText.Text = "Probing local AI…";
            try { await gateway.ProbeLocalAsync(); } catch { }
            UpdateLocalStatusText();
            ProbeButton.IsEnabled = true;
        }

        private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
        {
            if (_loading) return;
            var item = ThemeCombo.SelectedItem as ComboBoxItem;
            if (item == null) return;
            var settings = SettingsManager.Instance.Settings;
            settings.Theme = (ThemeMode)ThemeCombo.SelectedIndex;
            SettingsManager.Instance.Save();
            Theming.ThemeManager.Instance.ApplyTo(ParentWorkspace());
        }

        private System.Windows.FrameworkElement ParentWorkspace()
        {
            DependencyObject d = this;
            while (d != null && !(d is WorkspaceView)) d = System.Windows.Media.VisualTreeHelper.GetParent(d);
            return d as WorkspaceView;
        }

        private void OnSave(object sender, RoutedEventArgs e)
        {
            SaveProviderFields();
            SaveGeneralFields();
            SettingsManager.Instance.Save();
            if (_controller != null) _controller.SaveSettingsFromUi();
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            if (info != null) UpdateProviderUi(info);
        }

        private void SaveProviderFields()
        {
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            var settings = SettingsManager.Instance.Settings;

            // Update the Custom fields before any API-key persistence so a Test/Load Models action
            // cannot save the new key while leaving an old Base URL on disk.
            if (settings.CustomProvider != null)
            {
                settings.CustomProvider.Name = CustomNameBox.Text.Trim();
                settings.CustomProvider.BaseUrl = CustomBaseUrlBox.Text.Trim();
            }

            if (info != null)
            {
                settings.SelectedProviderId = info.Id;
                settings.Models[info.Id] = ModelCombo.Text.Trim();

                string key = ApiKeyBox.Password;
                if (info.RequiresApiKey && !string.IsNullOrWhiteSpace(key))
                    SettingsManager.Instance.SetApiKey(info.Id, key.Trim());
            }

            // Persist provider/model/custom endpoint changes even when the user did not enter a new
            // API key (important for local/no-auth Custom endpoints and Load Models/Test Connection).
            SettingsManager.Instance.Save();
        }

        private void SaveGeneralFields()
        {
            var settings = SettingsManager.Instance.Settings;

            if (PrivacyLocalOnly.IsChecked == true) settings.Privacy = PrivacyMode.LocalOnly;
            else if (PrivacyCloudAllowed.IsChecked == true) settings.Privacy = PrivacyMode.CloudAllowed;
            else settings.Privacy = PrivacyMode.AskBeforeSending;

            settings.PreferLocalWhenAvailable = PreferLocalCheck.IsChecked == true;

            int msgs, days;
            settings.HistoryMaxMessages = int.TryParse(MaxMessagesBox.Text, out msgs) ? Math.Max(10, msgs) : 500;
            settings.HistoryMaxAgeDays = int.TryParse(MaxDaysBox.Text, out days) ? Math.Max(1, days) : 30;

            var gateway = Gateway;
            if (gateway != null) gateway.Privacy.ResetSession();
        }
    }
}
