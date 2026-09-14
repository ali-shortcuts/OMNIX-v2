# OMNIX canonical FINAL production gate entrypoint.
# The implementation is isolated in final-production-core.ps1. This wrapper intentionally exposes
# no development-signature override and performs no install/restart/network/security actions.
# Before delegating to the broader production core it fail-closes on:
#   1) stale or cross-build real-machine/Core evidence, and
#   2) Office E2E evidence missing the real per-window TASKPANE-LIFECYCLE-REAL-001 result.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [string]$OfficeE2EReport = "$env:LOCALAPPDATA\OMNIX\logs\full-office-e2e.json",
    [string]$LifecycleReport = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json",
    [string]$ConsumerSecurityReport = "$env:LOCALAPPDATA\OMNIX\logs\consumer-security-acceptance.json",
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
$ErrorActionPreference='Stop'

$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$bindingGuard=Join-Path $scriptDir 'final-production-evidence-binding-guard.ps1'
$taskPaneGuard=Join-Path $scriptDir 'final-production-taskpane-guard.ps1'
$impl=Join-Path $scriptDir 'final-production-core.ps1'

if(-not(Test-Path -LiteralPath $bindingGuard -PathType Leaf)){throw "Final evidence-binding guard missing: $bindingGuard"}
if(-not(Test-Path -LiteralPath $taskPaneGuard -PathType Leaf)){throw "Final task-pane evidence guard missing: $taskPaneGuard"}
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "Final production implementation missing: $impl"}

# Guards are composable: rejection throws and stops here. Valid guards return normally. The broader
# production core MUST still execute after both guards pass.
& $bindingGuard `
    -InstallerPath $InstallerPath `
    -OfficeE2EReport $OfficeE2EReport `
    -LifecycleReport $LifecycleReport `
    -ConsumerSecurityReport $ConsumerSecurityReport `
    -OfficePersistenceReport $OfficePersistenceReport `
    -OfficeUiReport $OfficeUiReport `
    -OfficeRestartReport $OfficeRestartReport `
    -LocalOfflineReport $LocalOfflineReport `
    -ProviderReport $ProviderReport `
    -PrivacyReport $PrivacyReport

& $taskPaneGuard -OfficeE2EReport $OfficeE2EReport
& $impl @PSBoundParameters
exit $LASTEXITCODE
