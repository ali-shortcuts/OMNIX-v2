[CmdletBinding()]
param(
    [string]$CorePath = '.\src\OMNIX.Core\bin\Release\OMNIX.Core.dll',
    [string]$OutputPath = '.\build\artifact\provider-resilience-acceptance.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = (Resolve-Path -LiteralPath $CorePath).Path
$dependency = Join-Path (Split-Path -Parent $core) 'Newtonsoft.Json.dll'
if (Test-Path $dependency) { [void][Reflection.Assembly]::LoadFrom($dependency) }
[void][Reflection.Assembly]::LoadFrom($core)

$source = @'
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Errors;

public static class AdaptiveProviderResilienceHarness
{
    private static OmnixException ProviderError(string category)
    {
        return new OmnixException(
            ErrorCode.PROVIDER_ERROR,
            "Synthetic provider failure.",
            "Provider=fixture; HTTP=503; category=" + category + "; provider_response_body=REDACTED",
            "Synthetic fix.");
    }

    private static void Put(Dictionary<string, bool> checks, string name, bool value)
    {
        checks[name] = value;
    }

    public static Dictionary<string, bool> Run()
    {
        var checks = new Dictionary<string, bool>();

        var latency = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(80), TimeSpan.FromMilliseconds(250));
        Put(checks, "InitialProviderHealthy", !latency.IsCircuitOpen("latency") && latency.GetRoutingPenalty("latency") == 0);
        latency.RecordSuccess("latency", 100);
        latency.RecordSuccess("latency", 300);
        var latencySnapshot = latency.GetSnapshot("latency");
        Put(checks, "LatencyEwma", latencySnapshot.AverageLatencyMs == 150 && latencySnapshot.SuccessCount == 2);

        var outage = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(80), TimeSpan.FromMilliseconds(250));
        outage.RecordFailure("outage", OmnixException.Network("synthetic network failure"));
        Put(checks, "FirstAvailabilityFailureDoesNotOpenCircuit", !outage.IsCircuitOpen("outage"));
        outage.RecordFailure("outage", OmnixException.Timeout("synthetic timeout"));
        Put(checks, "SecondAvailabilityFailureOpensCircuit", outage.IsCircuitOpen("outage"));
        Put(checks, "OpenCircuitHasDominantPenalty", outage.GetRoutingPenalty("outage") >= 1000000);
        Thread.Sleep(120);
        Put(checks, "CircuitRecoversAfterCooldown", !outage.IsCircuitOpen("outage"));
        outage.RecordSuccess("outage", 75);
        var recovered = outage.GetSnapshot("outage");
        Put(checks, "SuccessResetsAvailabilityState", !recovered.IsCircuitOpen && recovered.ConsecutiveAvailabilityFailures == 0 && recovered.LastErrorCode == ErrorCode.None);

        var auth = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100));
        auth.RecordFailure("auth", OmnixException.Auth("synthetic auth failure"));
        auth.RecordFailure("auth", OmnixException.Auth("synthetic auth failure"));
        Put(checks, "AuthFailureDoesNotOpenCircuit", !auth.IsCircuitOpen("auth"));
        Put(checks, "AuthFailureGetsRoutingPenalty", auth.GetRoutingPenalty("auth") >= 5000);

        var model = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100));
        model.RecordFailure("model", OmnixException.Model("synthetic model failure"));
        model.RecordFailure("model", OmnixException.Model("synthetic model failure"));
        Put(checks, "ModelFailureDoesNotOpenCircuit", !model.IsCircuitOpen("model"));

        var deterministic = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100));
        deterministic.RecordFailure("large", ProviderError("request_too_large"));
        deterministic.RecordFailure("large", ProviderError("request_too_large"));
        Put(checks, "RequestTooLargeDoesNotPoisonAvailability", !deterministic.IsCircuitOpen("large"));

        var quota = new ProviderHealthTracker(2, TimeSpan.FromMilliseconds(80), TimeSpan.FromMilliseconds(160));
        quota.RecordFailure("quota", ProviderError("rate_limit_or_quota"));
        quota.RecordFailure("quota", ProviderError("rate_limit_or_quota"));
        Put(checks, "RateLimitUsesShortCircuitPressure", quota.IsCircuitOpen("quota"));

        int outageCalls = 0;
        int outageResult = RetryPolicy.ExecuteWithRetryAsync<int>(ct =>
        {
            outageCalls++;
            if (outageCalls < 3) throw ProviderError("provider_unavailable");
            return Task.FromResult(42);
        }, CancellationToken.None).GetAwaiter().GetResult();
        Put(checks, "ProviderOutageRetriesThenSucceeds", outageResult == 42 && outageCalls == 3);

        int quotaCalls = 0;
        try
        {
            RetryPolicy.ExecuteWithRetryAsync<int>(ct =>
            {
                quotaCalls++;
                throw ProviderError("rate_limit_or_quota");
            }, CancellationToken.None).GetAwaiter().GetResult();
            Put(checks, "RateLimitFailsFast", false);
        }
        catch (OmnixException)
        {
            Put(checks, "RateLimitFailsFast", quotaCalls == 1);
        }

        int authCalls = 0;
        try
        {
            RetryPolicy.ExecuteWithRetryAsync<int>(ct =>
            {
                authCalls++;
                throw OmnixException.Auth("synthetic auth failure");
            }, CancellationToken.None).GetAwaiter().GetResult();
            Put(checks, "AuthFailsFast", false);
        }
        catch (OmnixException ex)
        {
            Put(checks, "AuthFailsFast", ex.Code == ErrorCode.AUTH_ERROR && authCalls == 1);
        }

        int cancelCalls = 0;
        using (var cts = new CancellationTokenSource())
        {
            cts.Cancel();
            try
            {
                RetryPolicy.ExecuteWithRetryAsync<int>(ct =>
                {
                    cancelCalls++;
                    return Task.FromResult(1);
                }, cts.Token).GetAwaiter().GetResult();
                Put(checks, "PreCancelledRequestDoesNotSend", false);
            }
            catch (OperationCanceledException)
            {
                Put(checks, "PreCancelledRequestDoesNotSend", cancelCalls == 0);
            }
        }

        const string secretMarker = "SUPER-SECRET-PROVIDER-BODY-MARKER";
        int unknownCalls = 0;
        try
        {
            RetryPolicy.ExecuteWithRetryAsync<int>(ct =>
            {
                unknownCalls++;
                throw new InvalidOperationException(secretMarker);
            }, CancellationToken.None).GetAwaiter().GetResult();
            Put(checks, "UnexpectedTransportIsRedacted", false);
        }
        catch (OmnixException ex)
        {
            Put(checks, "UnexpectedTransportRetriesOnce", unknownCalls == 2);
            Put(checks, "UnexpectedTransportIsRedacted",
                ex.TechnicalDetails.IndexOf(secretMarker, StringComparison.Ordinal) < 0 &&
                ex.TechnicalDetails.IndexOf("provider_response_body=REDACTED", StringComparison.OrdinalIgnoreCase) >= 0);
        }

        Put(checks, "RetryClassifierRejectsDeterministicProviderError", !RetryPolicy.IsRetryable(ProviderError("request_rejected")));
        Put(checks, "RetryClassifierAcceptsOutage", RetryPolicy.IsRetryable(ProviderError("provider_unavailable")));
        Put(checks, "RetryClassifierAcceptsNetwork", RetryPolicy.IsRetryable(OmnixException.Network("synthetic")));

        return checks;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core, 'System.Core.dll')
$checks = [AdaptiveProviderResilienceHarness]::Run()
$failures = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
$report = [ordered]@{
    TestId = 'PROVIDER-ADAPTIVE-RESILIENCE-RUNTIME-001'
    SourceCommit = (git rev-parse HEAD).Trim()
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    CheckCount = $checks.Count
    Checks = $checks
    FailureCount = $failures.Count
    Failures = $failures
    OverallPass = ($failures.Count -eq 0)
}
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force $outDir | Out-Null }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8
if ($failures.Count -gt 0) { exit 1 }
