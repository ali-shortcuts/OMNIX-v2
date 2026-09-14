# OMNIX adaptive provider engine anti-drift contract.
# Structural checks complement the compiled provider-resilience acceptance.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing: $relative")
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}
function Require([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if ($text.IndexOf($needle,[StringComparison]::Ordinal) -lt 0) {
        $failures.Add("${relative}: missing '$needle' — $reason")
    }
}
function Forbid([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if ($text.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $failures.Add("${relative}: forbidden '$needle' — $reason")
    }
}

$health = 'src/OMNIX.Core/AiGateway/ProviderHealth.cs'
$gateway = 'src/OMNIX.Core/AiGateway/AiGateway.cs'
$router = 'src/OMNIX.Core/AiGateway/PrivacyGate.cs'
$resilience = 'src/OMNIX.Core/AiGateway/Resilience.cs'
$acceptance = 'tools/provider-resilience-acceptance.ps1'
$workflow = '.github/workflows/request-budget.yml'

foreach ($needle in @(
    'ProviderHealthTracker',
    'AverageLatencyMs',
    'CircuitOpenUntilUtc',
    'ShouldOpenCircuit(OmnixException error)',
    'RecordFailure(string providerId, OmnixException error)',
    'category=provider_unavailable',
    'category=rate_limit_or_quota'
)) { Require $health $needle 'adaptive provider state/classification drifted.' }
Forbid $health 'ChatRequest' 'health telemetry must never retain request/prompt content.'
Forbid $health 'ApiKey' 'health telemetry must never retain provider secrets.'

foreach ($needle in @(
    'ProviderHealthTracker _health',
    '_health.RecordFailure(provider.Info.Id, ex)',
    '_health.RecordSuccess(provider.Info.Id, sw.ElapsedMilliseconds)',
    '_health.IsCircuitOpen(provider.Info.Id)',
    'SuggestAlternative(provider, req.HasImages',
    'never silently moves Office data'
)) { Require $gateway $needle 'Gateway must use the adaptive provider engine without silent cloud failover.' }

$privacyIndex = (Read-Repo $gateway).IndexOf('await _privacy.EnsureAllowedAsync(provider)',[StringComparison]::Ordinal)
$sendIndex = (Read-Repo $gateway).IndexOf('provider.SendAsync(req',[StringComparison]::Ordinal)
if ($privacyIndex -lt 0 -or $sendIndex -lt 0 -or $privacyIndex -gt $sendIndex) {
    $failures.Add('AiGateway privacy ordering changed: privacy confirmation must remain before provider SendAsync.')
}

Require $router 'ThenBy(x => _health != null ? _health.GetRoutingPenalty(x.Info.Id) : 0)' 'compatible local providers must be health-ranked.'
Require $router '_health.IsCircuitOpen(provider.Info.Id)' 'router must exclude local providers with an open circuit.'
Require $resilience 'IsRetryable(OmnixException ex)' 'retry classification must remain centralized.'
Require $resilience 'provider_response_body=REDACTED' 'unexpected transport diagnostics must remain redacted.'
Require 'src/OMNIX.Core/OMNIX.Core.csproj' 'AiGateway\ProviderHealth.cs' 'adaptive provider source must compile into OMNIX.Core.'

foreach ($needle in @(
    'PROVIDER-ADAPTIVE-RESILIENCE-RUNTIME-001',
    'RequestTooLargeDoesNotPoisonAvailability',
    'ProviderOutageRetriesThenSucceeds',
    'RateLimitFailsFast',
    'AuthFailsFast',
    'UnexpectedTransportIsRedacted'
)) { Require $acceptance $needle 'compiled adaptive resilience behavior must remain covered.' }
Require $workflow 'Execute adaptive provider resilience acceptance' 'compiled adaptive resilience acceptance must run in CI.'
Require $workflow 'provider-resilience-acceptance.json' 'adaptive resilience report must be validated and uploaded.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX ADAPTIVE-PROVIDER CONTRACT: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX ADAPTIVE-PROVIDER-CONTRACT-001: PASS'
Write-Host 'Per-provider health, latency, circuit-breaker, precise retry classification, privacy ordering and suggestion-only failover are structurally intact.'
exit 0
