# OMNIX full real Office end-to-end acceptance orchestrator
#
# Intended for an interactive Windows desktop that has Excel + Word + PowerPoint installed.
# It optionally installs a supplied OMNIX installer, then runs:
#   1) strict two-launch COM automatic-load/persistence acceptance,
#   2) real Ribbon + Open Workspace + visible task-pane UI Automation acceptance,
#   3) real compiled OMNIX.Core Office-context/read/write/PowerPoint-Vision functional acceptance.
#
# This script does NOT restart Windows, alter networking, clear Office Resiliency, change Trust Center,
# or touch user Office documents. Reboot persistence remains a separate explicit before/after gate.

[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\full-office-e2e.json",
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Assert-OfficeClosed {
    $running = @()
    foreach ($name in @('EXCEL','WINWORD','POWERPNT')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
    if ($running.Count -gt 0) {
        throw "Close Excel, Word and PowerPoint before running the full OMNIX E2E test. Running: $($running -join ', ')"
    }
}

function Invoke-AcceptanceScript([string]$scriptName, [string]$reportPath, [string[]]$extraArgs = @()) {
    $scriptPath = Join-Path $scriptDir $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Acceptance script missing: $scriptPath" }

    $args = @('-NoProfile','-File',$scriptPath,'-OutputPath',$reportPath) + $extraArgs
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "$scriptName did not produce its report: $reportPath (exit=$($p.ExitCode))"
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ ExitCode=$p.ExitCode; Report=$report }
}

Assert-OfficeClosed

$installerEvidence = [ordered]@{
    Requested = (-not $SkipInstall)
    Path = $null
    FileName = $null
    SizeBytes = $null
    Sha256 = $null
    ExitCode = $null
    Pass = $false
    LogPath = $null
}

if ($SkipInstall) {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)) {
        throw "SkipInstall was requested but OMNIX is not installed at $InstallDir"
    }
    $installerEvidence.Pass = $true
}
else {
    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        throw 'InstallerPath is required unless -SkipInstall is supplied.'
    }
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }

    $installer = Get-Item -LiteralPath $InstallerPath
    if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small: $($installer.Length) bytes" }
    $installLog = Join-Path $logDir 'full-office-e2e-installer.log'
    if (Test-Path $installLog) { Remove-Item -LiteralPath $installLog -Force }

    $installerEvidence.Path = $installer.FullName
    $installerEvidence.FileName = $installer.Name
    $installerEvidence.SizeBytes = [int64]$installer.Length
    $installerEvidence.Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()
    $installerEvidence.LogPath = $installLog

    $installArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/LOG=' + $installLog))
    $p = Start-Process -FilePath $installer.FullName -ArgumentList $installArgs -Wait -PassThru
    $installerEvidence.ExitCode = $p.ExitCode
    $installerEvidence.Pass = [bool]($p.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf))

    if (-not $installerEvidence.Pass) {
        $tail = ''
        if (Test-Path $installLog) {
            try { $tail = ((Get-Content -LiteralPath $installLog -Tail 40) -join [Environment]::NewLine) } catch { }
        }
        throw "OMNIX installer E2E stage failed (exit=$($p.ExitCode)). Log: $installLog`n$tail"
    }
}

Assert-OfficeClosed

$persistencePath = Join-Path $logDir 'real-office-acceptance.json'
$uiPath = Join-Path $logDir 'real-office-ui-acceptance.json'
$functionalPath = Join-Path $logDir 'office-functional-acceptance.json'

$persistence = Invoke-AcceptanceScript 'real-office-acceptance.ps1' $persistencePath
Assert-OfficeClosed
$ui = Invoke-AcceptanceScript 'real-office-ui-acceptance.ps1' $uiPath
Assert-OfficeClosed
$functional = Invoke-AcceptanceScript 'office-functional-acceptance.ps1' $functionalPath @('-InstallDir',$InstallDir)
Assert-OfficeClosed

$officeVersions = @()
foreach ($name in @('Excel','Word','PowerPoint')) {
    $pRows = @($persistence.Report.Results | Where-Object { $_.Host -eq $name -and $_.Installed })
    $fRow = @($functional.Report.Results | Where-Object { $_.Host -eq $name -and $_.Installed }) | Select-Object -First 1
    $version = $null
    if ($pRows.Count -gt 0) { $version = [string]$pRows[0].Version }
    elseif ($null -ne $fRow) { $version = [string]$fRow.Version }
    $officeVersions += [ordered]@{ Host=$name; Version=$version }
}

$failures = New-Object System.Collections.Generic.List[string]
if (-not [bool]$installerEvidence.Pass) { $failures.Add('Installer stage failed.') }
if ($persistence.ExitCode -ne 0 -or -not [bool]$persistence.Report.OverallPass) { $failures.Add('Strict Office automatic-load/persistence acceptance failed.') }
if ($ui.ExitCode -ne 0 -or -not [bool]$ui.Report.OverallPass) { $failures.Add('Real Office Ribbon/workspace UI acceptance failed.') }
if ($functional.ExitCode -ne 0 -or -not [bool]$functional.Report.OverallPass) { $failures.Add('Real Office functional context/read/write/Vision acceptance failed.') }

$report = [ordered]@{
    TestId = 'OFFICE-E2E-REAL-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Windows = [Environment]::OSVersion.VersionString
    InteractiveSession = [Environment]::UserInteractive
    InstallDir = $InstallDir
    Installer = $installerEvidence
    OfficeVersions = $officeVersions
    Persistence = [ordered]@{
        TestId = [string]$persistence.Report.TestId
        ExitCode = [int]$persistence.ExitCode
        OverallPass = [bool]$persistence.Report.OverallPass
        RequiredHostCountPass = [bool]$persistence.Report.RequiredHostCountPass
        TwoRoundsPerHostPass = [bool]$persistence.Report.TwoRoundsPerHostPass
        AutomaticLoadEveryRoundPass = [bool]$persistence.Report.AutomaticLoadEveryRoundPass
    }
    Ui = [ordered]@{
        TestId = [string]$ui.Report.TestId
        ExitCode = [int]$ui.ExitCode
        OverallPass = [bool]$ui.Report.OverallPass
    }
    Functional = [ordered]@{
        TestId = [string]$functional.Report.TestId
        ExitCode = [int]$functional.ExitCode
        OverallPass = [bool]$functional.Report.OverallPass
        RequiredHostCountPass = [bool]$functional.Report.RequiredHostCountPass
        AllWritesGuarded = [bool]$functional.Report.AllWritesGuarded
        PowerPointVisionCapturePass = [bool]$functional.Report.PowerPointVisionCapturePass
    }
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    RemainingSeparateReleaseGates = @(
        'Windows restart persistence before/after an actual user-initiated restart',
        'offline local-model round-trip with public Internet disconnected',
        'live configured cloud-provider/model/streaming/vision tests',
        'consumer-machine Defender/SmartScreen with normal protections enabled',
        'trusted production Authenticode signature'
    )
    Safety = 'Temporary unsaved Office files only. No automatic restart/network/firewall/Trust Center/Office Resiliency manipulation.'
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10

if (-not $report.OverallPass) { exit 1 }
exit 0
