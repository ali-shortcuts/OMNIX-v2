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

# Final readiness must consume strict persistence, UI, restart, offline-local and provider evidence.
Require-PowerShellParses 'tools/release-readiness.ps1'
Require-Contains 'tools/release-readiness.ps1' 'OfficeRestartReport' 'Final readiness must consume Windows restart evidence.'
Require-Contains 'tools/release-readiness.ps1' 'Test-OfficeRestart' 'Final readiness must validate restart evidence fail-closed.'
Require-Contains 'tools/release-readiness.ps1' 'AutomaticLoadWithoutForceConnect' 'Final evidence must state the automatic-load invariant.'
Require-Contains 'tools/release-readiness.ps1' 'WindowsRestartPersistence' 'Final evidence must state restart persistence as mandatory.'
Require-Contains 'tools/release-readiness.ps1' 'WorkspaceEvidenceVisible' 'Ribbon/workspace proof must require visible rendered UI.'
Require-Contains 'tools/release-readiness.ps1' 'ProductionAuthenticode' 'Production trust must remain a distinct release requirement.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX REAL-EVIDENCE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX REAL-EVIDENCE CONTRACT: PASS'
Write-Host 'Structural evidence gates are intact. Real Office/restart/provider/security execution is still required.'
exit 0
