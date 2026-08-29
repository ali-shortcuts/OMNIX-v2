using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Errors;

namespace OMNIX.Core.AiGateway.Http
{
    /// <summary>Shared HttpClient factory. TLS 1.2+ is forced for older http stacks (net48).</summary>
    public static class HttpClientFactory
    {
        private static readonly object Gate = new object();
        private static bool _tlsConfigured;

        public static void EnsureTls()
        {
            if (_tlsConfigured) return;
            lock (Gate)
            {
                if (_tlsConfigured) return;
                try
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
                }
                catch { }
                _tlsConfigured = true;
            }
        }

        public static HttpClient Create(TimeSpan? timeout = null)
        {
            EnsureTls();
            var handler = new HttpClientHandler();
            handler.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            var client = new HttpClient(handler);
            client.Timeout = timeout ?? TimeSpan.FromSeconds(120);
            client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            return client;
        }
    }

    /// <summary>
    /// Reads "data: {...}" lines from an SSE stream. Honors CancellationToken for real
    /// cancellation (spec Section 5: Stop must truly abort the HTTP request).
    /// </summary>
    public static class SseLineReader
    {
        public static IEnumerable<string> ReadDataLines(Stream stream, CancellationToken ct)
        {
            var buffer = new byte[8192];
            var sb = new StringBuilder();
            using (var ms = new MemoryStream())
            {
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    int read;
                    try
                    {
                        read = stream.Read(buffer, 0, buffer.Length);
                    }
                    catch (OperationCanceledException)
                    {
                        throw;
                    }
                    catch (IOException)
                    {
                        throw; // stream aborted (cancelled at socket level)
                    }
                    if (read <= 0) break;

                    ms.Write(buffer, 0, read);
                    string chunk = Encoding.UTF8.GetString(ms.ToArray());
                    ms.SetLength(0);

                    sb.Append(chunk);
                    string acc = sb.ToString();
                    int idx;
                    while ((idx = acc.IndexOf('\n')) >= 0)
                    {
                        string line = acc.Substring(0, idx).TrimEnd('\r');
                        acc = acc.Substring(idx + 1);
                        if (line.StartsWith("data:", StringComparison.Ordinal))
                        {
                            string data = line.Substring(5).Trim();
                            if (data.Length > 0) yield return data;
                        }
                    }
                    sb.Clear();
                    sb.Append(acc);
                }
            }
        }

        /// <summary>Reads NDJSON lines (one JSON object per line — Ollama style).</summary>
        public static IEnumerable<string> ReadNdjsonLines(Stream stream, CancellationToken ct)
        {
            var buffer = new byte[8192];
            var sb = new StringBuilder();
            using (var ms = new MemoryStream())
            {
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    int read = stream.Read(buffer, 0, buffer.Length);
                    if (read <= 0) break;
                    ms.Write(buffer, 0, read);
                    string chunk = Encoding.UTF8.GetString(ms.ToArray());
                    ms.SetLength(0);
                    sb.Append(chunk);
                    string acc = sb.ToString();
                    int idx;
                    while ((idx = acc.IndexOf('\n')) >= 0)
                    {
                        string line = acc.Substring(0, idx).TrimEnd('\r');
                        acc = acc.Substring(idx + 1);
                        if (line.Trim().Length > 0) yield return line.Trim();
                    }
                    sb.Clear();
                    sb.Append(acc);
                }
            }
        }

        public static async Task<string> ReadErrorBodyAsync(HttpResponseMessage response, CancellationToken ct)
        {
            try
            {
                return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
            catch
            {
                return "(no body)";
            }
        }
    }
}
