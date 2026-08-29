using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// LM Studio adapter (local AI, OpenAI-compatible server on port 1234).
    /// Vision depends on the loaded model; an endpoint refusal is surfaced as a clear error.
    /// </summary>
    public sealed class LmStudioAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private ProviderCredentials _creds;

        public LmStudioAdapter()
        {
            _client = new OpenAiCompatibleClient("http://localhost:1234/v1", "LM Studio");
            Info = new ProviderInfo
            {
                Id = "lmstudio",
                DisplayName = "LM Studio (Local)",
                Kind = ProviderKind.Local,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "",
                RequiresApiKey = false,
                Notes = "Local server on port 1234. Load a model in LM Studio first."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials;
            _client.SetModel(credentials.Model);
        }

        private string Model { get { return _creds != null ? _creds.Model : Info.DefaultModel; } }

        public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            // LM Studio uses "model" loosely; if unset, send "local-model" hint.
            string model = string.IsNullOrEmpty(Model) ? "local-model" : Model;
            return _client.SendAsync(request, null, model, onDelta, ct);
        }

        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            return _client.ListModelsAsync(null, ct);
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
            string m = (Model ?? "").ToLowerInvariant();
            return m.Contains("vision") || m.Contains("llava") || m.Contains("vl") || m.Contains("qwen2.5vl");
        }
    }
}
