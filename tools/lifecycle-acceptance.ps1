# OMNIX canonical lifecycle acceptance entrypoint.
# Implementation lives in lifecycle-core-acceptance.ps1 so the public command remains stable while
# the evidence engine can precisely fingerprint only shared Office recovery subtrees OMNIX promises
# never to modify (DisabledItems, CrashingAddinList, DoNotDisableAddinList).

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Baseline','AfterRepair','AfterUninstall')]
    [string]$Phase,
    [string]$InstallerPath,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$SettingsPath = "$env:LOCALAPPDATA\OMNIX\settings.dat",
    [string]$StatePath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-state.json",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$impl = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'lifecycle-core-acceptance.ps1'
if (-not (Test-Path -LiteralPath $impl -PathType Leaf)) { throw "Lifecycle implementation missing: $impl" }

& $impl @PSBoundParameters
exit $LASTEXITCODE
