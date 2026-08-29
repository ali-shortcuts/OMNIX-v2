using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Errors;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Http
{
    /// <summary>
    /// Shared OpenAI-compatible chat-completions client (stream: true, SSE).
    /// Used by Groq, OpenRouter, LM Studio and Custom providers so behavior is identical
    /// across them (spec Layer 6: same normalized input/output for every adapter).
    /// </summary>
    public sealed class OpenAiCompatibleClient
    {
        private readonly string _baseUrl;
        private readonly string _providerDisplayName;
        private readonly Dictionary<string, string> _extraHeaders;

        public OpenAiCompatibleClient(string baseUrl, string providerDisplayName, Dictionary<string, string> extraHeaders = null)
        {
            _baseUrl = baseUrl.TrimEnd('/');
            _providerDisplayName = providerDisplayName;
            _extraHeaders = extraHeaders;
        }

        private static JObject BuildMessage(ChatTurn turn)
        {
            var msg = new JObject();
            msg["role"] = RoleToString(turn.Role);

            if (turn.HasImages)
            {
                var content = new JArray();
                if (!string.IsNullOrEmpty(turn.Text))
                    content.Add(new JObject { { "type", "text" }, { "text", turn.Text } });
                foreach (var img in turn.Images)
                {
                    string b64 = Convert.ToBase64String(img.PngBytes);
                    content.Add(new JObject
                    {
                        { "type", "image_url" },
                        { "image_url", new JObject { { "url", "data:image/png;base64," + b64 } } }
                    });
                }
                msg["content"] = content;
            }
            else
            {
                msg["content"] = turn.Text ?? "";
            }
            return msg;
        }

        private static string RoleToString(ChatRole role)
        {
            switch (role)
            {
                case ChatRole.Assistant: return "assistant";
                case ChatRole.System: return "system";
                default: return "user";
            }
        }

        private string _configuredModel;

        public void SetModel(string model) { _configuredModel = model; }

        public string BuildPayload(ChatRequest request, bool stream)
        {
            var messages = new JArray();
            if (!string.IsNullOrEmpty(request.SystemPrompt))
                messages.Add(new JObject { { "role", "system" }, { "content", request.SystemPrompt } });
            if (request.History != null)
                foreach (var t in request.History)
                    messages.Add(BuildMessage(t));
            if (request.UserTurn != null)
                messages.Add(BuildMessage(request.UserTurn));

            var payload = new JObject
            {
                { "model", _configuredModel ?? "default" },
                { "messages", messages },
                { "stream", stream }
            };
            return payload.ToString(Formatting.None);
        }

        public async Task<ChatResponse> SendAsync(ChatRequest request, string apiKey, string model,
            Action<string> onDelta, CancellationToken ct)
        {
            _configuredModel = model;
            string body = BuildPayload(request, onDelta != null);
            return await SendRawAsync(body, apiKey, onDelta, ct).ConfigureAwait(false);
        }

        public async Task<ChatResponse> SendRawAsync(string jsonBody, string apiKey,
            Action<string> onDelta, CancellationToken ct)
        {
            try
            {
                using (var client = HttpClientFactory.Create())
                using (var req = new HttpRequestMessage(HttpMethod.Post, _baseUrl + "/chat/completions"))
                {
                    if (!string.IsNullOrEmpty(apiKey))
                        req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey);
                    if (_extraHeaders != null)
                        foreach (var kv in _extraHeaders)
                            req.Headers.TryAddWithoutValidation(kv.Key, kv.Value);

                    req.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
                    var response = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);

                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, _providerDisplayName);
                    }

                    var sb = new StringBuilder();
                    string model = _configuredModel;

                    if (onDelta == null)
                    {
                        string full = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                        var root = JObject.Parse(full);
                        model = (string)root.SelectToken("model") ?? model;
                        sb.Append((string)root.SelectToken("choices[0].message.content") ?? "");
                    }
                    else
                    {
                        using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        {
                            foreach (string data in SseLineReader.ReadDataLines(stream, ct))
                            {
                                if (data == "[DONE]") break;
                                JObject chunk;
                                try { chunk = JObject.Parse(data); }
                                catch { continue; }
                                model = (string)chunk.SelectToken("model") ?? model;
                                string delta = (string)chunk.SelectToken("choices[0].delta.content");
                                if (!string.IsNullOrEmpty(delta))
                                {
                                    sb.Append(delta);
                                    onDelta(delta);
                                }
                            }
                        }
                    }
                    return new ChatResponse { Text = sb.ToString(), Model = model };
                }
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network(_providerDisplayName + ": " + ex.Message);
            }
            catch (OmnixException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw OmnixException.Provider(_providerDisplayName + " transport failure: " + ex.Message);
            }
        }

        public async Task<IReadOnlyList<string>> ListModelsAsync(string apiKey, CancellationToken ct)
        {
            try
            {
                using (var client = HttpClientFactory.Create(TimeSpan.FromSeconds(20)))
                using (var req = new HttpRequestMessage(HttpMethod.Get, _baseUrl + "/models"))
                {
                    if (!string.IsNullOrEmpty(apiKey))
                        req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", apiKey);
                    if (_extraHeaders != null)
                        foreach (var kv in _extraHeaders)
                            req.Headers.TryAddWithoutValidation(kv.Key, kv.Value);

                    var response = await client.SendAsync(req, ct).ConfigureAwait(false);
                    if (!response.IsSuccessStatusCode)
                    {
                        string err = await SseLineReader.ReadErrorBodyAsync(response, ct).ConfigureAwait(false);
                        throw HttpStatusMapper.Map((int)response.StatusCode, err, _providerDisplayName);
                    }
                    string json = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
                    var root = JObject.Parse(json);
                    var list = new List<string>();
                    foreach (var m in root["data"] ?? new JArray())
                        list.Add((string)m["id"]);
                    return list;
                }
            }
            catch (HttpRequestException ex)
            {
                throw OmnixException.Network(_providerDisplayName + " models: " + ex.Message);
            }
        }
    }
}
