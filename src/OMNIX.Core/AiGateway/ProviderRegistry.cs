using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway.Adapters;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Static provider registry (spec Phase 7.1). The initial list is fixed:
    /// Local: Ollama, LM Studio. Cloud: Gemini, Groq, OpenRouter, Custom.
    /// No provider may be added outside this registry without a spec revision (Ironclad scope).
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
