using System;
using System.Collections.Generic;
using OMNIX.Core.Errors;

namespace OMNIX.Core.AiGateway
{
    /// <summary>
    /// Read-only provider health snapshot used by routing, diagnostics and UI.
    /// No prompts, Office content, API keys or provider response bodies are retained here.
    /// </summary>
    public sealed class ProviderHealthSnapshot
    {
        public string ProviderId { get; internal set; }
        public int SuccessCount { get; internal set; }
        public int FailureCount { get; internal set; }
        public int ConsecutiveAvailabilityFailures { get; internal set; }
        public long AverageLatencyMs { get; internal set; }
        public DateTime? LastSuccessUtc { get; internal set; }
        public DateTime? LastFailureUtc { get; internal set; }
        public DateTime? CircuitOpenUntilUtc { get; internal set; }
        public ErrorCode LastErrorCode { get; internal set; }
        public bool IsCircuitOpen { get; internal set; }
        public int RoutingPenalty { get; internal set; }
    }

    /// <summary>
    /// Adaptive, in-memory provider health engine.
    ///
    /// - Tracks every provider independently instead of using one global failure counter.
    /// - Opens a short circuit only for availability/outage or rate-limit pressure.
    /// - Deterministic request/config errors never poison provider availability.
    /// - Uses bounded exponential cooldowns so a broken provider cannot repeatedly stall Office.
    /// - Maintains a latency EWMA used only to rank compatible failover/local candidates.
    /// - Never persists user data and never silently changes cloud providers.
    /// </summary>
    public sealed class ProviderHealthTracker
    {
        private sealed class State
        {
            public int SuccessCount;
            public int FailureCount;
            public int ConsecutiveAvailabilityFailures;
            public int CircuitOpenCount;
            public long AverageLatencyMs;
            public DateTime? LastSuccessUtc;
            public DateTime? LastFailureUtc;
            public DateTime? CircuitOpenUntilUtc;
            public ErrorCode LastErrorCode;
        }

        private readonly object _gate = new object();
        private readonly Dictionary<string, State> _states =
            new Dictionary<string, State>(StringComparer.OrdinalIgnoreCase);
        private readonly int _failureThreshold;
        private readonly TimeSpan _baseCooldown;
        private readonly TimeSpan _maxCooldown;

        public ProviderHealthTracker()
            : this(2, TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(5))
        {
        }

        public ProviderHealthTracker(int failureThreshold, TimeSpan baseCooldown, TimeSpan maxCooldown)
        {
            if (failureThreshold < 1) failureThreshold = 1;
            if (baseCooldown <= TimeSpan.Zero) baseCooldown = TimeSpan.FromSeconds(1);
            if (maxCooldown < baseCooldown) maxCooldown = baseCooldown;
            _failureThreshold = failureThreshold;
            _baseCooldown = baseCooldown;
            _maxCooldown = maxCooldown;
        }

        public void RecordSuccess(string providerId, long latencyMs)
        {
            if (string.IsNullOrWhiteSpace(providerId)) return;
            lock (_gate)
            {
                var state = GetOrCreate(providerId);
                state.SuccessCount++;
                state.ConsecutiveAvailabilityFailures = 0;
                state.LastSuccessUtc = DateTime.UtcNow;
                state.LastErrorCode = ErrorCode.None;
                state.CircuitOpenUntilUtc = null;
                if (state.CircuitOpenCount > 0) state.CircuitOpenCount--;

                if (latencyMs > 0)
                {
                    if (state.AverageLatencyMs <= 0) state.AverageLatencyMs = latencyMs;
                    else state.AverageLatencyMs = ((state.AverageLatencyMs * 3L) + latencyMs) / 4L;
                }
            }
        }

        /// <summary>
        /// Records a coarse failure classification. This overload is used by local connectivity
        /// probes where no provider HTTP category exists.
        /// </summary>
        public void RecordFailure(string providerId, ErrorCode code)
        {
            RecordFailureCore(providerId, code, IsAvailabilityFailure(code));
        }

        /// <summary>
        /// Records a gateway/provider failure with enough classification to avoid treating
        /// deterministic request/config errors as provider availability outages.
        /// </summary>
        public void RecordFailure(string providerId, OmnixException error)
        {
            if (error == null)
            {
                RecordFailureCore(providerId, ErrorCode.PROVIDER_ERROR, true);
                return;
            }
            RecordFailureCore(providerId, error.Code, ShouldOpenCircuit(error));
        }

        public bool IsCircuitOpen(string providerId)
        {
            return GetSnapshot(providerId).IsCircuitOpen;
        }

