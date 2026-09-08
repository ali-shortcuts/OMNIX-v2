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
    /// Hugging Face Inference Providers adapter.
    ///
    /// Hugging Face exposes an OpenAI-compatible router at router.huggingface.co/v1 and a live
    /// /models catalog containing architecture/provider metadata. OMNIX uses that live metadata to
    /// put models with a currently-free provider route first and to identify Vision-capable models.
    /// The provider also grants small monthly experimentation credits to free accounts; OMNIX labels
    /// that honestly and never promises unlimited free inference.
    /// </summary>
    public sealed class HuggingFaceAdapter : IProviderAdapter
    {
        private const string BaseUrl = "https://router.huggingface.co/v1";

        private readonly OpenAiCompatibleClient _client;
        private readonly HttpClient _catalogClient;
        private ProviderCredentials _creds;
        private HashSet<string> _visionModels;
        private HashSet<string> _currentlyFreeModels;

        public HuggingFaceAdapter()
        {
            _client = new OpenAiCompatibleClient(BaseUrl, "Hugging Face");
            _catalogClient = HttpClientFactory.Create(TimeSpan.FromSeconds(20));
            Info = new ProviderInfo
            {
                Id = "huggingface",
                DisplayName = "Hugging Face — monthly free credits",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "openai/gpt-oss-120b:fastest",
                RequiresApiKey = true,
                AccessProfile = ProviderAccessProfile.FreeCreditsAvailable,
                AccessNotes = "Free accounts currently receive small monthly Inference Providers credits. Models/routes marked free in the live catalog are prioritized when available.",
                Notes = "OpenAI-compatible Hugging Face router across many inference providers. Availability, pricing and free promotions are discovered dynamically."
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

        public async Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (request.HasImages && !SupportsVisionNow())
            {
                throw OmnixException.Model(
                    "Hugging Face model '" + Model + "' is not known to accept images. Use Load models and choose a Vision-capable model, or send text-only context.");
            }

            return await _client.SendAsync(request, ApiKey, Model, onDelta, ct).ConfigureAwait(false);
        }

        public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            try
            {
                using (var req = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/models"))
                {
                    if (!string.IsNullOrWhiteSpace(ApiKey))
                        req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", ApiKey);

                    var response = await _catalogClient.SendAsync(req, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, "Hugging Face");
                    }

                    string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var root = JObject.Parse(json);
                    var all = new List<string>();
                    var free = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    var vision = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                    foreach (var m in root["data"] ?? new JArray())
                    {
                        string id = (string)m["id"];
                        if (string.IsNullOrWhiteSpace(id)) continue;
                        all.Add(id);

                        try
                        {
                            var modalities = m.SelectToken("architecture.input_modalities") as JArray;
                            if (modalities != null && modalities.Any(x =>
                                string.Equals((string)x, "image", StringComparison.OrdinalIgnoreCase)))
                                vision.Add(id);
                        }
                        catch { }

                        try
                        {
                            var providers = m["providers"] as JArray;
                            if (providers != null && providers.Any(p =>
                                string.Equals((string)p["status"], "live", StringComparison.OrdinalIgnoreCase) &&
                                (bool?)p["is_free"] == true))
                                free.Add(id);
                        }
                        catch { }
                    }

                    _visionModels = vision;
                    _currentlyFreeModels = free;

                    // Keep the user's configured/default route selectable even if the live catalog
                    // temporarily omits that exact policy suffix (e.g. :fastest).
                    if (!all.Any(x => string.Equals(x, Model, StringComparison.OrdinalIgnoreCase)))
                        all.Add(Model);

                    return all
                        .Distinct(StringComparer.OrdinalIgnoreCase)
                        .OrderByDescending(x => free.Contains(x))
                        .ThenBy(x => x, StringComparer.OrdinalIgnoreCase)
                        .ToList();
                }
            }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network("Hugging Face models: " + ex.Message);
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
            string baseId = StripRoutingSuffix(Model);
            if (_visionModels == null) return false;
            return _visionModels.Contains(Model) || _visionModels.Contains(baseId);
        }

        public bool IsCurrentModelCurrentlyFree()
        {
            string baseId = StripRoutingSuffix(Model);
            return _currentlyFreeModels != null &&
                   (_currentlyFreeModels.Contains(Model) || _currentlyFreeModels.Contains(baseId));
        }

        private static string StripRoutingSuffix(string model)
        {
            if (string.IsNullOrWhiteSpace(model)) return string.Empty;
            int colon = model.LastIndexOf(':');
            if (colon <= 0) return model;
            return model.Substring(0, colon);
        }
    }
}
