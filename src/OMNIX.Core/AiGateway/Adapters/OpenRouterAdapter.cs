using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Errors;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// OpenRouter adapter — many models, some Vision-capable. The model list is DYNAMIC
    /// (spec Layer 6) and vision capability is read from each model's architecture modalities
    /// at connection time.
    /// </summary>
    public sealed class OpenRouterAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private readonly HttpClient _probeClient;
        private ProviderCredentials _creds;
        private HashSet<string> _visionModels;

        public OpenRouterAdapter()
        {
            _client = new OpenAiCompatibleClient("https://openrouter.ai/api/v1", "OpenRouter",
                new Dictionary<string, string>
                {
                    { "X-Title", "OMNIX" }
                });
            _probeClient = HttpClientFactory.Create(TimeSpan.FromSeconds(20));
            Info = new ProviderInfo
            {
                Id = "openrouter",
                DisplayName = "OpenRouter",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "openrouter/auto",
                RequiresApiKey = true,
                Notes = "Many models in one API; the model list is loaded dynamically."
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

        public async Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (request.HasImages && !SupportsVisionNow())
                throw Errors.OmnixException.Model(
                    "OpenRouter model '" + Model + "' does not accept images (Vision). " +
                    "Use 'Load models' and pick one with image input, or send text only.");
            return await _client.SendAsync(request, ApiKey, Model, onDelta, ct).ConfigureAwait(false);
        }

        public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            try
            {
                using (var req = new HttpRequestMessage(HttpMethod.Get, "https://openrouter.ai/api/v1/models"))
                {
                    if (!string.IsNullOrEmpty(ApiKey))
                        req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", ApiKey);
                    var response = await _probeClient.SendAsync(req, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, "OpenRouter");
                    }
                    string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var root = JObject.Parse(json);
                    var list = new List<string>();
                    var vision = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var m in root["data"] ?? new JArray())
                    {
                        string id = (string)m["id"];
                        if (string.IsNullOrEmpty(id)) continue;
                        list.Add(id);
                        try
                        {
                            var modalities = m.SelectToken("architecture.input_modalities") as JArray;
                            if (modalities != null && modalities.Any(t => string.Equals((string)t, "image", StringComparison.OrdinalIgnoreCase)))
                                vision.Add(id);
                        }
                        catch { }
                    }
                    _visionModels = vision;
                    return list;
                }
            }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network("OpenRouter models: " + ex.Message);
            }
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
            if (_visionModels == null) return false;
            return _visionModels.Contains(Model);
        }
    }
}
