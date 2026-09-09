using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Mistral AI cloud adapter. Mistral exposes an OpenAI-compatible /v1 API and provides
    /// a Free mode with limited usage/rate limits. Availability still depends on account/region.
    /// </summary>
    public sealed class MistralAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private ProviderCredentials _creds;

        public MistralAdapter()
        {
            _client = new OpenAiCompatibleClient("https://api.mistral.ai/v1", "Mistral AI");
            Info = new ProviderInfo
            {
                Id = "mistral",
                DisplayName = "Mistral AI — Free mode available",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "mistral-small-latest",
                RequiresApiKey = true,
                AccessProfile = ProviderAccessProfile.FreeTierAvailable,
                AccessNotes = "Mistral Studio Free mode is available with limited usage and rate limits; no credit card is required for Free mode according to current official docs.",
                Notes = "OpenAI-compatible Mistral API. Models are loaded dynamically from the account."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials ?? new ProviderCredentials();
            _client.SetModel(Model);
        }

        private string Model
        {
            get
            {
                return _creds != null && !string.IsNullOrWhiteSpace(_creds.Model)
                    ? _creds.Model
                    : Info.DefaultModel;
            }
        }

        private string ApiKey { get { return _creds != null ? _creds.ApiKey : null; } }

        public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (request.HasImages && !SupportsVisionNow())
                throw Errors.OmnixException.Model(
                    "Mistral model '" + Model + "' is not known by OMNIX as Vision-capable. Pick a multimodal Mistral model from Load models, or send text-only context.");

            return _client.SendAsync(request, ApiKey, Model, onDelta, ct);
        }

        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            return _client.ListModelsAsync(ApiKey, ct);
        }

        public async Task<bool> TestConnectionAsync(CancellationToken ct)
        {
            try
            {
                var models = await ListModelsAsync(ct).ConfigureAwait(false);
                return models != null && models.Count > 0;
            }
            catch
            {
                return false;
            }
        }

        public bool SupportsVisionNow()
        {
            string m = (Model ?? string.Empty).ToLowerInvariant();
            return m.Contains("pixtral") ||
                   m.Contains("ministral-3") ||
                   m.Contains("mistral-small-4") ||
                   m.Contains("mistral-medium-3.5") ||
                   m.Contains("mistral-large-3") ||
                   m.Contains("vision");
        }
    }
}
