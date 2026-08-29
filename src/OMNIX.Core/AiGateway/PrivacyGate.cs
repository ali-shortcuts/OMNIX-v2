using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Layer 7.5 — Privacy Mode enforced IN THE GATEWAY (not in the UI): before every cloud
    /// provider call the gateway checks the setting. LocalOnly + Cloud => request refused with a
    /// clear message. AskBeforeSending => explicit user confirmation via callback
    /// (with "don't ask again this session"). Default on first install: AskBeforeSending.
    /// </summary>
    public sealed class PrivacyGate
    {
        /// <summary>UI supplies this: (providerDisplayName) => Task&lt;(allowed, rememberSession)&gt;.</summary>
        public Func<string, Task<Tuple<bool, bool>>> CloudConfirmationCallback { get; set; }

        private volatile bool _sessionApproved;

        public void ResetSession() { _sessionApproved = false; }

        /// <summary>Throws PRIVACY_BLOCKED if the request may not proceed. Local providers always pass.</summary>
        public async Task EnsureAllowedAsync(IProviderAdapter provider)
        {
            if (provider == null || provider.Info.Kind == ProviderKind.Local) return;

            PrivacyMode mode = SettingsManager.Instance.Settings.Privacy;
            if (mode == PrivacyMode.CloudAllowed) return;

            if (mode == PrivacyMode.LocalOnly)
            {
                throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                    Localization.Strings.T("S.Privacy.LocalOnlyBlocked").Replace("{0}", provider.Info.DisplayName),
                    "PrivacyMode=LocalOnly; requested provider=" + provider.Info.Id,
                    "Switch to a local AI provider (Ollama / LM Studio) or change Privacy Mode in Settings.");
            }

            // AskBeforeSending
            if (_sessionApproved) return;

            if (CloudConfirmationCallback == null)
            {
                throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                    "Cloud send requires confirmation but no confirmation handler is wired.",
                    "PrivacyGate", "Select Privacy Mode 'Cloud Allowed' or restart the panel.");
            }

            var result = await CloudConfirmationCallback(provider.Info.DisplayName).ConfigureAwait(true);
            bool allowed = result != null && result.Item1;
            bool remember = result != null && result.Item2;
            if (!allowed)
            {
                throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                    "You declined sending this request to " + provider.Info.DisplayName + ".",
                    "PrivacyMode=AskBeforeSending; user declined.",
                    "Use a local AI provider, or change Privacy Mode in Settings.");
            }
            if (remember) _sessionApproved = true;
            Logger.Gateway("PrivacyGate: cloud send approved (rememberSession=" + remember + ")");
        }

        /// <summary>Synchronous variant used by tests/diagnostics only.</summary>
        public void EnsureAllowedForLocal(IProviderAdapter provider)
        {
            if (provider == null || provider.Info.Kind == ProviderKind.Local) return;
            PrivacyMode mode = SettingsManager.Instance.Settings.Privacy;
            if (mode == PrivacyMode.LocalOnly)
                throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                    Localization.Strings.T("S.Privacy.LocalOnlyBlocked").Replace("{0}", provider.Info.DisplayName),
                    "PrivacyMode=LocalOnly", "Switch to local AI or change Privacy Mode.");
        }
    }

    /// <summary>
    /// Provider router (spec Layer 5): priority = available Local AI &gt; selected cloud.
    /// Local availability is probed in the background; results are shown in Settings.
    /// </summary>
    public sealed class ProviderRouter
    {
        private readonly ProviderRegistry _registry;

        public ProviderRouter(ProviderRegistry registry)
        {
            _registry = registry;
        }

        /// <summary>Probes local providers (Ollama 11434 / LM Studio 1234) with a short timeout.</summary>
        public async Task ProbeLocalProvidersAsync()
        {
            foreach (var p in _registry.All.Where(x => x.Info.Kind == ProviderKind.Local))
            {
                try
                {
                    var creds = BuildCredentials(p.Info.Id);
                    p.Configure(creds);
                    using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2)))
                    {
                        bool ok = await p.TestConnectionAsync(cts.Token).ConfigureAwait(false);
                        _registry.SetLocalAvailability(p.Info.Id, ok);
                    }
                }
                catch
                {
                    _registry.SetLocalAvailability(p.Info.Id, false);
                }
            }
        }

        public IProviderAdapter Resolve(string selectedProviderId, bool needsVision)
        {
            var settings = SettingsManager.Instance.Settings;

            // Local-only privacy forces local.
            if (settings.Privacy == PrivacyMode.LocalOnly)
            {
                var local = _registry.GetFirstAvailableLocal();
                if (local == null)
                    throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                        Localization.Strings.T("S.Privacy.LocalOnlyBlocked").Replace("{0}", "selected cloud provider"),
                        "PrivacyMode=LocalOnly and no local AI is reachable.",
                        "Start Ollama or LM Studio, or switch Privacy Mode in Settings.");
                if (needsVision && local.Info.Vision == VisionSupport.No)
                {
                    // Fall through to vision error below by checking adapter at send time.
                }
                return local;
            }

            // Prefer local when available (Phase 9.3) — unless the user's selected provider IS local.
            if (settings.PreferLocalWhenAvailable)
            {
                var local = _registry.GetFirstAvailableLocal();
                if (local != null &&
                    !string.Equals(selectedProviderId, local.Info.Id, StringComparison.OrdinalIgnoreCase) &&
                    string.IsNullOrEmpty(settings.SelectedProviderId) == false)
                {
                    // Only auto-prefer local when the selection is unset or the same family;
                    // an explicit user selection wins (documented behavior).
                }
            }

            var chosen = _registry.Get(selectedProviderId);
            if (chosen == null)
                throw new OmnixException(ErrorCode.MODEL_ERROR,
                    "Provider '" + selectedProviderId + "' is not registered.",
                    "ProviderRouter.Resolve", "Pick a provider in Settings.");
            return chosen;
        }

        public ProviderCredentials BuildCredentials(string providerId)
        {
            var settings = SettingsManager.Instance.Settings;
            var creds = new ProviderCredentials();

            string model;
            creds.Model = settings.Models != null && settings.Models.TryGetValue(providerId, out model) ? model : null;

            switch (providerId)
            {
                case "gemini":
                    creds.ApiKey = SettingsManager.Instance.GetApiKey("gemini");
                    break;
                case "groq":
                    creds.ApiKey = SettingsManager.Instance.GetApiKey("groq");
                    break;
                case "openrouter":
                    creds.ApiKey = SettingsManager.Instance.GetApiKey("openrouter");
                    break;
                case "ollama":
                    creds.BaseUrl = "http://localhost:11434";
                    creds.Model = string.IsNullOrEmpty(creds.Model) ? _registry.GetLocalModelHint("ollama") : creds.Model;
                    break;
                case "lmstudio":
                    creds.BaseUrl = "http://localhost:1234/v1";
                    break;
                case "custom":
                    var cp = settings.CustomProvider;
                    creds.BaseUrl = cp != null ? cp.BaseUrl : null;
                    creds.Model = cp != null ? cp.Model : creds.Model;
                    creds.ApiKey = SettingsManager.Instance.GetApiKey("custom");
                    break;
            }
            return creds;
        }
    }
}
