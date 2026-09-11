using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace OMNIX.Core.Ai
{
    public sealed class AiGateway
    {
        private readonly ProviderRegistry _registry;
        private readonly PrivacyGate _privacy;

        public AiGateway(ProviderRegistry registry, PrivacyGate privacy)
        {
            _registry = registry ?? throw new ArgumentNullException(nameof(registry));
            _privacy = privacy ?? throw new ArgumentNullException(nameof(privacy));
        }

        public async Task<ChatResponse> SendAsync(
            string selectedProviderId,
            bool preferLocal,
            ChatRequest request,
            Action<string> onDelta,
            CancellationToken cancellationToken)
        {
            if (request == null) throw new ArgumentNullException(nameof(request));
            bool needsVision = request.Messages != null && request.Messages.Any(m => m.Images != null && m.Images.Count > 0);
            IAiProvider provider = _registry.Resolve(selectedProviderId, preferLocal, needsVision, request.Model);

            // Privacy is enforced here, immediately before provider execution. UI code cannot bypass it.
            await _privacy.EnsureAllowedAsync(provider.Descriptor).ConfigureAwait(true);
            cancellationToken.ThrowIfCancellationRequested();
            return await provider.SendAsync(request, onDelta, cancellationToken).ConfigureAwait(false);
        }
    }
}
