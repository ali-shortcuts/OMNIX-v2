# OMNIX FINAL production gate
#
# This is the last evidence aggregator. It NEVER installs/uninstalls Office, restarts Windows,
# changes networking/security policy, signs binaries, calls providers, or manufactures evidence.
# It consumes evidence produced by the real-machine acceptance tools and fails closed.
#
# Required before PASS:
#   - base release-readiness gate PASS (real Office persistence/UI, reboot, offline local AI,
#     provider streaming/model discovery, compiled privacy ordering, trusted Authenticode)
#   - full Office E2E schema >= 2 PASS, cryptographically bound to THIS installer
#   - real Office -> AI Gateway/provider -> rendered WPF marker round-trip PASS in all 3 hosts
#   - lifecycle AfterUninstall PASS (repair/settings/registration/Resiliency/uninstall trust cleanup)
#
# This script intentionally has NO development-signature escape hatch.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InstallerPath,

    [string]$OfficeE2EReport = "$env:LOCALAPPDATA\OMNIX\logs\full-office-e2e.json",
    [string]$LifecycleReport = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json",

    [string]$OfficePersistenceReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-acceptance.json",
    [string]$OfficeUiReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-ui-acceptance.json",
    [string]$OfficeRestartReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-restart-acceptance.json",
    [string]$LocalOfflineReport = "$env:LOCALAPPDATA\OMNIX\logs\local-ai-offline-acceptance.json",
    [string]$ProviderReport = "$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [string]$PrivacyReport = ".\build\artifact\privacy-acceptance.json",

    [string]$BaseReadinessOutput = ".\release-evidence\release-readiness.json",
    [string]$OutputPath = ".\release-evidence\final-production-gate.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Json([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$label not found: $path" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw "$label is not valid JSON: $path — $($_.Exception.Message)" }
}

function Get-GitHead {
    try {
        $sha = (& git rev-parse HEAD 2>$null).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -eq 0 -and $sha -match '^[0-9a-f]{40}$') { return $sha }
    } catch { }
    return $null
}

function Add-Failure($list, [string]$message) {
    if (-not [string]::IsNullOrWhiteSpace($message)) { $list.Add($message) }
}

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small: $($installer.Length) bytes" }
$installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$readinessScript = Join-Path $scriptDir 'release-readiness.ps1'
if (-not (Test-Path -LiteralPath $readinessScript -PathType Leaf)) { throw "Base release-readiness script missing: $readinessScript" }

$baseDir = Split-Path -Parent $BaseReadinessOutput
if ($baseDir) { New-Item -ItemType Directory -Force -Path $baseDir | Out-Null }
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# Run the existing base release gate with production signature requirements enabled.
# Deliberately do NOT pass -AllowDevelopmentSignature.
$baseArgs = @(
    '-NoProfile','-File',$readinessScript,
    '-OfficePersistenceReport',$OfficePersistenceReport,
    '-OfficeUiReport',$OfficeUiReport,
    '-OfficeRestartReport',$OfficeRestartReport,
    '-LocalOfflineReport',$LocalOfflineReport,
    '-ProviderReport',$ProviderReport,
    '-PrivacyReport',$PrivacyReport,
    '-InstallerPath',$installer.FullName,
    '-OutputPath',$BaseReadinessOutput
)
$baseProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $baseArgs -Wait -PassThru -WindowStyle Hidden
if (-not (Test-Path -LiteralPath $BaseReadinessOutput -PathType Leaf)) {
    throw "Base release-readiness did not generate evidence (exit=$($baseProcess.ExitCode)): $BaseReadinessOutput"
}

$base = Read-Json $BaseReadinessOutput 'Base release-readiness evidence'
$officeE2E = Read-Json $OfficeE2EReport 'Full Office E2E evidence'
$lifecycle = Read-Json $LifecycleReport 'Lifecycle evidence'

