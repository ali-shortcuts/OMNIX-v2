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
    /// Cost/access metadata is informational only. OMNIX never assumes that a cloud request is
    /// permanently free because quotas, regions and provider policies can change.
    /// </summary>
    public enum ProviderAccessProfile
    {
        LocalNoCost,
        FreeTierAvailable,
        FreeModelsAvailable,
        AccountDependent,
        CustomEndpoint
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

        /// <summary>
        /// Official provider-owned HTTPS pages only. These are product metadata, not user input.
        /// Settings uses ApiKeyUrl for the optional "Get API Key" action and still validates
        /// the scheme/host before opening the user's default browser.
        /// </summary>
        public string OfficialWebsiteUrl { get; set; }
        public string DocumentationUrl { get; set; }
        public string ApiKeyUrl { get; set; }
    }

    /// <summary>
    /// Layer 6 contract: every provider (local or cloud) presents the SAME input/output shape.
    /// The UI never talks to a provider directly — only the AI Gateway calls this interface.
    /// </summary>
    public interface IProviderAdapter
    {
        ProviderInfo Info { get; }

        /// <summary>Apply credentials/model for the next calls (in-memory only).</summary>
        void Configure(ProviderCredentials credentials);

        Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct);

        Task<bool> TestConnectionAsync(CancellationToken ct);

        /// <summary>
        /// Sends a chat request. Streaming deltas are reported through onDelta.
        /// Implementations MUST honor ct (real cancellation of the HTTP request).
        /// </summary>
        Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct);

        /// <summary>Whether the currently configured model can accept images. Called at send time.</summary>
        bool SupportsVisionNow();
    }

    /// <summary>Maps HTTP responses from OpenAI-style providers to categorized OMNIX errors.</summary>
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
