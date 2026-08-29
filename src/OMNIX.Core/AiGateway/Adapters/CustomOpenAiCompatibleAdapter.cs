using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Errors;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Custom provider: any OpenAI-compatible endpoint (Name + Base URL + API Key + Model).
    /// Vision is auto-enabled when the endpoint accepts image_url payloads — Test Connection
    /// performs a small image probe and stores the result (spec Layer 6 / Phase 8.2).
    /// </summary>
    public sealed class CustomOpenAiCompatibleAdapter : IProviderAdapter
    {
        private readonly OpenAiCompatibleClient _client;
        private ProviderCredentials _creds;
        private bool? _visionProbeResult;

        public CustomOpenAiCompatibleAdapter()
        {
            _client = new OpenAiCompatibleClient("http://localhost:8080/v1", "Custom Provider");
            Info = new ProviderInfo
            {
                Id = "custom",
                DisplayName = "Custom (OpenAI-compatible)",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "gpt-4o-mini",
                RequiresApiKey = false,
                Notes = "Any OpenAI-compatible endpoint you configure."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials;
            _client.SetModel(credentials.Model);
            string url = credentials.BaseUrl;
            var cp = SettingsManager.Instance.Settings.CustomProvider;
            if (string.IsNullOrEmpty(url) && cp != null) url = cp.BaseUrl;
            if (!string.IsNullOrEmpty(url))
                url_ = url;
            else
                throw OmnixException.Provider("Custom provider Base URL is not configured. Set it in Settings.");
        }

        private string url_;

        public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            return ActiveClient().SendAsync(request, _creds.ApiKey, _creds.Model, onDelta, ct);
        }

        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            return ActiveClient().ListModelsAsync(_creds.ApiKey, ct);
        }

        public async Task<bool> TestConnectionAsync(CancellationToken ct)
        {
            try
            {
                var models = await ListModelsAsync(ct).ConfigureAwait(false);
                bool ok = models != null && models.Count > 0;
                if (ok)
                {
                    // Vision probe: 1x1 transparent PNG asking the endpoint to describe it.
                    try
                    {
                        byte[] png = Convert.FromBase64String(
                            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==");
                        var probe = new ChatRequest
                        {
                            UserTurn = new ChatTurn
                            {
                                Role = ChatRole.User,
                                Text = "Reply with OK.",
                                Images = new System.Collections.Generic.List<ImageAttachment>
                                {
                                    new ImageAttachment { PngBytes = png, FileName = "probe.png" }
                                },
                                TimestampUtc = DateTime.UtcNow
                            }
                        };
                        var resp = await ActiveClient().SendAsync(probe, _creds.ApiKey, _creds.Model, null, ct).ConfigureAwait(false);
                        _visionProbeResult = resp != null && resp.Text != null;
                    }
                    catch
                    {
                        _visionProbeResult = false;
                    }
                    var cp = SettingsManager.Instance.Settings.CustomProvider;
                    if (cp != null) cp.SupportsVision = _visionProbeResult;
                }
                return ok;
            }
            catch
            {
                return false;
            }
        }

        public bool SupportsVisionNow()
        {
            if (_visionProbeResult.HasValue) return _visionProbeResult.Value;
            var cp = SettingsManager.Instance.Settings.CustomProvider;
            return cp != null && cp.SupportsVision == true;
        }

        private OpenAiCompatibleClient ActiveClient()
        {
            string baseWithFallback = string.IsNullOrEmpty(url_) ? (_creds != null ? _creds.BaseUrl : null) : url_;
            return new OpenAiCompatibleClient(baseWithFallback ?? "http://localhost:8080/v1", "Custom Provider");
        }
    }
}
