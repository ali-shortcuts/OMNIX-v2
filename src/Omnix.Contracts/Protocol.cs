using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Omnix.Contracts
{
    public sealed class Provider
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Kind { get; set; } = "compatible";
        public string Endpoint { get; set; }
        public string Model { get; set; } = "";
        public bool HasKey { get; set; }
        public bool Vision { get; set; }
        public override string ToString() => Name;
    }
    public sealed class Preferences
    {
        public int Revision { get; set; }
        public string Selected { get; set; } = "ollama";
        public string Privacy { get; set; } = "Ask before sending";
        public List<Provider> Providers { get; set; } = new List<Provider> {
            new Provider { Id="ollama", Name="Ollama", Endpoint="http://127.0.0.1:11434/v1" },
            new Provider { Id="lmstudio", Name="LM Studio", Endpoint="http://127.0.0.1:1234/v1" },
            new Provider { Id="openai", Name="OpenAI", Endpoint="https://api.openai.com/v1" },
            new Provider { Id="gemini", Name="Google Gemini", Kind="gemini", Endpoint="https://generativelanguage.googleapis.com/v1beta" },
            new Provider { Id="groq", Name="Groq", Endpoint="https://api.groq.com/openai/v1" },
            new Provider { Id="openrouter", Name="OpenRouter", Endpoint="https://openrouter.ai/api/v1" },
            new Provider { Id="custom", Name="Custom OpenAI-compatible", Endpoint="https://example.com/v1" }
        };
    }
    public sealed class Message
    {
        public string Role { get; set; }
        public string Text { get; set; }
    }
    public sealed class Request
    {
        public int Version { get; set; } = 1;
        public string Id { get; set; } = Guid.NewGuid().ToString("N");
        public string Operation { get; set; }
        public Preferences Settings { get; set; }
        public Dictionary<string,string> NewKeys { get; set; }
        public string ProviderId { get; set; }
        public string ExpectedEndpoint { get; set; }
        public string ExpectedModel { get; set; }
        public bool CloudApproved { get; set; }
        public List<Message> Messages { get; set; }
        public string Context { get; set; }
        public string ImageBase64 { get; set; }
    }
    public sealed class Reply
    {
        public string Id { get; set; }
        public bool Ok { get; set; }
        public string Code { get; set; }
        public string Text { get; set; }
        public Preferences Settings { get; set; }
        public List<string> Models { get; set; }
    }
    public static class Wire
    {
        public const int MaximumBytes = 8 * 1024 * 1024;
        public static string PipeName => "OMNIX.v4." + WindowsIdentity.GetCurrent().User.Value;
        public static string Json(object value) => new JavaScriptSerializer { MaxJsonLength=MaximumBytes, RecursionLimit=32 }.Serialize(value);
        public static T Parse<T>(string value) => new JavaScriptSerializer { MaxJsonLength=MaximumBytes, RecursionLimit=32 }.Deserialize<T>(value);
        public static async Task WriteAsync(Stream pipe, object value, CancellationToken cancel)
        {
            byte[] body=Encoding.UTF8.GetBytes(Json(value));
            if(body.Length>MaximumBytes) throw new InvalidDataException("Message is too large.");
            byte[] length=BitConverter.GetBytes(body.Length);
            await pipe.WriteAsync(length,0,length.Length,cancel).ConfigureAwait(false);
            await pipe.WriteAsync(body,0,body.Length,cancel).ConfigureAwait(false);
            await pipe.FlushAsync(cancel).ConfigureAwait(false);
        }
        public static async Task<T> ReadAsync<T>(Stream pipe, CancellationToken cancel)
        {
            var length=new byte[4]; await ReadExactly(pipe,length,cancel).ConfigureAwait(false);
            int count=BitConverter.ToInt32(length,0);
            if(count<1 || count>MaximumBytes) throw new InvalidDataException("Invalid message length.");
            var body=new byte[count]; await ReadExactly(pipe,body,cancel).ConfigureAwait(false);
            return Parse<T>(Encoding.UTF8.GetString(body));
        }
        private static async Task ReadExactly(Stream pipe,byte[] bytes,CancellationToken cancel)
        {
            int offset=0;
            while(offset<bytes.Length) {
                int n=await pipe.ReadAsync(bytes,offset,bytes.Length-offset,cancel).ConfigureAwait(false);
                if(n==0) throw new EndOfStreamException("Gateway disconnected.");
                offset+=n;
            }
        }
    }
}
