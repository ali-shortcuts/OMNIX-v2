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

    public sealed class ProviderInfo
    {
        public string Id { get; set; }
        public string DisplayName { get; set; }
        public ProviderKind Kind { get; set; }
        public VisionSupport Vision { get; set; }
        public string DefaultModel { get; set; }
        public bool RequiresApiKey { get; set; }
        public string Notes { get; set; }
    }

    /// <summary>
    /// Layer 6 contract: every provider (local or cloud) presents the SAME input/output shape.
    /// The UI never talks to a provider directly — only the AI Gateway calls this interface
    /// (spec Section 3, Layer 5).
    /// </summary>
    public interface IProviderAdapter
    {
        ProviderInfo Info { get; }

        /// <summary>Apply credentials/model for the next calls (in-memory only).</summary>
        void Configure(ProviderCredentials credentials);

        Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct);

        Task<bool> TestConnectionAsync(CancellationToken ct);

        /// <summary>
        /// Sends a chat request. Streaming deltas (word by word) are reported through onDelta.
        /// Implementations MUST honor ct (real cancellation of the HTTP request, spec Section 5).
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
                    return OmnixException.Provider(providerName + " returned HTTP 429 — rate limit / daily quota reached. Body: " + trimmed);
                default:
                    return OmnixException.Provider(providerName + " returned HTTP " + statusCode + ". Body: " + trimmed);
            }
        }
    }
}