$failures = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Base gate: persistence/UI/restart/offline/providers/privacy/signing.
# ---------------------------------------------------------------------------
if ($baseProcess.ExitCode -ne 0) { Add-Failure $failures "Base release-readiness exited $($baseProcess.ExitCode)." }
if ($base.TestId -ne 'OMNIX-RELEASE-READINESS-001') { Add-Failure $failures 'Unexpected base release-readiness TestId.' }
if (-not [bool]$base.OverallPass) { Add-Failure $failures 'Base release-readiness OverallPass is false.' }
if ([string]$base.Installer.Sha256 -ne $installerHash) { Add-Failure $failures 'Base readiness installer SHA256 does not match the final installer.' }
if ([string]$base.Installer.SignatureStatus -ne 'Valid') { Add-Failure $failures 'Final installer Authenticode status is not Valid.' }
if ([bool]$base.Installer.SelfSigned) { Add-Failure $failures 'Final installer is self-signed; production requires a trusted publisher certificate.' }

# ---------------------------------------------------------------------------
# Full Office E2E must prove the exact installer and the real AI route in all 3 hosts.
# ---------------------------------------------------------------------------
if ($officeE2E.TestId -ne 'OFFICE-E2E-REAL-001') { Add-Failure $failures 'Unexpected full Office E2E TestId.' }
if ([int]$officeE2E.EvidenceSchema -lt 2) { Add-Failure $failures 'Office E2E evidence schema is too old; AI round-trip evidence is mandatory.' }
if (-not [bool]$officeE2E.OverallPass) { Add-Failure $failures 'Full Office E2E OverallPass is false.' }
if ([string]$officeE2E.Installer.Sha256 -ne $installerHash) { Add-Failure $failures 'Office E2E was not run against the final installer SHA256.' }
if ($null -ne $officeE2E.Installer.HashMatchedExpected -and -not [bool]$officeE2E.Installer.HashMatchedExpected) {
    Add-Failure $failures 'Office E2E expected-installer hash binding failed.'
}
if ($null -eq $officeE2E.Installer.HashMatchedExpected) {
    Add-Failure $failures 'Office E2E did not use -ExpectedInstallerSha256; final evidence must be explicitly bound to the intended installer.'
}

if ($null -eq $officeE2E.AiRoundTrip) {
    Add-Failure $failures 'Office E2E AI round-trip evidence is missing.'
} else {
    if (-not [bool]$officeE2E.AiRoundTrip.Required) { Add-Failure $failures 'Office E2E AI round-trip was skipped.' }
    if ([string]$officeE2E.AiRoundTrip.TestId -ne 'OFFICE-AI-E2E-REAL-001') { Add-Failure $failures 'Unexpected Office AI E2E TestId.' }
    if (-not [bool]$officeE2E.AiRoundTrip.OverallPass) { Add-Failure $failures 'Office -> AI -> rendered UI round-trip failed.' }
    if (-not [bool]$officeE2E.AiRoundTrip.RequiredHostCountPass) { Add-Failure $failures 'Office AI E2E did not prove Excel + Word + PowerPoint.' }
    if (-not [bool]$officeE2E.AiRoundTrip.AllMarkerRoundTripsPass) { Add-Failure $failures 'At least one Office host failed the random-marker AI round-trip.' }
    if (-not [bool]$officeE2E.AiRoundTrip.AllProcessesExitedPass) { Add-Failure $failures 'At least one Office host left an orphan process after AI E2E.' }
}

# ---------------------------------------------------------------------------
# Lifecycle must finish with a real uninstall while preserving user settings and Office state.
# ---------------------------------------------------------------------------
if ($lifecycle.TestId -ne 'LIFECYCLE-REAL-001') { Add-Failure $failures 'Unexpected lifecycle TestId.' }
if ([int]$lifecycle.EvidenceSchema -lt 1) { Add-Failure $failures 'Lifecycle evidence schema is missing/invalid.' }
if ([string]$lifecycle.Phase -ne 'AfterUninstall') { Add-Failure $failures 'Lifecycle evidence must be the final AfterUninstall phase.' }
if (-not [bool]$lifecycle.OverallPass) { Add-Failure $failures 'Lifecycle OverallPass is false.' }
if (-not [bool]$lifecycle.BaselinePass) { Add-Failure $failures 'Lifecycle baseline did not pass.' }
if (-not [bool]$lifecycle.RepairPass) { Add-Failure $failures 'Repair/reinstall lifecycle did not pass.' }
if (-not [bool]$lifecycle.SettingsPreservedAcrossRepair) { Add-Failure $failures 'settings.dat was not preserved across repair/reinstall.' }
if (-not [bool]$lifecycle.ResiliencyPreservedAcrossRepair) { Add-Failure $failures 'Office Resiliency changed during repair/reinstall.' }
if (-not [bool]$lifecycle.RegistrationHealthyAfterRepair) { Add-Failure $failures 'Office registration was not healthy after repair/reinstall.' }
if (-not [bool]$lifecycle.UninstallPass) { Add-Failure $failures 'Uninstall lifecycle did not pass.' }
if (-not [bool]$lifecycle.SettingsPreservedAcrossUninstall) { Add-Failure $failures 'User settings were not preserved when uninstall was asked to keep user data.' }
if (-not [bool]$lifecycle.OmnixRegistrationRemoved) { Add-Failure $failures 'OMNIX Office registration remains after uninstall.' }
if (-not [bool]$lifecycle.AppPayloadRemoved) { Add-Failure $failures 'OMNIX application payload remains after uninstall.' }
if (-not [bool]$lifecycle.ResiliencyPreservedAcrossUninstall) { Add-Failure $failures 'Shared Office Resiliency changed during uninstall.' }
if (-not [bool]$lifecycle.DevelopmentCertificateRemoved) { Add-Failure $failures 'OMNIX development trust material remains after uninstall.' }

