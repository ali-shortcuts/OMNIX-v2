using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Adapters;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Provider registry. Runtime/provider behavior lives behind adapters; provider-owned setup
    /// URLs and maintained default-model hints are centralized here so the UI never hard-codes
    /// random links or silently keeps long-deprecated defaults.
    /// </summary>
    public sealed class ProviderRegistry
    {
        private readonly List<IProviderAdapter> _providers;
        private readonly Dictionary<string, bool> _localAvailability;

        public ProviderRegistry()
        {
            _providers = new List<IProviderAdapter>
            {
                new OllamaAdapter(),
                new LmStudioAdapter(),
                new GeminiAdapter(),
                new GroqAdapter(),
                new OpenRouterAdapter(),
                new CustomOpenAiCompatibleAdapter()
            };
            _localAvailability = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            ApplyOfficialMetadata();
        }

        private void ApplyOfficialMetadata()
        {
            SetMetadata("gemini",
                "https://ai.google.dev/gemini-api/docs",
                "https://ai.google.dev/gemini-api/docs/get-started",
                "https://aistudio.google.com/apikey",
                "gemini-3.6-flash");

            SetMetadata("groq",
                "https://groq.com/",
                "https://console.groq.com/docs/quickstart",
                "https://console.groq.com/keys",
                "openai/gpt-oss-120b");

            SetMetadata("openrouter",
                "https://openrouter.ai/",
                "https://openrouter.ai/docs",
                "https://openrouter.ai/settings/keys",
                "openrouter/auto");

            SetMetadata("ollama", "https://ollama.com/", "https://docs.ollama.com/", null, null);
            SetMetadata("lmstudio", "https://lmstudio.ai/", "https://lmstudio.ai/docs", null, null);

            var gemini = Get("gemini");
            if (gemini != null)
                gemini.Info.Notes = "Vision-capable Gemini provider. Free-tier availability and limits depend on the current Google account/region.";

            var groq = Get("groq");
            if (groq != null)
                groq.Info.Notes = "Fast GroqCloud inference. Available models and account limits are loaded dynamically.";

            var openRouter = Get("openrouter");
            if (openRouter != null)
                openRouter.Info.Notes = "Multi-provider router. Endpoint availability can be constrained by account privacy/data-policy settings.";

            // Custom provider URLs are intentionally NOT supplied by OMNIX. User-entered BaseUrl
            // is an API endpoint, not a trusted provider setup page, and is never opened as a link.
        }

        private void SetMetadata(string id, string website, string docs, string apiKey, string defaultModel)
        {
            var provider = Get(id);
            if (provider == null) return;
            provider.Info.OfficialWebsiteUrl = website;
            provider.Info.DocumentationUrl = docs;
            provider.Info.ApiKeyUrl = apiKey;
            if (!string.IsNullOrWhiteSpace(defaultModel)) provider.Info.DefaultModel = defaultModel;
        }

        public IReadOnlyList<IProviderAdapter> All { get { return _providers; } }

        public IProviderAdapter Get(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            return _providers.FirstOrDefault(p => string.Equals(p.Info.Id, id, StringComparison.OrdinalIgnoreCase));
        }

        public void SetLocalAvailability(string id, bool available)
        {
            lock (_localAvailability)
            {
                _localAvailability[id] = available;
            }
        }

        public bool IsLocalAvailable(string id)
        {
            lock (_localAvailability)
            {
                bool v;
                return _localAvailability.TryGetValue(id, out v) && v;
            }
        }

        public IProviderAdapter GetFirstAvailableLocal()
        {
            foreach (var p in _providers.Where(x => x.Info.Kind == ProviderKind.Local))
            {
                if (IsLocalAvailable(p.Info.Id)) return p;
            }
            return null;
        }

        public string GetLocalModelHint(string id)
        {
            try
            {
                var p = Get(id);
                if (p == null) return null;
                var t = p.ListModelsAsync(CancellationToken_None);
                t.Wait(3000);
                if (t.Status == TaskStatus.RanToCompletion && t.Result != null && t.Result.Count > 0)
                    return t.Result[0];
            }
            catch { }
            return null;
        }

        private static CancellationToken CancellationToken_None { get { return CancellationToken.None; } }
    }
}
