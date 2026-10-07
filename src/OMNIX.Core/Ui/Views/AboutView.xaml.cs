using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Reflection;
using System.IO;
using System.Threading.Tasks;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;
using Newtonsoft.Json;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// About page — fixed content mandated by spec Section 8. Exact links, exact text.
    /// Every row is one clickable element: Process.Start with UseShellExecute=true.
    /// Icons are official brand vectors (Simple Icons, CC0) embedded in the assembly —
    /// no internet needed to display them.
    /// </summary>
    public partial class AboutView : UserControl
    {
        public AboutView()
        {
            InitializeComponent();
            try
            {
                Version v = Assembly.GetExecutingAssembly().GetName().Version;
                VersionText.Text = "v" + v.ToString(3);
            }
            catch { }
            DiagnosticsButton.Content = SettingsManager.Instance.Settings.UiLanguage == "fa" ? "گزارش تشخیص" : "Diagnostic report";
        }

        private async void ExportDiagnostics(object sender, RoutedEventArgs e)
        {
            try { await OfficeUi.RunAsync(Dispatcher, ExportDiagnosticsCore); }
            catch { DiagnosticsStatus.Text = "Report export failed."; DiagnosticsButton.IsEnabled = true; }
        }

        private async Task ExportDiagnosticsCore()
        {
            bool fa = SettingsManager.Instance.Settings.UiLanguage == "fa";
            var dialog = new Microsoft.Win32.SaveFileDialog {
                Filter = "Diagnostic report (*.json)|*.json", DefaultExt = ".json", AddExtension = true,
                FileName = "OMNIX-diagnostics-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json"
            };
            if (dialog.ShowDialog() != true) return;
            DiagnosticsButton.IsEnabled = false;
            DiagnosticsStatus.Text = fa ? "در حال ساخت گزارش…" : "Preparing report…";
            try
            {
                string destination = dialog.FileName;
                int requests = await Task.Run(() => {
                    var report = DiagnosticReport.Collect();
                    string temp = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try {
                        File.WriteAllText(temp, report.ToString(Formatting.Indented), new System.Text.UTF8Encoding(false));
                        if (File.Exists(destination)) File.Replace(temp, destination, null);
                        else File.Move(temp, destination);
                    } finally { if (File.Exists(temp)) File.Delete(temp); }
                    return ((Newtonsoft.Json.Linq.JArray)report["requests"]).Count;
                });
                DiagnosticsStatus.Text = fa ? "گزارش ذخیره شد؛ " + requests + " مسیر اجرا." : "Report saved: " + requests + " traces.";
            }
            catch (Exception ex)
            {
                // Do not show or log exception messages containing personal destination paths.
                DiagnosticsStatus.Text = (fa ? "ذخیرهٔ گزارش ناموفق: " : "Report export failed: ") + ex.GetType().Name;
            }
            finally { DiagnosticsButton.IsEnabled = true; }
        }

        private static void Open(string url)
        {
            Util.ProcessLauncher.Open(url);
        }

        private void Open_Email(object sender, MouseButtonEventArgs e) { Open("mailto:Ali.hekmati2026@gmail.com"); }
        private void Open_Telegram(object sender, MouseButtonEventArgs e) { Open("https://t.me/Ali_silent0"); }
        private void Open_TelegramChannel(object sender, MouseButtonEventArgs e) { Open("https://t.me/Ali_shortcuts"); }
        private void Open_Facebook(object sender, MouseButtonEventArgs e) { Open("https://www.facebook.com/AliShortcuts"); }
        private void Open_TikTok(object sender, MouseButtonEventArgs e) { Open("https://www.tiktok.com/@ali_shortcuts"); }
        private void Open_Instagram(object sender, MouseButtonEventArgs e) { Open("https://www.instagram.com/ali_shortcuts"); }
        private void Open_YouTube(object sender, MouseButtonEventArgs e) { Open("https://www.youtube.com/@Ali_Shortcuts"); }
    }
}
