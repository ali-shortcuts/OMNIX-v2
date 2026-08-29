using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Errors;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Ollama adapter (local AI, port 11434). NDJSON streaming via /api/chat.
    /// Vision is enabled only when the installed model is multimodal (llava and friends),
    /// detected via /api/show (spec Section 6).
    /// </summary>
    public sealed class OllamaAdapter : IProviderAdapter
    {
        private ProviderCredentials _creds;
        private static readonly string[] KnownVisionMarkers =
        {
            "llava", "bakllava", "moondream", "minicpm-v", "qwen2-vl", "qwen2.5vl",
            "llama3.2-vision", "vision", "gemma3", "mistral-small3.1", "granite3.1-moe"
        };

        public OllamaAdapter()
        {
            Info = new ProviderInfo
            {
                Id = "ollama",
                DisplayName = "Ollama (Local)",
                Kind = ProviderKind.Local,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "",
                RequiresApiKey = false,
                Notes = "Runs on this PC (port 11434). Vision requires a multimodal model such as llava."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials) { _creds = credentials; }

        private string BaseUrl { get { return (_creds != null && !string.IsNullOrEmpty(_creds.BaseUrl)) ? _creds.BaseUrl.TrimEnd('/') : "http://localhost:11434"; } }

        private string Model
        {
            get { return _creds != null && !string.IsNullOrEmpty(_creds.Model) ? _creds.Model : FirstModelOr("llava"); }
        }

        private string _firstModel;

        private string FirstModelOr(string fallback)
        {
            return string.IsNullOrEmpty(_firstModel) ? fallback : _firstModel;
        }

        private static JObject BuildMessage(ChatTurn turn)
        {
            var msg = new JObject { { "role", turn.Role == ChatRole.Assistant ? "assistant" : "user" } };
            msg["content"] = turn.Text ?? "";
            if (turn.HasImages)
            {
                var images = new JArray();
                foreach (var img in turn.Images)
                    images.Add(Convert.ToBase64String(img.PngBytes));
                msg["images"] = images;
            }
            return msg;
        }

        public string BuildPayload(ChatRequest request)
        {
            var messages = new JArray();
            if (request.History != null)
                foreach (var t in request.History)
                    messages.Add(BuildMessage(t));
            if (request.UserTurn != null)
                messages.Add(BuildMessage(request.UserTurn));

            var payload = new JObject
            {
                { "model", Model },
                { "messages", messages },
                { "stream", request.UserTurn != null }
            };
            return payload.ToString(Formatting.None);
        }

        public async Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            try
            {
                using (var client = HttpClientFactory.Create())
                using (var req = new HttpRequestMessage(HttpMethod.Post, BaseUrl + "/api/chat"))
                {
                    req.Content = new StringContent(BuildPayload(request), Encoding.UTF8, "application/json");
                    var response = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, "Ollama");
                    }

                    var sb = new StringBuilder();
                    using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                    {
                        foreach (string line in SseLineReader.ReadNdjsonLines(stream, ct))
                        {
                            JObject obj;
                            try { obj = JObject.Parse(line); }
                            catch { continue; }
                            string delta = (string)obj.SelectToken("message.content");
                            if (!string.IsNullOrEmpty(delta) && onDelta != null)
                            {
                                sb.Append(delta);
                                onDelta(delta);
                            }
                            else if (!string.IsNullOrEmpty(delta))
                            {
                                sb.Append(delta);
                            }
                            bool done = (bool?)obj["done"] == true;
                            if (done) break;
                        }
                    }
                    return new ChatResponse { Text = sb.ToString(), Model = Model };
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (HttpRequestException ex) { throw OmnixException.Network("Ollama: " + ex.Message); }
            catch (OmnixException) { throw; }
            catch (Exception ex) { throw OmnixException.Provider("Ollama transport failure: " + ex.Message); }
        }

        public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            try
            {
                using (var client = HttpClientFactory.Create(TimeSpan.FromSeconds(10)))
                using (var req = new HttpRequestMessage(HttpMethod.Get, BaseUrl + "/api/tags"))
                {
                    var response = await client.SendAsync(req, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                        throw HttpStatusMapper.Map((int)response.StatusCode, "(Ollama /api/tags)", "Ollama");
                    string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var root = JObject.Parse(json);
                    var list = new List<string>();
                    foreach (var m in root["models"] ?? new JArray())
                        list.Add((string)m["name"]);
                    _firstModel = list.FirstOrDefault();
                    return list;
                }
            }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network("Ollama is not reachable at " + BaseUrl + ": " + ex.Message);
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
            string m = (Model ?? "").ToLowerInvariant();
            return KnownVisionMarkers.Any(marker => m.Contains(marker));
        }
    }
}
