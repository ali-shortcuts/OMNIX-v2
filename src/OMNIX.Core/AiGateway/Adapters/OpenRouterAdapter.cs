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
    /// OpenRouter adapter. Live model metadata is used to prioritize openrouter/free and models
    /// whose current pricing is zero / whose id ends in :free. Availability, provider privacy
    /// policies and quotas can change at runtime. Live catalog bodies/counts are bounded before
    /// materialization so discovery cannot grow an Office process without limit.
    /// </summary>
    public sealed class OpenRouterAdapter : IProviderAdapter
    {
        private const int MaxCatalogBytes = 8 * 1024 * 1024;
        private const int MaxModels = 5000;

        private readonly OpenAiCompatibleClient _client;
        private readonly HttpClient _probeClient;
        private ProviderCredentials _creds;
        private HashSet<string> _visionModels;
        private HashSet<string> _freeModels;

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
                DisplayName = "OpenRouter — free models available",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "openrouter/free",
                RequiresApiKey = true,
                AccessProfile = ProviderAccessProfile.FreeModelsAvailable,
                AccessNotes = "openrouter/free automatically selects from currently available free models; individual :free variants are also listed first.",
                Notes = "Many models in one API. Free models are discovered dynamically and listed before paid models."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials ?? new ProviderCredentials();
            _client.SetModel(Model);
        }

        private string Model { get { return _creds == null || string.IsNullOrEmpty(_creds.Model) ? Info.DefaultModel : _creds.Model; } }
        private string ApiKey { get { return _creds != null ? _creds.ApiKey : null; } }

        public async Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (request != null && request.HasImages && !SupportsVisionNow())
                throw OmnixException.Model(
                    "OpenRouter model '" + Model + "' is not known to accept images (Vision). " +
                    "Use Load models and pick one with image input, choose openrouter/free, or send text only.");
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

                    using (var response = await _probeClient.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false))
                    {
                        if (!response.IsSuccessStatusCode)
                        {
                            string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                            throw HttpStatusMapper.Map((int)response.StatusCode, err, "OpenRouter");
                        }

                        string json = await SseLineReader.ReadBodyBoundedAsync(response.Content, MaxCatalogBytes, ct).ConfigureAwait(false);
                        var root = JObject.Parse(json);
                        var all = new List<string>();
                        var free = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        var vision = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                        foreach (var m in root["data"] ?? new JArray())
                        {
                            if (all.Count >= MaxModels) break;
                            string id = (string)m["id"];
                            if (string.IsNullOrEmpty(id)) continue;
                            all.Add(id);

                            if (IsFreeModel(m, id)) free.Add(id);

                            try
                            {
                                var modalities = m.SelectToken("architecture.input_modalities") as JArray;
                                if (modalities != null && modalities.Any(t => string.Equals((string)t, "image", StringComparison.OrdinalIgnoreCase)))
                                    vision.Add(id);
                            }
                            catch { }
                        }

                        // Official free-router alias may not always be emitted by /models; keep it as
                        // an explicit top-level choice. Capability selection can still fail at runtime
                        // if OpenRouter's current privacy/capacity policy has no eligible endpoint.
                        if (!all.Any(x => string.Equals(x, "openrouter/free", StringComparison.OrdinalIgnoreCase)))
                            all.Add("openrouter/free");
                        free.Add("openrouter/free");
                        vision.Add("openrouter/free");

                        _freeModels = free;
                        _visionModels = vision;

                        return all
                            .Distinct(StringComparer.OrdinalIgnoreCase)
                            .OrderByDescending(x => string.Equals(x, "openrouter/free", StringComparison.OrdinalIgnoreCase))
                            .ThenByDescending(x => free.Contains(x))
                            .ThenBy(x => x, StringComparer.OrdinalIgnoreCase)
                            .ToList();
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network("OpenRouter models: " + ex.Message);
            }
            catch (OmnixException) { throw; }
            catch (Exception ex) { throw OmnixException.Provider("OpenRouter model discovery failure: " + ex.Message); }
        }

        private static bool IsFreeModel(JToken model, string id)
        {
            if (string.Equals(id, "openrouter/free", StringComparison.OrdinalIgnoreCase)) return true;
            if (id.EndsWith(":free", StringComparison.OrdinalIgnoreCase)) return true;

            try
            {
                string prompt = (string)model.SelectToken("pricing.prompt");
                string completion = (string)model.SelectToken("pricing.completion");
                decimal p, c;
                if (decimal.TryParse(prompt, System.Globalization.NumberStyles.Any,
                        System.Globalization.CultureInfo.InvariantCulture, out p) &&
                    decimal.TryParse(completion, System.Globalization.NumberStyles.Any,
                        System.Globalization.CultureInfo.InvariantCulture, out c))
                    return p == 0m && c == 0m;
            }
            catch { }

            return false;
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
            if (string.Equals(Model, "openrouter/free", StringComparison.OrdinalIgnoreCase)) return true;
            if (_visionModels == null) return false;
            return _visionModels.Contains(Model);
        }

        public bool IsCurrentModelFree()
        {
            if (string.Equals(Model, "openrouter/free", StringComparison.OrdinalIgnoreCase)) return true;
            return _freeModels != null && _freeModels.Contains(Model);
        }
    }
}
