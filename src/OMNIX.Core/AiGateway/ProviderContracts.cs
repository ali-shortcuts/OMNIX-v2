using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Errors;

namespace OMNIX.Core.AiGateway
{
    public enum ProviderKind
    {
        Local,
        Cloud
    }

    public enum VisionSupport
    {
        No,
        Yes,
        DependsOnModel
    }

    /// <summary>
    /// Cost/access metadata is informational only. Unknown is deliberately zero/default so a
    /// provider can never be mislabeled as free merely because metadata was not initialized.
    /// </summary>
    public enum ProviderAccessProfile
    {
        Unknown = 0,
        LocalNoCost = 1,
        FreeTierAvailable = 2,
        FreeModelsAvailable = 3,
        AccountDependent = 4,
        CustomEndpoint = 5,
        FreeCreditsAvailable = 6
    }

    public sealed class ProviderInfo
    {
        public string Id { get; set; }
        public string DisplayName { get; set; }
        public ProviderKind Kind { get; set; }
        public VisionSupport Vision { get; set; }
        public string DefaultModel { get; set; }
        public bool RequiresApiKey { get; set; }
        public string Notes { get; set; }
        public ProviderAccessProfile AccessProfile { get; set; }
        public string AccessNotes { get; set; }
        public string OfficialWebsiteUrl { get; set; }
        public string DocumentationUrl { get; set; }
        public string ApiKeyUrl { get; set; }

        /// <summary>
        /// UTC calendar date when OMNIX maintainers last checked AccessProfile/AccessNotes against
        /// an official provider page. This is deliberately visible in Settings because cloud
        /// pricing/free-tier rules can change without an OMNIX binary update.
        /// </summary>
        public string AccessVerifiedUtc { get; set; }

        /// <summary>Official source used for the current access/free-tier classification.</summary>
        public string AccessVerificationUrl { get; set; }
    }

    public interface IProviderAdapter
    {
        ProviderInfo Info { get; }
        void Configure(ProviderCredentials credentials);
        Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct);
        Task<bool> TestConnectionAsync(CancellationToken ct);
        Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct);
        bool SupportsVisionNow();
    }

    public static class HttpStatusMapper
    {
        public static OmnixException Map(int statusCode, string body, string providerName)
        {
            string trimmed = body ?? "";
            if (trimmed.Length > 800) trimmed = trimmed.Substring(0, 800);

            if (string.Equals(providerName, "OpenRouter", StringComparison.OrdinalIgnoreCase) &&
                (trimmed.IndexOf("No endpoints available matching your guardrail restrictions and data policy", StringComparison.OrdinalIgnoreCase) >= 0 ||
                 trimmed.IndexOf("openrouter.ai/settings/privacy", StringComparison.OrdinalIgnoreCase) >= 0))
            {
                return OmnixException.PrivacyBlocked(
                    "OpenRouter could not route this request under the account's current guardrail/privacy data policy. HTTP " +
                    statusCode + ". Body: " + trimmed);
            }

            switch (statusCode)
            {
                case 401:
                case 403:
                    return OmnixException.Auth(providerName + " returned HTTP " + statusCode + ". Body: " + trimmed);
                case 404:
                    return OmnixException.Model(providerName + " returned HTTP 404 (model or endpoint not found). Body: " + trimmed);
                case 408:
                    return OmnixException.Timeout(providerName + " returned HTTP 408.");
                case 429:
                    return OmnixException.Provider(providerName + " returned HTTP 429 — rate limit / quota reached. Body: " + trimmed);
                default:
                    return OmnixException.Provider(providerName + " returned HTTP " + statusCode + ". Body: " + trimmed);
            }
        }
    }
}
