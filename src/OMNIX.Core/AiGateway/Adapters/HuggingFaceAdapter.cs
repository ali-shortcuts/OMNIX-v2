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
    /// /models catalog containing architecture/provider metadata. When the catalog marks a live
    /// provider route is_free=true, OMNIX exposes the exact model:provider route first. Catalog
    /// bodies/counts are hard-bounded before materialization inside the Office host.
    /// </summary>
    public sealed class HuggingFaceAdapter : IProviderAdapter
    {
        private const string BaseUrl = "https://router.huggingface.co/v1";
        private const int MaxCatalogBytes = 8 * 1024 * 1024;
        private const int MaxModels = 5000;

        private readonly OpenAiCompatibleClient _client;
        private readonly HttpClient _catalogClient;
        private ProviderCredentials _creds;
        private HashSet<string> _visionModels;
        private HashSet<string> _currentlyFreeRoutes;

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
                AccessNotes = "Free accounts currently receive small monthly Inference Providers credits. Exact live routes marked free by the provider catalog are listed first when available.",
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
            if (request != null && request.HasImages && !SupportsVisionNow())
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

                    using (var response = await _catalogClient.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
                    {
                        if (!response.IsSuccessStatusCode)
                        {
                            string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                            throw HttpStatusMapper.Map((int)response.StatusCode, err, "Hugging Face");
                        }

                        string json = await SseLineReader.ReadBodyBoundedAsync(response.Content, MaxCatalogBytes, ct).ConfigureAwait(false);
                        var root = JObject.Parse(json);
                        var baseModels = new List<string>();
                        var freeRoutes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        var vision = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                        foreach (var m in root["data"] ?? new JArray())
                        {
                            if (baseModels.Count >= MaxModels) break;
                            string id = (string)m["id"];
                            if (string.IsNullOrWhiteSpace(id)) continue;
                            baseModels.Add(id);

                            bool visionCapable = false;
                            try
                            {
                                var modalities = m.SelectToken("architecture.input_modalities") as JArray;
                                visionCapable = modalities != null && modalities.Any(x =>
                                    string.Equals((string)x, "image", StringComparison.OrdinalIgnoreCase));
                                if (visionCapable) vision.Add(id);
                            }
                            catch { }

                            try
                            {
                                var providers = m["providers"] as JArray;
                                if (providers == null) continue;
                                foreach (var provider in providers)
                                {
                                    if (!string.Equals((string)provider["status"], "live", StringComparison.OrdinalIgnoreCase) ||
                                        (bool?)provider["is_free"] != true)
                                        continue;

                                    string providerId = (string)provider["provider"];
                                    if (string.IsNullOrWhiteSpace(providerId)) continue;
                                    string route = id + ":" + providerId;
                                    freeRoutes.Add(route);
                                    if (visionCapable) vision.Add(route);
                                }
                            }
                            catch { }
                        }

                        _visionModels = vision;
                        _currentlyFreeRoutes = freeRoutes;

                        var ordered = new List<string>();
                        ordered.AddRange(freeRoutes.OrderBy(x => x, StringComparer.OrdinalIgnoreCase));
                        ordered.AddRange(baseModels.OrderBy(x => x, StringComparer.OrdinalIgnoreCase));

                        if (!ordered.Any(x => string.Equals(x, Model, StringComparison.OrdinalIgnoreCase)))
                            ordered.Add(Model);

                        return ordered.Distinct(StringComparer.OrdinalIgnoreCase).Take(MaxModels + 1).ToList();
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network("Hugging Face models: " + ex.Message);
            }
            catch (OmnixException) { throw; }
            catch (Exception ex) { throw OmnixException.Provider("Hugging Face model discovery failure: " + ex.Message); }
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
            return _currentlyFreeRoutes != null && _currentlyFreeRoutes.Contains(Model);
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
