using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Groq adapter (OpenAI-compatible). Text-first provider: Vision availability depends on the
    /// model served at connection time (spec Layer 6) — known vision-capable ids are checked,
    /// and an image rejection at the endpoint is surfaced as a CLEAR message (never a vague error).
    /// </summary>
    public sealed class GroqAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private ProviderCredentials _creds;

        public GroqAdapter()
        {
            _client = new OpenAiCompatibleClient("https://api.groq.com/openai/v1", "Groq");
            Info = new ProviderInfo
            {
                Id = "groq",
                DisplayName = "Groq",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "llama-3.3-70b-versatile",
                RequiresApiKey = true,
                Notes = "Very fast text models. Vision only with vision-capable models."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials;
            _client.SetModel(credentials.Model);
        }

        private string Model { get { return string.IsNullOrEmpty(_creds.Model) ? Info.DefaultModel : _creds.Model; } }

        private string ApiKey { get { return _creds != null ? _creds.ApiKey : null; } }

        public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (request.HasImages && !SupportsVisionNow())
                throw Errors.OmnixException.Model(
                    "Groq model '" + Model + "' does not accept images (Vision). " +
                    "Pick a vision-capable model or send text only.");
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
            string m = (Model ?? "").ToLowerInvariant();
            return m.Contains("vision") || m.Contains("llama-4") || m.Contains("scout") || m.Contains("maverick");
        }
    }
}
