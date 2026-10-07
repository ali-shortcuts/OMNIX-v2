using System;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Errors;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Layer 9 resilience. Retries only failures that are reasonably transient; authentication,
    /// model/configuration, privacy, quota/rate-limit and other deterministic failures fail fast.
    /// Provider response bodies are never copied into retry diagnostics.
    /// </summary>
    public static class RetryPolicy
    {
        // Cancellation must release the caller even if an adapter/socket ignores its token.
        // This cancels waiting, not remote execution. Never pass abandoned results to Office.
        public static async Task<T> WaitWithCancellationAsync<T>(Task<T> pending, CancellationToken ct)
        {
            if (pending == null) throw new ArgumentNullException("pending");
            // Observe a late fault after cancellation without logging private transport payloads.
            pending.ContinueWith(task => { var observed = task.Exception; }, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
            ct.ThrowIfCancellationRequested();
            if (!ct.CanBeCanceled) return await pending.ConfigureAwait(false);
            var cancelled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            using (ct.Register(() => cancelled.TrySetResult(true)))
            {
                await Task.WhenAny(pending, cancelled.Task).ConfigureAwait(false);
                // Cancellation wins a completion race; an old tool result must not reach Office.
                ct.ThrowIfCancellationRequested();
                return await pending.ConfigureAwait(false);
            }
        }

        public static async Task<T> ExecuteWithRetryAsync<T>(Func<CancellationToken, Task<T>> action, CancellationToken ct)
        {
            if (action == null) throw new ArgumentNullException("action");

            int retryCount = 0;
            while (true)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    return await action(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (OmnixException ex)
                {
                    if (!IsRetryable(ex) || retryCount >= 2) throw;
                    retryCount++;
                    await Task.Delay(GetDelayMs(ex, retryCount), ct).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    // Adapters are expected to normalize transport failures into OmnixException.
                    // Give an unknown transport failure one defensive retry, then return only the
                    // exception type in technical diagnostics (exception messages can contain URLs,
                    // account data or provider payload fragments).
                    if (retryCount >= 1)
                        throw OmnixException.Provider("Unexpected transport failure type=" + ex.GetType().Name + "; provider_response_body=REDACTED");
                    retryCount++;
                    await Task.Delay(400, ct).ConfigureAwait(false);
                }
            }
        }

        public static bool IsRetryable(OmnixException ex)
        {
            if (ex == null) return false;
            if (ex.Code == ErrorCode.NETWORK_ERROR || ex.Code == ErrorCode.TIMEOUT) return true;
            if (ex.Code != ErrorCode.PROVIDER_ERROR) return false;

            string details = ex.TechnicalDetails ?? string.Empty;
            return details.IndexOf("category=provider_unavailable", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   details.IndexOf("category=provider_timeout", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static int GetDelayMs(OmnixException ex, int retryCount)
        {
            bool providerOutage = ex != null && ex.Code == ErrorCode.PROVIDER_ERROR;
            if (providerOutage)
                return retryCount <= 1 ? 750 : 1800;
            return retryCount <= 1 ? 400 : 1200;
        }
    }

    /// <summary>
    /// Compatibility helper retained for older callers. New gateway routing uses
    /// ProviderHealthTracker so failure streaks are isolated per provider.
    /// </summary>
    public sealed class FailoverPolicy
    {
        private int _consecutiveFailures;
        private readonly int _threshold;

        public FailoverPolicy(int threshold = 3)
        {
            _threshold = threshold;
        }

        public void RecordSuccess()
        {
            _consecutiveFailures = 0;
        }

        public void RecordFailure()
        {
            _consecutiveFailures++;
        }

        public bool ShouldSuggestFailover
        {
            get { return _consecutiveFailures >= _threshold; }
        }
    }
}
