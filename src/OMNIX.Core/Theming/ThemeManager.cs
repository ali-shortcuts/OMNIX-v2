using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;

namespace OMNIX.Core.Theming
{
    /// <summary>
    /// Light / Dark / System theme manager. System follows the Windows "Apps use light/dark"
    /// personalization setting (polled with a lightweight timer — no extra framework dependency).
    /// Theme dictionaries are attached per view (never to Application.Current) so OMNIX cannot
    /// clash with other WPF-based add-ins inside the same Office process.
    /// </summary>
    public sealed class ThemeManager
    {
        private static readonly ThemeManager _instance = new ThemeManager();
        public static ThemeManager Instance { get { return _instance; } }

        private System.Windows.Threading.DispatcherTimer _pollTimer;

        public event Action ThemeChanged;

        public bool IsDarkEffective
        {
            get
            {
                var mode = SettingsManager.Instance.Settings.Theme;
                if (mode == ThemeMode.Dark) return true;
                if (mode == ThemeMode.Light) return false;
                return WindowsPrefersDark();
            }
        }

        public static bool WindowsPrefersDark()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    if (key != null)
                    {
                        object v = key.GetValue("AppsUseLightTheme");
                        if (v is int) return ((int)v) == 0;
                    }
                }
            }
            catch { }
            return false;
        }

        /// <summary>Loads the correct theme dictionary into the given view (per-view merged dictionaries).</summary>
        public void ApplyTo(FrameworkElement view)
        {
            if (view == null) return;
            EnsurePolling();

            bool dark = IsDarkEffective;
            string uri = dark
                ? "pack://application:,,,/OMNIX.Core;component/Theming/Themes/Dark.xaml"
                : "pack://application:,,,/OMNIX.Core;component/Theming/Themes/Light.xaml";

            try
            {
                var dict = new ResourceDictionary { Source = new Uri(uri) };
                // Replace existing OMNIX theme dictionaries but keep user content (Strings merged separately).
                for (int i = view.Resources.MergedDictionaries.Count - 1; i >= 0; i--)
                {
                    var md = view.Resources.MergedDictionaries[i];
                    if (md.Source != null && (md.Source.OriginalString.Contains("/Theming/Themes/")))
                        view.Resources.MergedDictionaries.RemoveAt(i);
                }
                view.Resources.MergedDictionaries.Add(dict);
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Failed to apply theme " + uri, ex);
            }
        }

        public void NotifySettingsChanged()
        {
            var handler = ThemeChanged;
            if (handler != null) handler();
        }

        private void EnsurePolling()
        {
            if (_pollTimer != null) return;
            _pollTimer = new System.Windows.Threading.DispatcherTimer();
            _pollTimer.Interval = TimeSpan.FromSeconds(5);
            _pollTimer.Tick += delegate
            {
                if (SettingsManager.Instance.Settings.Theme != ThemeMode.System) return;
                var handler = ThemeChanged;
                if (handler != null) handler();
            };
            _pollTimer.Start();
        }
    }
}
