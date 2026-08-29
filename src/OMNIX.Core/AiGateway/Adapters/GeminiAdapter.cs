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
    /// Gemini adapter — full Vision support (image + text), free daily tier.
    /// Endpoint: POST /v1beta/models/{model}:streamGenerateContent?alt=sse (SSE streaming).
    /// API key travels in the x-goog-api-key header (never in URLs that get logged).
    /// </summary>
    public sealed class GeminiAdapter : IProviderAdapter
    {
        private const string Base = "https://generativelanguage.googleapis.com/v1beta";

        private ProviderCredentials _creds;

        public ProviderInfo Info { get; private set; }

        public GeminiAdapter()
        {
            Info = new ProviderInfo
            {
                Id = "gemini",
                DisplayName = "Google Gemini",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.Yes,
                DefaultModel = "gemini-2.0-flash",
                RequiresApiKey = true,
                Notes = "Full Vision support. Free daily quota available."
            };
        }

        public void Configure(ProviderCredentials credentials) { _creds = credentials; }

        private string Model
        {
            get { return string.IsNullOrEmpty(_creds.Model) ? Info.DefaultModel : _creds.Model; }
        }

        private static JObject BuildPart(ChatTurn turn)
        {
            var parts = new JArray();
            if (!string.IsNullOrEmpty(turn.Text))
                parts.Add(new JObject { { "text", turn.Text } });
            if (turn.HasImages)
            {
                foreach (var img in turn.Images)
                {
                    parts.Add(new JObject
                    {
                        { "inline_data", new JObject { { "mime_type", "image/png" },
                            { "data", Convert.ToBase64String(img.PngBytes) } } }
                    });
                }
            }
            return new JObject { { "parts", parts } };
        }

        public string BuildPayload(ChatRequest request, bool stream)
        {
            var contents = new JArray();
            if (request.History != null)
                foreach (var t in request.History)
                {
                    var part = BuildPart(t);
                    part["role"] = t.Role == ChatRole.Assistant ? "model" : "user";
                    contents.Add(part);
                }
            if (request.UserTurn != null)
            {
                var part = BuildPart(request.UserTurn);
                part["role"] = "user";
                contents.Add(part);
            }

            var payload = new JObject { { "contents", contents } };
            if (!string.IsNullOrEmpty(request.SystemPrompt))
                payload["systemInstruction"] = new JObject
                {
                    { "parts", new JArray { new JObject { { "text", request.SystemPrompt } } } }
                };
            return payload.ToString(Formatting.None);
        }

        public async Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            if (_creds == null || string.IsNullOrEmpty(_creds.ApiKey))
                throw OmnixException.Auth("No Gemini API key configured.");

            string url = Base + "/models/" + Uri.EscapeDataString(Model) +
                         (onDelta != null ? ":streamGenerateContent?alt=sse" : ":generateContent");

            try
            {
                using (var client = HttpClientFactory.Create())
                using (var req = new HttpRequestMessage(HttpMethod.Post, url))
                {
                    req.Headers.TryAddWithoutValidation("x-goog-api-key", _creds.ApiKey);
                    req.Content = new StringContent(BuildPayload(request, onDelta != null), Encoding.UTF8, "application/json");
                    var response = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);

                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, "Gemini");
                    }

                    var sb = new StringBuilder();
                    if (onDelta == null)
                    {
                        string full = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                        var root = JObject.Parse(full);
                        foreach (var part in root.SelectTokens("candidates[0].content.parts[*]"))
                            sb.Append((string)part["text"]);
                    }
                    else
                    {
                        using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        {
                            foreach (string data in SseLineReader.ReadDataLines(stream, ct))
                            {
                                JObject chunk;
                                try { chunk = JObject.Parse(data); }
                                catch { continue; }
                                foreach (var part in chunk.SelectTokens("candidates[0].content.parts[*]"))
                                {
                                    string delta = (string)part["text"];
                                    if (!string.IsNullOrEmpty(delta))
                                    {
                                        sb.Append(delta);
                                        onDelta(delta);
                                    }
                                }
                            }
                        }
                    }
                    return new ChatResponse { Text = sb.ToString(), Model = Model };
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (HttpRequestException ex) { throw OmnixException.Network("Gemini: " + ex.Message); }
            catch (OmnixException) { throw; }
            catch (Exception ex) { throw OmnixException.Provider("Gemini transport failure: " + ex.Message); }
        }

        public async Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            if (_creds == null || string.IsNullOrEmpty(_creds.ApiKey))
                throw OmnixException.Auth("No Gemini API key configured.");
            try
            {
                using (var client = HttpClientFactory.Create(TimeSpan.FromSeconds(20)))
                using (var req = new HttpRequestMessage(HttpMethod.Get, Base + "/models"))
                {
                    req.Headers.TryAddWithoutValidation("x-goog-api-key", _creds.ApiKey);
                    var response = await client.SendAsync(req, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, "Gemini");
                    }
                    string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var root = JObject.Parse(json);
                    var list = new List<string>();
                    foreach (var m in root["models"] ?? new JArray())
                    {
                        string name = (string)m["name"] ?? "";
                        if (name.StartsWith("models/", StringComparison.Ordinal)) name = name.Substring(7);
                        var methods = m["supportedGenerationMethods"] as JArray;
                        if (methods != null && !methods.Any(t => (string)t == "generateContent")) continue;
                        list.Add(name);
                    }
                    return list;
                }
            }
            catch (HttpRequestException ex) { throw OmnixException.Network("Gemini models: " + ex.Message); }
        }

        public Task<bool> TestConnectionAsync(CancellationToken ct)
        {
            var request = new ChatRequest
            {
                SystemPrompt = null,
                UserTurn = new ChatTurn
                {
                    Role = ChatRole.User,
                    Text = "ping",
                    TimestampUtc = DateTime.UtcNow
                }
            };
            var minimal = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, minimal.Token);
            return TestInner(request, linked.Token);
        }

        private async Task<bool> TestInner(ChatRequest request, CancellationToken ct)
        {
            try
            {
                var resp = await SendAsync(request, null, ct).ConfigureAwait(false);
                return resp != null && resp.Text != null;
            }
            catch
            {
                return false;
            }
        }

        public bool SupportsVisionNow() { return true; }
    }
}