        public TimeSpan GetRemainingCooldown(string providerId)
        {
            lock (_gate)
            {
                State state;
                if (string.IsNullOrWhiteSpace(providerId) || !_states.TryGetValue(providerId, out state) ||
                    !state.CircuitOpenUntilUtc.HasValue)
                    return TimeSpan.Zero;

                var remaining = state.CircuitOpenUntilUtc.Value - DateTime.UtcNow;
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }

        public int GetRoutingPenalty(string providerId)
        {
            return GetSnapshot(providerId).RoutingPenalty;
        }

        public ProviderHealthSnapshot GetSnapshot(string providerId)
        {
            string id = providerId ?? string.Empty;
            lock (_gate)
            {
                State state;
                if (!_states.TryGetValue(id, out state))
                {
                    return new ProviderHealthSnapshot
                    {
                        ProviderId = id,
                        LastErrorCode = ErrorCode.None,
                        RoutingPenalty = 0,
                        IsCircuitOpen = false
                    };
                }

                DateTime now = DateTime.UtcNow;
                bool open = state.CircuitOpenUntilUtc.HasValue && state.CircuitOpenUntilUtc.Value > now;
                int penalty = 0;

                if (open)
                {
                    penalty = 1000000;
                }
                else
                {
                    penalty += state.ConsecutiveAvailabilityFailures * 600;
                    if (state.AverageLatencyMs > 0)
                        penalty += (int)Math.Min(1500L, state.AverageLatencyMs / 10L);

                    if (state.LastFailureUtc.HasValue && state.LastFailureUtc.Value > now.AddMinutes(-10))
                    {
                        if (state.LastErrorCode == ErrorCode.AUTH_ERROR || state.LastErrorCode == ErrorCode.MODEL_ERROR)
                            penalty += 5000;
                        else if (IsAvailabilityFailure(state.LastErrorCode))
                            penalty += 1200;
                    }
                }

                return new ProviderHealthSnapshot
                {
                    ProviderId = id,
                    SuccessCount = state.SuccessCount,
                    FailureCount = state.FailureCount,
                    ConsecutiveAvailabilityFailures = state.ConsecutiveAvailabilityFailures,
                    AverageLatencyMs = state.AverageLatencyMs,
                    LastSuccessUtc = state.LastSuccessUtc,
                    LastFailureUtc = state.LastFailureUtc,
                    CircuitOpenUntilUtc = state.CircuitOpenUntilUtc,
                    LastErrorCode = state.LastErrorCode,
                    IsCircuitOpen = open,
                    RoutingPenalty = penalty
                };
            }
        }

        public static bool IsAvailabilityFailure(ErrorCode code)
        {
            return code == ErrorCode.NETWORK_ERROR ||
                   code == ErrorCode.TIMEOUT ||
                   code == ErrorCode.PROVIDER_ERROR;
        }

        public static bool ShouldOpenCircuit(OmnixException error)
        {
            if (error == null) return true;
            if (error.Code == ErrorCode.NETWORK_ERROR || error.Code == ErrorCode.TIMEOUT) return true;
            if (error.Code != ErrorCode.PROVIDER_ERROR) return false;

            string details = error.TechnicalDetails ?? string.Empty;
            return details.IndexOf("category=provider_unavailable", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   details.IndexOf("category=provider_timeout", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   details.IndexOf("category=rate_limit_or_quota", StringComparison.OrdinalIgnoreCase) >= 0 ||
                   details.IndexOf("category=circuit_open", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private void RecordFailureCore(string providerId, ErrorCode code, bool availabilityFailure)
        {
            if (string.IsNullOrWhiteSpace(providerId)) return;
            lock (_gate)
            {
                var state = GetOrCreate(providerId);
                state.FailureCount++;
                state.LastFailureUtc = DateTime.UtcNow;
                state.LastErrorCode = code;

                if (!availabilityFailure)
                {
                    state.ConsecutiveAvailabilityFailures = 0;
                    return;
                }

                state.ConsecutiveAvailabilityFailures++;
                if (state.ConsecutiveAvailabilityFailures < _failureThreshold) return;

                state.ConsecutiveAvailabilityFailures = 0;
                state.CircuitOpenCount++;
                double multiplier = Math.Pow(2.0, Math.Min(6, state.CircuitOpenCount - 1));
                long ticks = (long)Math.Min(_maxCooldown.Ticks, _baseCooldown.Ticks * multiplier);
                state.CircuitOpenUntilUtc = DateTime.UtcNow.AddTicks(ticks);
            }
        }

        private State GetOrCreate(string providerId)
        {
            State state;
            if (!_states.TryGetValue(providerId, out state))
            {
                state = new State();
                _states[providerId] = state;
            }
            return state;
        }
    }
}
