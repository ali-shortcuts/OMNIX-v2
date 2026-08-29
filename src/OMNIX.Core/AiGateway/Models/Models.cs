using System;
using System.Collections.Generic;

namespace OMNIX.Core.AiGateway
{
    public sealed class ProviderCredentials
    {
        public string ApiKey { get; set; }
        public string Model { get; set; }
        public string BaseUrl { get; set; }
    }

    public sealed class ChatRequest
    {
        public string SystemPrompt { get; set; }
        public List<Storage.ChatTurn> History { get; set; }
        public Storage.ChatTurn UserTurn { get; set; }

        public bool HasImages
        {
            get
            {
                if (UserTurn != null && UserTurn.HasImages) return true;
                if (History != null)
                    foreach (var t in History)
                        if (t.HasImages) return true;
                return false;
            }
        }
    }

    public sealed class ChatResponse
    {
        public string Text { get; set; }
        public string Model { get; set; }
        public bool WasCancelled { get; set; }
    }
}
