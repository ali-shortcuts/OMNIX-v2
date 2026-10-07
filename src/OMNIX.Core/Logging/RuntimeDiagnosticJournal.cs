using System;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Errors;

namespace OMNIX.Core.Logging
{
    /// <summary>
    /// Privacy-preserving request/tool diagnostic journal.
    ///
    /// Files:
    ///   runtime-journey.log  - concise human-readable timeline.
    ///   runtime-events.jsonl - one structured JSON object per event for reconstruction.
    ///
    /// The journal deliberately does NOT accept prompt text, Office content, tool arguments,
    /// API keys, custom Base URLs, provider response bodies, or stack traces.
    /// </summary>
    public static class RuntimeDiagnosticJournal
    {
        private sealed class TraceState
        {
            public string TraceId;
            public string Host;
            public bool MutationRequested;
            public long StartedTicks;
            public string Provider;
            public string Model;
        }

        private static readonly int ProcessId = GetProcessId();
        private static int GetProcessId() { try { using(var process=Process.GetCurrentProcess()) return process.Id; } catch { return 0; } }

        private static readonly AsyncLocal<TraceState> Current = new AsyncLocal<TraceState>();

        public static string CurrentTraceId
        {
            get { return Current.Value != null ? Current.Value.TraceId : "no-trace"; }
        }

        public static void BeginRequest(string host, bool mutationRequested, int userChars, int historyTurns, bool hasImages)
        {
            var state = new TraceState
            {
                TraceId = NewTraceId(),
                Host = SafeToken(host, 40),
                MutationRequested = mutationRequested,
                StartedTicks = Stopwatch.GetTimestamp()
            };
            Current.Value = state;
            Event("request_start", null, "start", null, null,
                "host=" + state.Host +
                "; mutation=" + mutationRequested +
                "; userChars=" + Math.Max(0, userChars) +
                "; historyTurns=" + Math.Max(0, historyTurns) +
                "; images=" + hasImages);
        }

        public static void UiDispatcherGap(string traceId, string operation, string phase, long gapMs)
        {
            var previous = Current.Value;
            try
            {
                Current.Value = new TraceState { TraceId = SafeToken(traceId, 80) };
                Event("ui_dispatcher_gap", operation, phase, gapMs, null, null);
            }
            finally { Current.Value = previous; }
        }

        public static void SetProvider(string providerId, string modelId)
        {
            var state = Current.Value;
            if (state == null) return;
            state.Provider = SafeToken(providerId, 80);
            state.Model = SafeToken(modelId, 160);
            Event("provider_selected", null, "selected", null, null, null);
        }

        public static void CompleteRequest(string status, int successfulWrites, int failedWrites, bool verified)
        {
            var state = Current.Value;
            long elapsed = state != null ? ElapsedMs(state.StartedTicks) : 0;
            Event("request_complete", null, SafeToken(status, 40), elapsed, null,
                "successfulWrites=" + Math.Max(0, successfulWrites) +
                "; failedWrites=" + Math.Max(0, failedWrites) +
                "; verified=" + verified);
            Current.Value = null;
        }

        public static void AbandonRequest(string status, ErrorCode? errorCode)
        {
            var state = Current.Value;
            long elapsed = state != null ? ElapsedMs(state.StartedTicks) : 0;
            Event("request_abort", null, SafeToken(status, 40), elapsed, errorCode, null);
            Current.Value = null;
        }

        public static void Event(
            string eventName,
            string toolName,
            string status,
            long? elapsedMs,
            ErrorCode? errorCode,
            string detail)
        {
            WriteEvent(eventName, toolName, status, elapsedMs, errorCode, detail, null);
        }

        public static void ExceptionEvent(string eventName, string toolName, string status, long? elapsedMs, Exception exception)
        {
            // Numeric HRESULT is actionable without retaining the private exception message.
            WriteEvent(eventName, toolName, status, elapsedMs, null, null, exception != null ? (int?)exception.HResult : null);
        }

