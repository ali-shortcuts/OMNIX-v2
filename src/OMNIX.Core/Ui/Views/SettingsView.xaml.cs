using System;
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
    /// Settings page: provider dropdown, API key (DPAPI-encrypted on save), model list loading,
    /// real Test Connection, local AI probing (Ollama 11434 / LM Studio 1234), Privacy Mode,
    /// appearance and history limits (spec Phases 7–10).
    /// </summary>
    public partial class SettingsView : UserControl
    {
        private WorkspaceController _controller;
        private bool _loading;

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
                if (selected != null) ProviderCombo.SelectedItem = selected.Info;

                string model;
                ModelCombo.Text = settings.Models != null && settings.Models.TryGetValue(settings.SelectedProviderId ?? "", out model) ? model : "";

                ApiKeyBox.Clear();
                bool hasKey = SettingsManager.Instance.HasApiKey(settings.SelectedProviderId);
                KeyStateText.Visibility = hasKey ? Visibility.Visible : Visibility.Collapsed;

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

        // ------------------------------------------------------------- handlers

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
            KeyStateText.Visibility = SettingsManager.Instance.HasApiKey(info.Id) ? Visibility.Visible : Visibility.Collapsed;
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
                    ModelCombo.ItemsSource = models.Take(200).ToList();
                    if (!string.IsNullOrEmpty(current) && models.Contains(current)) ModelCombo.Text = current;
                    TestResultText.Text = models.Count + " models loaded.";
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
                    bool ok = await adapter.TestConnectionAsync(cts.Token);
                    TestResultText.Text = ok ? Localization.Strings.T("S.Settings.TestOk") + (info.RequiresApiKey ? "" : "")
                                             : Localization.Strings.T("S.Settings.TestFailed");
                    TestResultText.SetResourceReference(TextBlock.ForegroundProperty,
                        ok ? "B.Success" : "B.Danger");

                    if (ok && adapter.SupportsVisionNow())
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionSupported");
                    else if (ok && info.Vision == VisionSupport.DependsOnModel)
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionUnknown");
                    else if (ok)
                        TestResultText.Text += "\n" + Localization.Strings.T("S.Settings.VisionNotSupported");
                }
            }
            catch (OmnixException ex)
            {
                TestResultText.Text = Errors.ErrorPresenter.Format(ex);
                TestResultText.SetResourceReference(TextBlock.ForegroundProperty, "B.Danger");
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "TestConnection failed", ex);
                TestResultText.Text = Localization.Strings.T("S.Settings.TestFailed") + " — " + ex.Message;
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
            try
            {
                await gateway.ProbeLocalAsync();
            }
            catch { }
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
            KeyStateText.Visibility = Visibility.Visible;
        }

        private void SaveProviderFields()
        {
            var info = ProviderCombo.SelectedItem as ProviderInfo;
            var settings = SettingsManager.Instance.Settings;
            if (info != null)
            {
                settings.SelectedProviderId = info.Id;
                settings.Models[info.Id] = ModelCombo.Text.Trim();

                string key = ApiKeyBox.Password;
                if (!string.IsNullOrWhiteSpace(key))
                    SettingsManager.Instance.SetApiKey(info.Id, key.Trim());
            }

            if (settings.CustomProvider != null)
            {
                settings.CustomProvider.Name = CustomNameBox.Text.Trim();
                settings.CustomProvider.BaseUrl = CustomBaseUrlBox.Text.Trim();
            }
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
