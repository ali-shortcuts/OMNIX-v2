using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace OMNIX.Core.AiGateway.Http
{
    /// <summary>
    /// Shared HttpClient factory. Cloud/custom HTTPS uses normal Windows certificate validation;
    /// OMNIX never installs a validation bypass. TLS 1.0/1.1 are deliberately not enabled.
    /// Automatic redirects are disabled so Authorization headers and Office context cannot be
    /// silently redirected to a different origin/scheme by a provider or custom endpoint.
    /// </summary>
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
                    // net48 on supported Windows reliably supports TLS 1.2. Do not OR legacy TLS
                    // protocols back in; certificate validation remains the platform default.
                    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                }
                catch { }
                _tlsConfigured = true;
            }
        }

        public static HttpClient Create(TimeSpan? timeout = null)
        {
            EnsureTls();
            var handler = new HttpClientHandler
            {
                AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
                AllowAutoRedirect = false
            };
            var client = new HttpClient(handler);
            client.Timeout = timeout ?? TimeSpan.FromSeconds(120);
            client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            return client;
        }
    }

    /// <summary>
    /// Reads SSE/NDJSON incrementally with a cancellation-aware socket read and a stateful UTF-8
    /// decoder. The stateful decoder prevents non-ASCII text from being corrupted when one UTF-8
    /// code point is split across network chunks. Accumulator limits prevent a malformed endpoint
    /// from growing an unbounded no-newline buffer inside an Office process.
    /// </summary>
    public static class SseLineReader
    {
        private const int BufferBytes = 8192;
        private const int MaxPendingChars = 4 * 1024 * 1024;
        private const int MaxErrorBodyChars = 16 * 1024;

        public static IEnumerable<string> ReadDataLines(Stream stream, CancellationToken ct)
        {
            if (stream == null) yield break;
            foreach (string line in ReadLines(stream, ct))
            {
                if (line.StartsWith("data:", StringComparison.Ordinal))
                {
                    string data = line.Substring(5).Trim();
                    if (data.Length > 0) yield return data;
                }
            }
        }

        /// <summary>Reads NDJSON lines (one JSON object per line — Ollama style).</summary>
        public static IEnumerable<string> ReadNdjsonLines(Stream stream, CancellationToken ct)
        {
            if (stream == null) yield break;
            foreach (string line in ReadLines(stream, ct))
            {
                string trimmed = line.Trim();
                if (trimmed.Length > 0) yield return trimmed;
            }
        }

        private static IEnumerable<string> ReadLines(Stream stream, CancellationToken ct)
        {
            var bytes = new byte[BufferBytes];
            var chars = new char[Encoding.UTF8.GetMaxCharCount(BufferBytes)];
            Decoder decoder = Encoding.UTF8.GetDecoder();
            var pending = new StringBuilder();

            while (true)
            {
                ct.ThrowIfCancellationRequested();
                int read;
                try
                {
                    read = stream.ReadAsync(bytes, 0, bytes.Length, ct).GetAwaiter().GetResult();
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (IOException)
                {
                    throw;
                }

                if (read <= 0) break;

                int byteIndex = 0;
                while (byteIndex < read)
                {
                    int bytesUsed, charsUsed;
                    bool completed;
                    decoder.Convert(bytes, byteIndex, read - byteIndex, chars, 0, chars.Length, false,
                        out bytesUsed, out charsUsed, out completed);
                    byteIndex += bytesUsed;
                    if (charsUsed > 0) pending.Append(chars, 0, charsUsed);
                    if (pending.Length > MaxPendingChars)
                        throw new InvalidDataException("Provider stream contains an over-sized line/no-newline payload.");
                }

                string acc = pending.ToString();
                int newline;
                while ((newline = acc.IndexOf('\n')) >= 0)
                {
                    string line = acc.Substring(0, newline).TrimEnd('\r');
                    acc = acc.Substring(newline + 1);
                    yield return line;
                }
                pending.Clear();
                pending.Append(acc);
            }

            // Flush any final decoder state and a final line that was not newline-terminated.
            int flushBytes, flushChars;
            bool flushCompleted;
            decoder.Convert(new byte[0], 0, 0, chars, 0, chars.Length, true,
                out flushBytes, out flushChars, out flushCompleted);
            if (flushChars > 0) pending.Append(chars, 0, flushChars);
            if (pending.Length > MaxPendingChars)
                throw new InvalidDataException("Provider stream final line exceeded the safety limit.");
            if (pending.Length > 0)
                yield return pending.ToString().TrimEnd('\r');
        }

        /// <summary>
        /// Reads a normal JSON/text HTTP body without allowing an endpoint to allocate an unlimited
        /// string inside an Office process. Callers choose a route-specific byte cap.
        /// </summary>
        public static async Task<string> ReadBodyBoundedAsync(HttpContent content, int maxBytes, CancellationToken ct)
        {
            if (content == null) return string.Empty;
            if (maxBytes <= 0) throw new ArgumentOutOfRangeException("maxBytes");

            using (var stream = await content.ReadAsStreamAsync().ConfigureAwait(false))
            using (var ms = new MemoryStream())
            {
                var buffer = new byte[BufferBytes];
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    int remaining = maxBytes + 1 - (int)ms.Length;
                    if (remaining <= 0)
                        throw new InvalidDataException("HTTP response body exceeded the OMNIX safety limit.");
                    int read = await stream.ReadAsync(buffer, 0, Math.Min(buffer.Length, remaining), ct).ConfigureAwait(false);
                    if (read <= 0) break;
                    ms.Write(buffer, 0, read);
                    if (ms.Length > maxBytes)
                        throw new InvalidDataException("HTTP response body exceeded the OMNIX safety limit.");
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        public static async Task<string> ReadErrorBodyAsync(HttpResponseMessage response, CancellationToken ct)
        {
            if (response == null || response.Content == null) return "(no body)";
            try
            {
                string text = await ReadBodyBoundedAsync(response.Content, MaxErrorBodyChars, ct).ConfigureAwait(false);
                return text.Length >= MaxErrorBodyChars ? text + "…[truncated]" : text;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (InvalidDataException)
            {
                return "(provider error body exceeded OMNIX safety limit)";
            }
            catch
            {
                return "(no body)";
            }
        }
    }
}