        private static void WriteEvent(string eventName, string toolName, string status, long? elapsedMs,
            ErrorCode? errorCode, string detail, int? hresult)
        {
            try
            {
                var state = Current.Value;
                string traceId = state != null ? state.TraceId : "no-trace";
                string provider = state != null ? state.Provider : null;
                string model = state != null ? state.Model : null;
                string host = state != null ? state.Host : null;

                string safeEvent = SafeToken(eventName, 80);
                string safeTool = SafeToken(toolName, 100);
                string safeStatus = SafeToken(status, 80);
                string safeDetail = SafeDetail(detail, 900);

                var o = new JObject
                {
                    ["tsUtc"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                    ["traceId"] = traceId,
                    ["thread"] = Thread.CurrentThread.ManagedThreadId,
                    ["processId"] = ProcessId,
                    ["event"] = safeEvent
                };
                if (!string.IsNullOrEmpty(host)) o["host"] = host;
                if (!string.IsNullOrEmpty(provider)) o["provider"] = provider;
                if (!string.IsNullOrEmpty(model)) o["model"] = model;
                if (!string.IsNullOrEmpty(safeTool)) o["tool"] = safeTool;
                if (!string.IsNullOrEmpty(safeStatus)) o["status"] = safeStatus;
                if (elapsedMs.HasValue) o["elapsedMs"] = Math.Max(0, elapsedMs.Value);
                if (errorCode.HasValue) o["errorCode"] = errorCode.Value.ToString();
                if (hresult.HasValue) o["hresult"] = hresult.Value;
                if (!string.IsNullOrEmpty(safeDetail)) o["detail"] = safeDetail;

                Logger.RuntimeEventJson(o.ToString(Formatting.None));

                var line = new StringBuilder();
                line.Append("trace=").Append(traceId)
                    .Append(" event=").Append(safeEvent);
                if (!string.IsNullOrEmpty(provider)) line.Append(" provider=").Append(provider);
                if (!string.IsNullOrEmpty(model)) line.Append(" model=").Append(model);
                if (!string.IsNullOrEmpty(safeTool)) line.Append(" tool=").Append(safeTool);
                if (!string.IsNullOrEmpty(safeStatus)) line.Append(" status=").Append(safeStatus);
                if (elapsedMs.HasValue) line.Append(" elapsedMs=").Append(Math.Max(0, elapsedMs.Value));
                if (errorCode.HasValue) line.Append(" error=").Append(errorCode.Value);
                if (!string.IsNullOrEmpty(safeDetail)) line.Append(" detail=").Append(safeDetail);
                Logger.RuntimeJourney(line.ToString());
            }
            catch
            {
                // Journal failures must never interrupt Office or provider execution.
            }
        }

        public static long ElapsedMs(long startTicks)
        {
            if (startTicks <= 0) return 0;
            long delta = Stopwatch.GetTimestamp() - startTicks;
            if (delta <= 0) return 0;
            return (long)(delta * 1000.0 / Stopwatch.Frequency);
        }

        public static long StartTimer()
        {
            return Stopwatch.GetTimestamp();
        }

        private static string NewTraceId()
        {
            return Guid.NewGuid().ToString("N").Substring(0, 16);
        }

        private static string SafeToken(string value, int max)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            var sb = new StringBuilder();
            foreach (char ch in value.Trim())
            {
                if (sb.Length >= max) break;
                if (char.IsLetterOrDigit(ch) || ch == '_' || ch == '-' || ch == '.' || ch == ':' || ch == '/')
                    sb.Append(ch);
            }
            return sb.Length == 0 ? null : sb.ToString();
        }

        private static string SafeDetail(string value, int max)
        {
            if (string.IsNullOrWhiteSpace(value)) return null;
            string text = value.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ').Replace('\0', ' ');
            // Redact common secret-bearing labels even though callers should never send them.
            foreach (string marker in new[] { "api_key", "apikey", "authorization", "bearer", "password", "secret", "baseurl", "base_url" })
            {
                int ix = text.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
                if (ix >= 0)
                    text = text.Substring(0, ix) + marker + "=REDACTED";
            }
            if (text.Length > max) text = text.Substring(0, max);
            return text;
        }
    }
}