$sourceCommit = Get-GitHead
if ([string]::IsNullOrWhiteSpace($sourceCommit)) { Add-Failure $failures 'Could not resolve exact source Git commit.' }
if (-not [string]::IsNullOrWhiteSpace([string]$base.SourceCommit) -and
    -not [string]::IsNullOrWhiteSpace($sourceCommit) -and
    [string]$base.SourceCommit -ne $sourceCommit) {
    Add-Failure $failures 'Base release evidence source commit does not match the current checkout.'
}

$evidence = [ordered]@{
    TestId = 'OMNIX-FINAL-PRODUCTION-GATE-001'
    EvidenceSchema = 1
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = $sourceCommit
    Installer = [ordered]@{
        FileName = $installer.Name
        SizeBytes = [int64]$installer.Length
        Sha256 = $installerHash
        SignatureStatus = [string]$base.Installer.SignatureStatus
        SignerSubject = [string]$base.Installer.SignerSubject
        SignerThumbprint = [string]$base.Installer.SignerThumbprint
        Timestamped = [bool]$base.Installer.Timestamped
    }
    BaseReleaseReadinessPass = [bool]$base.OverallPass
    OfficeE2E = [ordered]@{
        Pass = [bool]$officeE2E.OverallPass
        InstallerHashMatchedExpected = [bool]$officeE2E.Installer.HashMatchedExpected
        AiRoundTripRequired = [bool]$officeE2E.AiRoundTrip.Required
        AiRoundTripPass = [bool]$officeE2E.AiRoundTrip.OverallPass
        AllThreeOfficeMarkerRoundTrips = [bool]$officeE2E.AiRoundTrip.AllMarkerRoundTripsPass
    }
    Lifecycle = [ordered]@{
        Pass = [bool]$lifecycle.OverallPass
        RepairPass = [bool]$lifecycle.RepairPass
        SettingsPreserved = [bool]($lifecycle.SettingsPreservedAcrossRepair -and $lifecycle.SettingsPreservedAcrossUninstall)
        ResiliencyPreserved = [bool]($lifecycle.ResiliencyPreservedAcrossRepair -and $lifecycle.ResiliencyPreservedAcrossUninstall)
        RegistrationRemoved = [bool]$lifecycle.OmnixRegistrationRemoved
        PayloadRemoved = [bool]$lifecycle.AppPayloadRemoved
        DevelopmentCertificateRemoved = [bool]$lifecycle.DevelopmentCertificateRemoved
    }
    Requirements = [ordered]@{
        ExactInstallerHashBinding = $true
        ExcelWordPowerPoint = $true
        RealOfficeAutomaticLoadAndUi = $true
        RealOfficeContextToAiToRenderedUi = $true
        RealWindowsRestartPersistence = $true
        OfflineLocalAi = $true
        LiveProviderMatrixAndStreaming = $true
        GatewayPrivacyBeforeSend = $true
        RepairAndUninstallLifecycle = $true
        TrustedProductionAuthenticode = $true
    }
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    Privacy = 'Sanitized aggregate only; no API keys, prompts, provider response bodies, machine names or Office document contents are copied.'
}

$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$evidence | ConvertTo-Json -Depth 10

if (-not $evidence.OverallPass) { exit 1 }
exit 0
