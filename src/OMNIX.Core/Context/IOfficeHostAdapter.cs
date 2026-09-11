using System.Threading;
using System.Threading.Tasks;

namespace OMNIX.Core.Context
{
    public interface IOfficeHostAdapter
    {
        string HostName { get; }
        Task<OfficeContext> CaptureContextAsync(ContextRequest request, CancellationToken cancellationToken);
        Task<byte[]> CaptureCurrentViewPngAsync(CancellationToken cancellationToken);
        Task<OfficeMutationPreview> PreviewMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken);
        Task ApplyMutationAsync(OfficeMutation mutation, CancellationToken cancellationToken);
    }

    public sealed class ContextRequest
    {
        public int MaxCharacters { get; set; } = 6000;
        public int MaxItems { get; set; } = 2000;
        public bool IncludeFormulas { get; set; } = true;
        public bool IncludeMetadata { get; set; } = true;
    }

    public sealed class OfficeMutation
    {
        public string Tool { get; set; }
        public string Target { get; set; }
        public string Value { get; set; }
        public string Formula { get; set; }
        public string JsonArguments { get; set; }
    }

    public sealed class OfficeMutationPreview
    {
        public string Host { get; set; }
        public string Tool { get; set; }
        public string Target { get; set; }
        public string Before { get; set; }
        public string After { get; set; }
        public bool IsDestructive { get; set; }
    }
}
