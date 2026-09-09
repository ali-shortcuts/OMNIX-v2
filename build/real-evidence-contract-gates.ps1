# OMNIX real-evidence anti-drift contract
# Structural checks only. This does NOT replace real Office/provider/security execution.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-RepoFile([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing required file: $relative")
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}

function Require-Contains([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-RepoFile $relative
    if ($text -notlike "*$needle*") {
        $failures.Add("${relative}: missing '$needle' — $reason")
    }
}

function Require-NotContains([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-RepoFile $relative
    if ($text -like "*$needle*") {
        $failures.Add("${relative}: forbidden '$needle' — $reason")
    }
}

function Require-PowerShellParses([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing required PowerShell file: $relative")
        return
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $failures.Add("${relative}: PowerShell parser error — $($parseError.Message)")
    }
}

# Strict two-launch automatic Office load evidence.
Require-PowerShellParses 'tools/real-office-acceptance.ps1'
Require-Contains 'tools/real-office-acceptance.ps1' 'AutomaticLoadEveryRoundPass' 'Two-launch persistence must require automatic load on every round.'
Require-Contains 'tools/real-office-acceptance.ps1' 'InitialConnect' 'Automatic load must be observed before any diagnostic force-connect.'
Require-Contains 'tools/real-office-acceptance.ps1' 'ForceConnectAttempted' 'Force-connect may exist only as diagnostic evidence.'
Require-Contains 'tools/real-office-acceptance.ps1' '$result.AutomaticLoadPass' 'PASS must bind to the initial automatic load state.'
Require-Contains 'tools/real-office-acceptance.ps1' '$result.Registry.Manifest.Exists' 'Registered VSTO manifest target must exist.'
Require-Contains 'tools/real-office-acceptance.ps1' '$installedHostNames.Count -eq $hosts.Count' 'Excel, Word and PowerPoint are all mandatory for final acceptance.'

# Real compiled Office functional evidence across Excel, Word and PowerPoint.
Require-PowerShellParses 'tools/office-functional-acceptance.ps1'
Require-Contains 'tools/office-functional-acceptance.ps1' 'OFFICE-FUNCTIONAL-REAL-001' 'Functional Office evidence needs a stable TestId.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'OMNIX.Core.dll' 'Functional evidence must load the installed compiled core payload.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'ContextReadPass' 'Each Office host must prove real context extraction.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'WriteNoConfirmationBlockedPass' 'Write tools must fail closed without a confirmation callback.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'WriteDeniedBlockedPass' 'A denied preview must not modify Office content.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'WriteApprovedAppliedPass' 'An approved write must actually apply to the temporary Office document.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'PowerPointVisionCapturePass' 'Real PowerPoint slide PNG capture must be exercised.'
Require-Contains 'tools/office-functional-acceptance.ps1' 'ProcessExitedCleanly' 'Each Office host must close without leaving an orphan process.'
Require-NotContains 'tools/office-functional-acceptance.ps1' 'SaveAs' 'Functional acceptance must not save temporary test documents.'
Require-NotContains 'tools/office-functional-acceptance.ps1' 'Restart-Computer' 'Functional acceptance must never restart Windows.'
Require-NotContains 'tools/office-functional-acceptance.ps1' 'Disable-NetAdapter' 'Functional acceptance must never change network state.'

# One-command real Office E2E orchestrator must bind install + persistence + UI + functional evidence.
Require-PowerShellParses 'tools/full-office-e2e.ps1'
Require-Contains 'tools/full-office-e2e.ps1' 'OFFICE-E2E-REAL-001' 'The full Office E2E run needs a stable TestId.'
Require-Contains 'tools/full-office-e2e.ps1' 'real-office-acceptance.ps1' 'E2E must include strict automatic-load/persistence acceptance.'
Require-Contains 'tools/full-office-e2e.ps1' 'real-office-ui-acceptance.ps1' 'E2E must include actual Ribbon/workspace UI acceptance.'
Require-Contains 'tools/full-office-e2e.ps1' 'office-functional-acceptance.ps1' 'E2E must include compiled Office context/read/write/Vision acceptance.'
Require-Contains 'tools/full-office-e2e.ps1' 'Get-FileHash -Algorithm SHA256' 'Installed E2E evidence must bind to the tested installer hash.'
Require-NotContains 'tools/full-office-e2e.ps1' 'Restart-Computer' 'The E2E orchestrator must never restart the user machine.'
Require-NotContains 'tools/full-office-e2e.ps1' 'shutdown.exe' 'The E2E orchestrator must never invoke shutdown/restart.'
Require-NotContains 'tools/full-office-e2e.ps1' 'Disable-NetAdapter' 'The E2E orchestrator must never change network state.'

# Real Windows restart persistence is a two-phase manual-restart gate.
Require-PowerShellParses 'tools/reboot-persistence-acceptance.ps1'
Require-Contains 'tools/reboot-persistence-acceptance.ps1' 'OFFICE-RESTART-PERSISTENCE-REAL-001' 'Release needs a real restart persistence artifact.'
Require-Contains 'tools/reboot-persistence-acceptance.ps1' "ValidateSet('BeforeRestart','AfterRestart')" 'Restart proof must use explicit before/after phases.'
Require-Contains 'tools/reboot-persistence-acceptance.ps1' 'BootSessionChanged' 'AfterRestart must prove a different Windows boot session.'
Require-Contains 'tools/reboot-persistence-acceptance.ps1' 'PreRestartPersistencePass' 'Strict persistence must pass before restart.'
Require-Contains 'tools/reboot-persistence-acceptance.ps1' 'PostRestartPersistencePass' 'Strict persistence must pass after restart.'
Require-NotContains 'tools/reboot-persistence-acceptance.ps1' 'Restart-Computer' 'Acceptance tooling must never restart the user machine automatically.'
Require-NotContains 'tools/reboot-persistence-acceptance.ps1' 'shutdown.exe' 'Acceptance tooling must never invoke a shutdown/restart command.'

# Local AI offline evidence must observe no public Internet and a real local model round-trip.
Require-PowerShellParses 'tools/local-offline-acceptance.ps1'
Require-Contains 'tools/local-offline-acceptance.ps1' 'LOCAL-AI-OFFLINE-REAL-001' 'Release needs dedicated offline local-AI evidence.'
Require-Contains 'tools/local-offline-acceptance.ps1' 'InternetDisconnectedObserved' 'Offline proof must record that public HTTPS was not reachable.'
Require-Contains 'tools/local-offline-acceptance.ps1' 'AtLeastOneLocalRuntimePass' 'Offline proof must require a real Ollama or LM Studio round-trip.'
Require-Contains 'tools/local-offline-acceptance.ps1' 'http://localhost:11434/api/chat' 'Ollama must be exercised locally.'
Require-Contains 'tools/local-offline-acceptance.ps1' 'http://localhost:1234/v1/chat/completions' 'LM Studio must be exercised locally.'
Require-NotContains 'tools/local-offline-acceptance.ps1' 'Disable-NetAdapter' 'Acceptance tooling must not disable user networking.'
Require-NotContains 'tools/local-offline-acceptance.ps1' 'New-NetFirewallRule' 'Acceptance tooling must not alter firewall policy.'
Require-NotContains 'tools/local-offline-acceptance.ps1' 'Set-NetFirewallProfile' 'Acceptance tooling must not alter firewall policy.'

# Provider evidence must use live discovery and real streaming transport.
Require-PowerShellParses 'tools/provider-acceptance.ps1'
Require-Contains 'tools/provider-acceptance.ps1' 'Invoke-StreamingHttp' 'Provider acceptance must exercise streaming transport.'
Require-Contains 'tools/provider-acceptance.ps1' 'ResponseHeadersRead' 'Streaming proof must not wait for the full response body before reading events.'
Require-Contains 'tools/provider-acceptance.ps1' 'StreamingPass' 'Provider evidence must record streaming success separately.'
Require-Contains 'tools/provider-acceptance.ps1' 'FirstStreamEventMs' 'Provider evidence must record first stream event timing.'
Require-Contains 'tools/provider-acceptance.ps1' 'ModelSource' 'Provider evidence must record live model discovery source.'
Require-Contains 'tools/provider-acceptance.ps1' "PreferredExact @('openrouter/free')" 'OpenRouter free router must be preferred first.'
Require-Contains 'tools/provider-acceptance.ps1' "PreferredSuffix @(':free')" 'OpenRouter :free variants must be preferred before non-free routes.'
Require-NotContains 'tools/provider-acceptance.ps1' 'gemini-3.8-flash' 'Provider acceptance must use live Gemini discovery instead of depending on one fixed model id.'

# Privacy must be proven through the real AiGateway/PrivacyGate runtime, not only source strings.
Require-PowerShellParses 'tools/privacy-acceptance.ps1'
Require-Contains 'tools/privacy-acceptance.ps1' 'PRIVACY-GATE-RUNTIME-001' 'Privacy acceptance needs a stable evidence TestId.'
Require-Contains 'tools/privacy-acceptance.ps1' 'LocalOnlyAllCloudRoutesBlocked' 'LocalOnly must be exercised across registered cloud routes.'
Require-Contains 'tools/privacy-acceptance.ps1' 'LocalOnlyFakeCloudSendPrevented' 'Instrumented cloud SendAsync must remain untouched under LocalOnly.'
Require-Contains 'tools/privacy-acceptance.ps1' 'AskDeniedBlockedBeforeSend' 'AskBeforeSending denial must prevent provider SendAsync.'
Require-Contains 'tools/privacy-acceptance.ps1' 'AskApprovedBeforeSend' 'Approval callback must be observed before provider SendAsync.'
Require-Contains 'tools/privacy-acceptance.ps1' 'AskRememberSessionPass' 'Session-scoped remembered approval behavior must be tested.'
Require-Contains 'tools/privacy-acceptance.ps1' 'CloudAllowedNoPromptPass' 'CloudAllowed must bypass confirmation without bypassing gateway routing.'
Require-Contains 'tools/privacy-acceptance.ps1' 'LocalOnlyLocalRoutePass' 'LocalOnly must still permit an explicitly available local route.'
Require-NotContains 'tools/privacy-acceptance.ps1' 'HttpClient' 'Deterministic privacy acceptance must not create an outbound HTTP client.'
Require-NotContains 'tools/privacy-acceptance.ps1' 'WebRequest' 'Deterministic privacy acceptance must not perform web requests.'
Require-Contains '.github/workflows/build.yml' 'Runtime AI Gateway privacy acceptance' 'Windows CI must execute the privacy runtime test after OMNIX.Core builds.'
Require-Contains '.github/workflows/build.yml' 'privacy-acceptance.json' 'CI artifacts must preserve privacy runtime evidence.'
Require-Contains '.github/workflows/build.yml' 'PrivacyGatewayRuntimePass' 'Development artifact metadata must record privacy runtime result.'

# Final readiness must consume strict persistence, UI, restart, offline-local, provider and privacy evidence.
Require-PowerShellParses 'tools/release-readiness.ps1'
Require-Contains 'tools/release-readiness.ps1' 'OfficeRestartReport' 'Final readiness must consume Windows restart evidence.'
Require-Contains 'tools/release-readiness.ps1' 'Test-OfficeRestart' 'Final readiness must validate restart evidence fail-closed.'
Require-Contains 'tools/release-readiness.ps1' 'LocalOfflineReport' 'Final readiness must consume dedicated offline local-AI evidence.'
Require-Contains 'tools/release-readiness.ps1' 'Test-LocalOffline' 'Final readiness must validate offline local-AI evidence fail-closed.'
Require-Contains 'tools/release-readiness.ps1' 'PrivacyReport' 'Final readiness must consume compiled privacy runtime evidence.'
Require-Contains 'tools/release-readiness.ps1' 'Test-PrivacyGateway' 'Final readiness must validate compiled gateway privacy behavior fail-closed.'
Require-Contains 'tools/release-readiness.ps1' 'PrivacyGatewayRuntime' 'Final evidence must summarize privacy runtime results.'
Require-Contains 'tools/release-readiness.ps1' 'GatewayPrivacyOrderingRuntime' 'Final release must require privacy enforcement before provider SendAsync.'
Require-Contains 'tools/release-readiness.ps1' 'AutomaticLoadWithoutForceConnect' 'Final evidence must state the automatic-load invariant.'
Require-Contains 'tools/release-readiness.ps1' 'WindowsRestartPersistence' 'Final evidence must state restart persistence as mandatory.'
Require-Contains 'tools/release-readiness.ps1' 'LocalAiWithInternetDisconnected' 'Final evidence must state offline local AI as mandatory.'
Require-Contains 'tools/release-readiness.ps1' 'LiveProviderModelDiscovery' 'Final release must require live provider model discovery.'
Require-Contains 'tools/release-readiness.ps1' 'StreamingProviderRoundTrips' 'Final release must require provider streaming evidence.'
Require-Contains 'tools/release-readiness.ps1' 'OpenRouterFreeRoutePriority' 'Final release must require OpenRouter free-route priority when cloud providers are required.'
Require-Contains 'tools/release-readiness.ps1' 'WorkspaceEvidenceVisible' 'Ribbon/workspace proof must require visible rendered UI.'
Require-Contains 'tools/release-readiness.ps1' 'ProductionAuthenticode' 'Production trust must remain a distinct release requirement.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX REAL-EVIDENCE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX REAL-EVIDENCE CONTRACT: PASS'
Write-Host 'Structural evidence gates are intact. Deterministic gateway privacy runtime is executed in build CI; real Office E2E/restart/provider/consumer-machine security execution remains separate.'
exit 0
