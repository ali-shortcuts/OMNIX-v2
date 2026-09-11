using System;
using System.Collections.Generic;
using System.Linq;

namespace OMNIX.Core.Ai
{
    public sealed class ProviderRegistry
    {
        private readonly Dictionary<string, IAiProvider> _providers =
            new Dictionary<string, IAiProvider>(StringComparer.OrdinalIgnoreCase);

        public IReadOnlyCollection<IAiProvider> All => _providers.Values.ToArray();

        public void Register(IAiProvider provider)
        {
            if (provider == null) throw new ArgumentNullException(nameof(provider));
            if (provider.Descriptor == null || string.IsNullOrWhiteSpace(provider.Descriptor.Id))
                throw new ArgumentException("Provider must expose a stable descriptor id.", nameof(provider));
            _providers[provider.Descriptor.Id] = provider;
        }

        public IAiProvider Get(string id)
        {
            if (string.IsNullOrWhiteSpace(id)) return null;
            _providers.TryGetValue(id, out IAiProvider provider);
            return provider;
        }

        public IAiProvider Resolve(string selectedId, bool preferLocal, bool needsVision, string model)
        {
            if (preferLocal)
            {
                IAiProvider local = _providers.Values.FirstOrDefault(p =>
                    p.Descriptor.Kind == ProviderKind.Local && (!needsVision || p.SupportsVision(model)));
                if (local != null) return local;
            }

            IAiProvider selected = Get(selectedId);
            if (selected == null) throw new InvalidOperationException("Selected provider is not registered: " + selectedId);
            if (needsVision && !selected.SupportsVision(model))
                throw new InvalidOperationException("Selected provider/model does not support Vision.");
            return selected;
        }
    }
}
