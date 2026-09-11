using System;
using System.Threading.Tasks;

namespace OMNIX.Core.Ai
{
    public enum PrivacyMode
    {
        LocalOnly,
        CloudAllowed,
        AskBeforeSending
    }

    public sealed class CloudConsentResult
    {
        public bool Allowed { get; set; }
        public bool RememberForSession { get; set; }
    }

    public sealed class PrivacyGate
    {
        private bool _sessionCloudApproved;

        public PrivacyMode Mode { get; set; } = PrivacyMode.AskBeforeSending;
        public Func<ProviderDescriptor, Task<CloudConsentResult>> RequestCloudConsentAsync { get; set; }

        public void ResetSessionConsent() => _sessionCloudApproved = false;

        public async Task EnsureAllowedAsync(ProviderDescriptor provider)
        {
            if (provider == null) throw new ArgumentNullException(nameof(provider));
            if (provider.Kind == ProviderKind.Local) return;

            if (Mode == PrivacyMode.LocalOnly)
                throw new InvalidOperationException("Cloud provider blocked by Local Only privacy mode.");

            if (Mode == PrivacyMode.CloudAllowed || _sessionCloudApproved) return;

            if (RequestCloudConsentAsync == null)
                throw new InvalidOperationException("Cloud send requires explicit confirmation but no confirmation handler is available.");

            CloudConsentResult result = await RequestCloudConsentAsync(provider).ConfigureAwait(true);
            if (result == null || !result.Allowed)
                throw new InvalidOperationException("The cloud send was cancelled before provider execution.");

            if (result.RememberForSession) _sessionCloudApproved = true;
        }
    }
}
