using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Adapters;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Provider registry. Provider-owned setup URLs, access/cost hints and maintained default
    /// model ids are centralized here. Cloud free-tier metadata is informational: OMNIX still
    /// loads live model lists and surfaces provider quota/rate-limit errors instead of promising
    /// that a cloud provider will remain free forever.
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
                new MistralAdapter(),
                new HuggingFaceAdapter(),
                new CerebrasAdapter(),
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
                "gemini-3.8-flash",
                ProviderAccessProfile.FreeTierAvailable,
                "Gemini Developer API currently offers free-tier usage for supported models; limits, data-use terms and regional availability apply.");

            SetMetadata("groq",
                "https://groq.com/",
                "https://console.groq.com/docs/quickstart",
                "https://console.groq.com/keys",
                "openai/gpt-oss-120b",
                ProviderAccessProfile.FreeTierAvailable,
                "Groq currently publishes Free Plan rate limits for supported models. Quotas are account/model specific.");

            SetMetadata("openrouter",
                "https://openrouter.ai/",
                "https://openrouter.ai/docs",
                "https://openrouter.ai/settings/keys",
                "openrouter/free",
                ProviderAccessProfile.FreeModelsAvailable,
                "OpenRouter exposes openrouter/free plus individual :free model variants. Free capacity, model inventory and provider privacy compatibility can change.");

            SetMetadata("mistral",
                "https://mistral.ai/",
                "https://docs.mistral.ai/getting-started/quickstarts/studio/activate-and-generate-api-key",
                "https://console.mistral.ai/",
                "mistral-small-latest",
                ProviderAccessProfile.FreeTierAvailable,
                "Mistral Studio currently enables Free mode with limited included usage/rate limits and no credit card required for Free mode.");

            SetMetadata("huggingface",
                "https://huggingface.co/",
                "https://huggingface.co/docs/inference-providers/index",
                "https://huggingface.co/settings/tokens",
                "openai/gpt-oss-120b:fastest",
                ProviderAccessProfile.FreeCreditsAvailable,
                "Hugging Face currently gives free users small monthly Inference Providers credits. The live model catalog can also mark temporary provider routes as free.");

            SetMetadata("cerebras",
                "https://www.cerebras.ai/",
                "https://www.cerebras.ai/inference",
                "https://cloud.cerebras.ai/",
                "gpt-oss-120b",
                ProviderAccessProfile.FreeCreditsAvailable,
                "Cerebras currently advertises free trial credits for new accounts. Continued usage is account/plan dependent rather than a permanent unlimited free tier.");

            SetMetadata("ollama", "https://ollama.com/", "https://docs.ollama.com/", null, null,
                ProviderAccessProfile.LocalNoCost,
                "Runs locally on this PC. Provider usage is not metered by OMNIX; model/resource cost is the user's local hardware usage.");

            SetMetadata("lmstudio", "https://lmstudio.ai/", "https://lmstudio.ai/docs", null, null,
                ProviderAccessProfile.LocalNoCost,
                "Runs locally on this PC through the LM Studio local server.");

            var custom = Get("custom");
            if (custom != null)
            {
                custom.Info.AccessProfile = ProviderAccessProfile.CustomEndpoint;
                custom.Info.AccessNotes = "Cost, privacy, authentication and limits are defined entirely by the user-configured endpoint.";
            }

            var gemini = Get("gemini");
            if (gemini != null)
                gemini.Info.Notes = "Vision-capable Gemini provider. Models are loaded dynamically; free-tier availability depends on the Google account/region.";

            var groq = Get("groq");
            if (groq != null)
                groq.Info.Notes = "Fast GroqCloud inference. Available models and account limits are loaded/validated at runtime where possible.";

            var openRouter = Get("openrouter");
            if (openRouter != null)
                openRouter.Info.Notes = "Multi-provider router. openrouter/free and :free variants are prioritized in the model list; account privacy policy can restrict routing.";
        }

        private void SetMetadata(string id, string website, string docs, string apiKey, string defaultModel,
            ProviderAccessProfile accessProfile, string accessNotes)
        {
            var provider = Get(id);
            if (provider == null) return;
            provider.Info.OfficialWebsiteUrl = website;
            provider.Info.DocumentationUrl = docs;
            provider.Info.ApiKeyUrl = apiKey;
            provider.Info.AccessProfile = accessProfile;
            provider.Info.AccessNotes = accessNotes;
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
