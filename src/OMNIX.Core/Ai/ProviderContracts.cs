using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace OMNIX.Core.Ai
{
    public enum ProviderKind { Local, Cloud }
    public enum VisionSupport { No, Yes, DependsOnModel }
    public enum AccessClass { Local, Free, FreeTier, Trial, Paid, Unknown }

    public sealed class ProviderDescriptor
    {
        public string Id { get; set; }
        public string DisplayName { get; set; }
        public ProviderKind Kind { get; set; }
        public VisionSupport Vision { get; set; }
        public AccessClass Access { get; set; }
        public bool RequiresApiKey { get; set; }
        public string OfficialWebsite { get; set; }
        public string DocumentationUrl { get; set; }
        public string ApiKeyUrl { get; set; }
    }

    public sealed class ChatMessage
    {
        public string Role { get; set; }
        public string Text { get; set; }
        public IReadOnlyList<ImagePart> Images { get; set; } = Array.Empty<ImagePart>();
    }

    public sealed class ImagePart
    {
        public string MimeType { get; set; }
        public byte[] Bytes { get; set; }
    }

    public sealed class ChatRequest
    {
        public string Model { get; set; }
        public string SystemPrompt { get; set; }
        public IReadOnlyList<ChatMessage> Messages { get; set; } = Array.Empty<ChatMessage>();
    }

    public sealed class ChatResponse
    {
        public string Text { get; set; }
        public string ProviderId { get; set; }
        public string Model { get; set; }
    }

    public interface IAiProvider
    {
        ProviderDescriptor Descriptor { get; }
        Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken cancellationToken);
        Task<bool> TestConnectionAsync(CancellationToken cancellationToken);
        Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken cancellationToken);
        bool SupportsVision(string model);
    }
}
