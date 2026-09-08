using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Cerebras Inference cloud adapter. The public API is OpenAI-compatible and the provider
    /// currently documents a Free tier with model-specific rate limits. OMNIX treats it as
    /// text-only until a selected model is explicitly verified for image input.
    /// </summary>
    public sealed class CerebrasAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private ProviderCredentials _creds;

        public CerebrasAdapter()
        {
            _client = new OpenAiCompatibleClient("https://api.cerebras.ai/v1", "Cerebras");
            Info = new ProviderInfo
            {
                Id = "cerebras",
                DisplayName = "Cerebras — Free tier available",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.No,
                DefaultModel = "gpt-oss-120b",
                RequiresApiKey = true,
                AccessProfile = ProviderAccessProfile.FreeTierAvailable,
                AccessNotes = "Cerebras currently documents a $0 Free tier with lower model-specific rate limits. Limits can change and are account-specific.",
                Notes = "Very fast OpenAI-compatible inference. Current OMNIX integration is text-only."
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
            if (request.HasImages)
                throw Errors.OmnixException.Model(
                    "Cerebras is configured as text-only in this OMNIX build. Use a Vision-capable provider for image analysis.");

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

        public bool SupportsVisionNow() { return false; }
    }
}
