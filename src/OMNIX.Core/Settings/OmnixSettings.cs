using System;
using System.Collections.Generic;

namespace OMNIX.Core.Settings
{
    /// <summary>Layer 7.5 privacy modes. Default on first install: AskBeforeSending (most conservative).</summary>
    public enum PrivacyMode
    {
        LocalOnly = 0,
        CloudAllowed = 1,
        AskBeforeSending = 2
    }

    public enum ThemeMode
    {
        System = 0,
        Light = 1,
        Dark = 2
    }

    public sealed class CustomProviderConfig
    {
        public string Name { get; set; }
        public string BaseUrl { get; set; }
        public string Model { get; set; }
        /// <summary>Result of the automatic Vision probe performed by Test Connection (null = unknown).</summary>
        public bool? SupportsVision { get; set; }
    }

    /// <summary>
    /// POCO settings. API keys are NEVER stored here in plain text — SettingsManager keeps them
    /// DPAPI-protected in a separate dictionary (Ironclad Rule 6).
    /// </summary>
    public sealed class OmnixSettings
    {
        public int SchemaVersion { get; set; }

        public PrivacyMode Privacy { get; set; }
        public ThemeMode Theme { get; set; }
        public string UiLanguage { get; set; }

        /// <summary>Id of the provider the user selected in Settings.</summary>
        public string SelectedProviderId { get; set; }

        /// <summary>Preferred local provider when Local AI is available (ollama / lmstudio).</summary>
        public string PreferredLocalProviderId { get; set; }

        /// <summary>Model per provider id (model names are NOT secrets).</summary>
        public Dictionary<string, string> Models { get; set; }

        public CustomProviderConfig CustomProvider { get; set; }

        /// <summary>Chat history cap (Layer 8): never grow unbounded.</summary>
        public int HistoryMaxMessages { get; set; }
        public int HistoryMaxAgeDays { get; set; }

        /// <summary>Context Limiter caps (Layer 4).</summary>
        public int ContextMaxCells { get; set; }
        public int ContextMaxChars { get; set; }
        public int ContextMaxTokens { get; set; }

        public bool PreferLocalWhenAvailable { get; set; }

        public static OmnixSettings CreateDefaults()
        {
            var s = new OmnixSettings();
            s.SchemaVersion = 1;
            s.Privacy = PrivacyMode.AskBeforeSending;   // spec Layer 7.5: conservative default
            s.Theme = ThemeMode.System;                  // user decision
            s.UiLanguage = "en";                         // spec 10.7: English default
            s.SelectedProviderId = "gemini";
            s.PreferredLocalProviderId = "ollama";
            s.Models = new Dictionary<string, string>
            {
                { "gemini", "gemini-2.0-flash" },
                { "groq", "llama-3.3-70b-versatile" },
                { "openrouter", "openrouter/auto" },
                { "ollama", "" },
                { "lmstudio", "" },
                { "custom", "gpt-4o-mini" }
            };
            s.CustomProvider = new CustomProviderConfig
            {
                Name = "My Endpoint",
                BaseUrl = "http://localhost:8080/v1",
                Model = "gpt-4o-mini"
            };
            s.HistoryMaxMessages = 500;
            s.HistoryMaxAgeDays = 30;
            s.ContextMaxCells = 2000;
            s.ContextMaxChars = 6000;
            s.ContextMaxTokens = 3000;
            s.PreferLocalWhenAvailable = true;
            return s;
        }
    }
}
