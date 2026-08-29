using System;
using System.IO;
using System.Windows;
using OMNIX.Core.Logging;

namespace OMNIX.Core.Localization
{
    /// <summary>
    /// Spec 10.7: UI strings live in a central Resource Dictionary (Localization/Strings.xaml),
    /// never hard-coded in XAML or C#. English is the default; the architecture is ready for a
    /// future Persian (RTL) dictionary swap without touching any view.
    /// </summary>
    public static class Strings
    {
        private static ResourceDictionary _dict;
        private static readonly object Gate = new object();

        public static ResourceDictionary Dictionary
        {
            get
            {
                if (_dict == null)
                {
                    lock (Gate)
                    {
                        if (_dict == null)
                        {
                            _dict = new ResourceDictionary();
                            string lang = Settings.SettingsManager.Instance.Settings.UiLanguage ?? "en";
                            // Future: switch on lang to load Strings.fa.xaml (RTL ready).
                            string uri = "pack://application:,,,/OMNIX.Core;component/Localization/Strings.xaml";
                            try
                            {
                                var loaded = new ResourceDictionary { Source = new Uri(uri) };
                                _dict = loaded;
                            }
                            catch (Exception ex)
                            {
                                Logger.Error("ui", "Failed to load Strings.xaml", ex);
                            }
                        }
                    }
                }
                return _dict;
            }
        }

        /// <summary>Translate a key; falls back to the key itself when missing (honest diagnostics).</summary>
        public static string T(string key)
        {
            try
            {
                if (Dictionary.Contains(key)) return Dictionary[key] as string;
            }
            catch { }
            return key;
        }
    }
}
