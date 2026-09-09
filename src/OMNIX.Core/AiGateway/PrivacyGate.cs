using System;
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
    /// clear message. AskBeforeSending => explicit user confirmation via callback.
    /// </summary>
    public sealed class PrivacyGate
    {
        public Func<string, Task<Tuple<bool, bool>>> CloudConfirmationCallback { get; set; }
        private volatile bool _sessionApproved;

        public void ResetSession() { _sessionApproved = false; }

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
                    "Switch to a local AI provider (Ollama / LM Studio / loopback Custom) or change Privacy Mode in Settings.");
            }

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

    public sealed class ProviderRouter
    {
        private readonly ProviderRegistry _registry;

        public ProviderRouter(ProviderRegistry registry)
        {
            _registry = registry;
        }

        public async Task ProbeLocalProvidersAsync()
        {
            foreach (var p in _registry.All.Where(x =>
                string.Equals(x.Info.Id, "ollama", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(x.Info.Id, "lmstudio", StringComparison.OrdinalIgnoreCase)))
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

            if (settings.Privacy == PrivacyMode.LocalOnly)
            {
                var selectedCustomLocal = ResolveSelectedLoopbackCustom(selectedProviderId, needsVision);
                if (selectedCustomLocal != null) return selectedCustomLocal;

                var local = ResolveAvailableLocal(settings.PreferredLocalProviderId, needsVision);
                if (local != null) return local;

                if (needsVision && AnyLocalAvailable())
                {
                    throw new OmnixException(ErrorCode.MODEL_ERROR,
                        "Privacy Mode is Local Only, but no available local model is currently Vision-capable.",
                        "ProviderRouter.Resolve: local providers are reachable, needsVision=true, none reports vision support.",
                        "Load a multimodal local model in Ollama/LM Studio, test a Vision-capable loopback Custom endpoint, or use text-only context.");
                }

                throw new OmnixException(ErrorCode.PRIVACY_BLOCKED,
                    Localization.Strings.T("S.Privacy.LocalOnlyBlocked").Replace("{0}", "selected cloud provider"),
                    "PrivacyMode=LocalOnly and no compatible local AI is reachable.",
                    "Start Ollama or LM Studio, configure a localhost Custom endpoint, or switch Privacy Mode in Settings.");
            }

            if (settings.PreferLocalWhenAvailable)
            {
                var local = ResolveAvailableLocal(settings.PreferredLocalProviderId, needsVision);
                if (local != null)
                {
                    Logger.Gateway("ProviderRouter: using available local provider '" + local.Info.Id +
                                   "' because PreferLocalWhenAvailable=true (needsVision=" + needsVision + ").");
                    return local;
                }
            }

            var chosen = _registry.Get(selectedProviderId);
            if (chosen == null)
                throw new OmnixException(ErrorCode.MODEL_ERROR,
                    "Provider '" + selectedProviderId + "' is not registered.",
                    "ProviderRouter.Resolve", "Pick a provider in Settings.");
            return chosen;
        }

        private IProviderAdapter ResolveSelectedLoopbackCustom(string selectedProviderId, bool needsVision)
        {
            if (!string.Equals(selectedProviderId, "custom", StringComparison.OrdinalIgnoreCase)) return null;

            var settings = SettingsManager.Instance.Settings;
            var cp = settings.CustomProvider;
            if (cp == null || string.IsNullOrWhiteSpace(cp.BaseUrl)) return null;

            Uri uri;
            if (!Uri.TryCreate(cp.BaseUrl, UriKind.Absolute, out uri) ||
                !(uri.IsLoopback || string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase)))
                return null;

            var custom = _registry.Get("custom");
            if (custom == null) return null;
            custom.Configure(BuildCredentials("custom"));

            if (needsVision && !custom.SupportsVisionNow())
                throw new OmnixException(ErrorCode.MODEL_ERROR,
                    "The selected localhost Custom provider has not been verified as Vision-capable.",
                    "ProviderRouter.Resolve: custom loopback endpoint selected; needsVision=true; SupportsVisionNow=false.",
                    "Use Test Connection in Settings to probe Vision support, choose a multimodal local model, or send text-only context.");

            Logger.Gateway("ProviderRouter: LocalOnly accepted selected loopback Custom endpoint.");
            return custom;
        }

        private IProviderAdapter ResolveAvailableLocal(string preferredId, bool needsVision)
        {
            IProviderAdapter preferred = _registry.Get(preferredId);
            if (IsCompatibleAvailableLocal(preferred, needsVision)) return preferred;

            foreach (var candidate in _registry.All.Where(x => x.Info.Kind == ProviderKind.Local))
            {
                if (preferred != null && string.Equals(candidate.Info.Id, preferred.Info.Id, StringComparison.OrdinalIgnoreCase))
                    continue;
                if (IsCompatibleAvailableLocal(candidate, needsVision)) return candidate;
            }
            return null;
        }

        private bool IsCompatibleAvailableLocal(IProviderAdapter provider, bool needsVision)
        {
            if (provider == null || provider.Info.Kind != ProviderKind.Local) return false;
            if (!_registry.IsLocalAvailable(provider.Info.Id)) return false;
            if (!needsVision) return true;

            try
            {
                provider.Configure(BuildCredentials(provider.Info.Id));
                return provider.SupportsVisionNow();
            }
            catch
            {
                return false;
            }
        }

        private bool AnyLocalAvailable()
        {
            foreach (var p in _registry.All.Where(x => x.Info.Kind == ProviderKind.Local))
                if (_registry.IsLocalAvailable(p.Info.Id)) return true;
            return false;
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
                case "groq":
                case "openrouter":
                case "mistral":
                case "huggingface":
                case "cerebras":
                    creds.ApiKey = SettingsManager.Instance.GetApiKey(providerId);
                    break;
                case "ollama":
                    creds.BaseUrl = "http://localhost:11434";
                    creds.Model = string.IsNullOrEmpty(creds.Model) ? _registry.GetLocalModelHint("ollama") : creds.Model;
                    break;
                case "lmstudio":
                    creds.BaseUrl = "http://localhost:1234/v1";
                    if (string.IsNullOrEmpty(creds.Model)) creds.Model = _registry.GetLocalModelHint("lmstudio");
                    break;
                case "custom":
                    var cp = settings.CustomProvider;
                    creds.BaseUrl = cp != null ? cp.BaseUrl : null;
                    if (string.IsNullOrWhiteSpace(creds.Model))
                        creds.Model = cp != null ? cp.Model : null;
                    creds.ApiKey = SettingsManager.Instance.GetApiKey("custom");
                    break;
            }
            return creds;
        }
    }
}
