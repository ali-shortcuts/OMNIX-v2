# OMNIX consumer-security anti-drift contract. Structural only; real execution remains mandatory.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Missing: $relative"); return '' }
    return Get-Content -LiteralPath $path -Raw
}
function Require([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if (-not $text.Contains($needle)) { $failures.Add("${relative}: missing '$needle' — $reason") }
}
function Forbid([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if ($text.Contains($needle)) { $failures.Add("${relative}: forbidden '$needle' — $reason") }
}
function Parse-Ps([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Missing: $relative"); return }
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    foreach($e in @($errors)){ $failures.Add("${relative}: parser error — $($e.Message)") }
}

Parse-Ps 'tools/consumer-security-acceptance.ps1'
Require 'tools/consumer-security-acceptance.ps1' 'CONSUMER-SECURITY-REAL-001' 'consumer evidence needs a stable TestId.'
Require 'tools/consumer-security-acceptance.ps1' 'RealTimeProtectionEnabled' 'normal Defender real-time protection must be required.'
Require 'tools/consumer-security-acceptance.ps1' 'BehaviorMonitorEnabled' 'behavior monitoring state must be observed.'
Require 'tools/consumer-security-acceptance.ps1' 'Start-MpScan -ScanType CustomScan' 'the exact installer must receive a normal Defender scan.'
Require 'tools/consumer-security-acceptance.ps1' 'InstallerDetectionCount' 'installer-associated detections must be fail-closed.'
Require 'tools/consumer-security-acceptance.ps1' 'SmartScreenDisposition' 'SmartScreen must be explicitly observed through normal UI.'
Require 'tools/consumer-security-acceptance.ps1' "ValidateSet('NotBlocked','WarnedButAllowed','Blocked','NotTested')" 'SmartScreen evidence must distinguish not-tested and blocked.'
Forbid 'tools/consumer-security-acceptance.ps1' 'Add-MpPreference' 'acceptance must never add Defender exclusions.'
Forbid 'tools/consumer-security-acceptance.ps1' 'Set-MpPreference' 'acceptance must never weaken Defender settings.'
Forbid 'tools/consumer-security-acceptance.ps1' 'Remove-MpPreference' 'acceptance must never manipulate Defender exclusions.'
Forbid 'tools/consumer-security-acceptance.ps1' 'Disable-NetAdapter' 'acceptance must never change networking.'
Forbid 'tools/consumer-security-acceptance.ps1' 'New-NetFirewallRule' 'acceptance must never change firewall policy.'

# Canonical entrypoint is intentionally a thin wrapper so policy logic is kept in one auditable core.
# Contract therefore verifies both: wrapper delegation/parameter surface + fail-closed core validation.
Parse-Ps 'tools/final-production-gate.ps1'
Require 'tools/final-production-gate.ps1' 'ConsumerSecurityReport' 'final production entrypoint must accept consumer security evidence.'
Require 'tools/final-production-gate.ps1' 'final-production-core.ps1' 'canonical final entrypoint must delegate to the audited production core.'

Parse-Ps 'tools/final-production-core.ps1'
Require 'tools/final-production-core.ps1' 'ConsumerSecurityReport' 'final production core must consume consumer security evidence.'
Require 'tools/final-production-core.ps1' 'CONSUMER-SECURITY-REAL-001' 'final core must validate the consumer security TestId.'
Require 'tools/final-production-core.ps1' 'Defender.RealTimeProtectionEnabled' 'final core must reject hosted-runner-like protection-off evidence.'
Require 'tools/final-production-core.ps1' 'Defender.BehaviorMonitorEnabled' 'final core must require behavior monitoring.'
Require 'tools/final-production-core.ps1' 'Defender.InstallerDetectionCount' 'final core must fail on Defender detections for the exact installer.'
Require 'tools/final-production-core.ps1' 'SmartScreen.Disposition' 'final core must reject missing/blocked SmartScreen evidence.'
Require 'tools/final-production-core.ps1' 'ConsumerDefenderAndSmartScreen=$true' 'final release requirements must expose consumer protection explicitly.'
Require 'tools/final-production-core.ps1' "OMNIX-FINAL-PRODUCTION-GATE-002" 'final production evidence must use the current stable TestId.'
Forbid 'tools/final-production-core.ps1' 'AllowDevelopmentSignature' 'production core must have no development-signature escape hatch.'

if($failures.Count -gt 0){
    Write-Host 'OMNIX CONSUMER-SECURITY CONTRACT: FAIL' -ForegroundColor Red
    foreach($f in $failures){ Write-Host " - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'OMNIX CONSUMER-SECURITY CONTRACT: PASS'
Write-Host 'Structure is intact; a real protected consumer Windows machine and normal SmartScreen UI observation are still required.'
exit 0
