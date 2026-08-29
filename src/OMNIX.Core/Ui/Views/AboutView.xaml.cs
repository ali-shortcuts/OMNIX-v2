using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Reflection;

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
        }

        private static void Open(string url)
        {
            Util.ProcessLauncher.Open(url);
        }

        private void Open_Email(object sender, MouseButtonEventArgs e) { Open("mailto:Ali.hekmati2026@gmail.com"); }
        private void Open_Telegram(object sender, MouseButtonEventArgs e) { Open("https://t.me/Mr_Ali_2025"); }
        private void Open_TelegramChannel(object sender, MouseButtonEventArgs e) { Open("https://t.me/Ali_shortcuts"); }
        private void Open_Facebook(object sender, MouseButtonEventArgs e) { Open("https://www.facebook.com/AliShortcuts"); }
        private void Open_TikTok(object sender, MouseButtonEventArgs e) { Open("https://www.tiktok.com/@ali_shortcuts"); }
        private void Open_Instagram(object sender, MouseButtonEventArgs e) { Open("https://www.instagram.com/ali_shortcuts"); }
        private void Open_YouTube(object sender, MouseButtonEventArgs e) { Open("https://www.youtube.com/@Ali_Shortcuts"); }
    }
}
