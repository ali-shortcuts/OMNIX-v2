using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.Errors;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

namespace OMNIX.Core.AiGateway.Adapters
{
    /// <summary>
    /// Custom provider: any OpenAI-compatible endpoint (Name + Base URL + optional API Key + Model).
    /// Loopback endpoints (localhost / 127.0.0.1 / ::1) are classified as Local after Configure,
    /// so Privacy Mode can use a local custom server without pretending data leaves the PC.
    /// All other custom endpoints remain Cloud and pass through the normal cloud privacy gate.
    /// </summary>
    public sealed class CustomOpenAiCompatibleAdapter : IProviderAdapter
    {
        private ProviderCredentials _creds;
        private bool? _visionProbeResult;
        private string _baseUrl;

        public CustomOpenAiCompatibleAdapter()
        {
            Info = new ProviderInfo
            {
                Id = "custom",
                DisplayName = "Custom (OpenAI-compatible)",
                Kind = ProviderKind.Cloud,
                Vision = VisionSupport.DependsOnModel,
                DefaultModel = "gpt-4o-mini",
                // True means Settings should expose the key field. The key itself remains optional.
                RequiresApiKey = true,
                AccessProfile = ProviderAccessProfile.CustomEndpoint,
                AccessNotes = "API key is optional. Loopback endpoints are treated as local; other endpoints are treated as cloud.",
                Notes = "Configure an OpenAI-compatible Base URL, model, and optional API key."
            };
        }

        public ProviderInfo Info { get; private set; }

        public void Configure(ProviderCredentials credentials)
        {
            _creds = credentials ?? new ProviderCredentials();
            string url = _creds.BaseUrl;
            var cp = SettingsManager.Instance.Settings.CustomProvider;
            if (string.IsNullOrWhiteSpace(url) && cp != null) url = cp.BaseUrl;

            if (string.IsNullOrWhiteSpace(url))
                throw OmnixException.Provider("Custom provider Base URL is not configured. Set it in Settings.");

            Uri parsed;
            if (!Uri.TryCreate(url.Trim(), UriKind.Absolute, out parsed) ||
                !(string.Equals(parsed.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) ||
                  string.Equals(parsed.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)))
            {
                throw OmnixException.Provider("Custom provider Base URL must be an absolute http:// or https:// URL.");
            }

            _baseUrl = parsed.GetLeftPart(UriPartial.Path).TrimEnd('/');
            Info.Kind = IsLoopbackEndpoint(parsed) ? ProviderKind.Local : ProviderKind.Cloud;
            Info.AccessNotes = Info.Kind == ProviderKind.Local
                ? "Loopback custom endpoint: treated as Local AI; request data stays on this PC unless that local server forwards it elsewhere."
                : "Remote custom endpoint: treated as Cloud; OMNIX cloud privacy rules apply. Cost, retention and limits are defined by the endpoint owner.";

            if (string.IsNullOrWhiteSpace(_creds.Model) && cp != null) _creds.Model = cp.Model;
            if (string.IsNullOrWhiteSpace(_creds.Model)) _creds.Model = Info.DefaultModel;
        }

        public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
        {
            return ActiveClient().SendAsync(request, _creds != null ? _creds.ApiKey : null,
                _creds != null ? _creds.Model : Info.DefaultModel, onDelta, ct);
        }

        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
        {
            return ActiveClient().ListModelsAsync(_creds != null ? _creds.ApiKey : null, ct);
        }

        public async Task<bool> TestConnectionAsync(CancellationToken ct)
        {
            try
            {
                var models = await ListModelsAsync(ct).ConfigureAwait(false);
                bool ok = models != null && models.Count > 0;
                if (ok)
                {
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
                                Images = new List<ImageAttachment>
                                {
                                    new ImageAttachment { PngBytes = png, FileName = "probe.png" }
                                },
                                TimestampUtc = DateTime.UtcNow
                            }
                        };
                        var resp = await ActiveClient().SendAsync(probe,
                            _creds != null ? _creds.ApiKey : null,
                            _creds != null ? _creds.Model : Info.DefaultModel,
                            null, ct).ConfigureAwait(false);
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

        public static bool IsLoopbackEndpoint(string raw)
        {
            Uri uri;
            return Uri.TryCreate(raw, UriKind.Absolute, out uri) && IsLoopbackEndpoint(uri);
        }

        private static bool IsLoopbackEndpoint(Uri uri)
        {
            return uri != null && (uri.IsLoopback ||
                string.Equals(uri.Host, "localhost", StringComparison.OrdinalIgnoreCase));
        }

        private OpenAiCompatibleClient ActiveClient()
        {
            if (string.IsNullOrWhiteSpace(_baseUrl))
            {
                string raw = _creds != null ? _creds.BaseUrl : null;
                if (string.IsNullOrWhiteSpace(raw) && SettingsManager.Instance.Settings.CustomProvider != null)
                    raw = SettingsManager.Instance.Settings.CustomProvider.BaseUrl;
                if (string.IsNullOrWhiteSpace(raw))
                    throw OmnixException.Provider("Custom provider Base URL is not configured.");
                _baseUrl = raw.Trim().TrimEnd('/');
            }
            return new OpenAiCompatibleClient(_baseUrl, "Custom Provider");
        }
    }
}
