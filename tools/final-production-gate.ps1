# OMNIX canonical FINAL production gate entrypoint.
# The implementation is isolated in final-production-core.ps1. This wrapper intentionally exposes
# no development-signature override and performs no install/restart/network/security actions.

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
$impl=Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'final-production-core.ps1'
if(-not(Test-Path -LiteralPath $impl -PathType Leaf)){throw "Final production implementation missing: $impl"}
& $impl @PSBoundParameters
exit $LASTEXITCODE
