using System;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Errors;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Layer 9 resilience: exponential backoff for transient network/timeout failures
    /// (spec Phase 12.3) and consecutive-failure tracking for failover suggestions
    /// (spec Phase 12.4).
    /// </summary>
    public static class RetryPolicy
    {
        public static async Task<T> ExecuteWithRetryAsync<T>(Func<CancellationToken, Task<T>> action, CancellationToken ct)
        {
            int attempt = 0;
            while (true)
            {
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
                    bool transient = ex.Code == ErrorCode.NETWORK_ERROR || ex.Code == ErrorCode.TIMEOUT;
                    if (!transient || attempt >= 2) throw;
                    attempt++;
                    int delayMs = attempt == 1 ? 1000 : 2000;
                    await Task.Delay(delayMs, ct).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    if (attempt >= 2) throw OmnixException.Provider("Unexpected transport failure: " + ex.Message);
                    attempt++;
                    await Task.Delay(1000, ct).ConfigureAwait(false);
                }
            }
        }
    }

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
