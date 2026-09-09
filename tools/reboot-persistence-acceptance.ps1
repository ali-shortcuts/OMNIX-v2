# OMNIX real Windows restart persistence gate
#
# This is a TWO-PHASE real-machine test. It never restarts Windows by itself.
#
# Phase 1 (before restart):
#   .\tools\reboot-persistence-acceptance.ps1 -Phase BeforeRestart
# Then restart Windows normally.
# Phase 2 (after restart):
#   .\tools\reboot-persistence-acceptance.ps1 -Phase AfterRestart
#
# Each phase runs the strict real-office-acceptance.ps1 gate. The final PASS requires:
# - Excel, Word and PowerPoint all pass strict automatic-load/persistence checks before restart;
# - the Windows boot session actually changed;
# - all three hosts pass the same strict automatic-load/persistence checks after restart.
#
# This script does not change Office Trust Center, Resiliency, registry policy, startup policy,
# security settings, documents, or Windows restart configuration.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('BeforeRestart','AfterRestart')]
    [string]$Phase,
    [string]$StatePath = "$env:LOCALAPPDATA\OMNIX\logs\restart-persistence-state.json",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\real-office-restart-acceptance.json",
    [string]$OfficeAcceptanceScript = (Join-Path $PSScriptRoot 'real-office-acceptance.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BootSessionUtc {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $boot = [DateTime]$os.LastBootUpTime
        return $boot.ToUniversalTime().ToString('o')
    }
    catch {
        throw "Could not resolve Windows boot session time: $($_.Exception.Message)"
    }
}

function Read-Json([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "$label not found: $path"
    }
    try {
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }
    catch {
        throw "$label is not valid JSON: $path — $($_.Exception.Message)"
    }
}

function Test-StrictOfficeReport($report, [string]$label) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'OFFICE-PERSISTENCE-REAL-001') {
        $errors.Add("$label has an unexpected/missing TestId.")
        return $errors
    }
    if (-not [bool]$report.OverallPass) { $errors.Add("$label OverallPass is false.") }
    if (-not [bool]$report.RequiredHostCountPass) { $errors.Add("$label did not prove all three required Office hosts.") }
    if (-not [bool]$report.TwoRoundsPerHostPass) { $errors.Add("$label did not prove two independent launches per host.") }
    if (-not [bool]$report.AutomaticLoadEveryRoundPass) { $errors.Add("$label did not prove automatic OMNIX load on every launch.") }

    foreach ($name in @('Excel','Word','PowerPoint')) {
        $rows = @($report.Results | Where-Object { $_.Host -eq $name -and $_.Installed })
        if ($rows.Count -ne 2) {
            $errors.Add("$label $name must contain exactly two installed launch rounds.")
            continue
        }
        foreach ($r in $rows) {
            if (-not [bool]$r.Pass) { $errors.Add("$label $name round $($r.Round) failed.") }
            if (-not [bool]$r.InitialConnect) { $errors.Add("$label $name round $($r.Round) did not auto-connect.") }
            if (-not [bool]$r.AutomaticLoadPass) { $errors.Add("$label $name round $($r.Round) automatic-load proof failed.") }
            if ([bool]$r.ForceConnectAttempted) { $errors.Add("$label $name round $($r.Round) required a force-connect diagnostic.") }
            if ($null -eq $r.Registry -or -not [bool]$r.Registry.Found) { $errors.Add("$label $name round $($r.Round) registration was not found.") }
            elseif ([int]$r.Registry.LoadBehavior -ne 3) { $errors.Add("$label $name round $($r.Round) LoadBehavior is not 3.") }
            elseif ($null -eq $r.Registry.Manifest -or -not [bool]$r.Registry.Manifest.Exists) { $errors.Add("$label $name round $($r.Round) registered manifest target is missing.") }
        }
    }
    return $errors
}

function Invoke-OfficeAcceptance([string]$reportPath) {
    if (-not (Test-Path -LiteralPath $OfficeAcceptanceScript -PathType Leaf)) {
        throw "Office acceptance script not found: $OfficeAcceptanceScript"
    }

    $dir = Split-Path -Parent $reportPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    & $OfficeAcceptanceScript -OutputPath $reportPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Strict Office acceptance failed with exit code $exitCode. Evidence: $reportPath"
    }

    return Read-Json $reportPath 'Office acceptance report'
}

$stateDir = Split-Path -Parent $StatePath
if ($stateDir) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

if ($Phase -eq 'BeforeRestart') {
    $preReportPath = Join-Path $stateDir 'real-office-before-restart.json'
    $pre = Invoke-OfficeAcceptance $preReportPath
    $preErrors = @(Test-StrictOfficeReport $pre 'BeforeRestart')
    if ($preErrors.Count -gt 0) {
        throw "Pre-restart Office acceptance was not strict PASS: $($preErrors -join ' | ')"
    }

    $state = [ordered]@{
        StateSchema = 1
        TestId = 'OFFICE-RESTART-PERSISTENCE-STATE-001'
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        BeforeBootSessionUtc = Get-BootSessionUtc
        BeforeOfficeReport = $preReportPath
        BeforeOfficeOverallPass = [bool]$pre.OverallPass
        BeforeAutomaticLoadEveryRoundPass = [bool]$pre.AutomaticLoadEveryRoundPass
    }
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    $state | ConvertTo-Json -Depth 8
    Write-Host 'BEFORE-RESTART PASS. Restart Windows normally, then run this script with -Phase AfterRestart.'
    exit 0
}

$state = Read-Json $StatePath 'Restart persistence state'
if ($state.TestId -ne 'OFFICE-RESTART-PERSISTENCE-STATE-001') {
    throw 'Unexpected restart persistence state TestId.'
}

$beforeBoot = [DateTime]::Parse([string]$state.BeforeBootSessionUtc).ToUniversalTime()
$currentBootText = Get-BootSessionUtc
$currentBoot = [DateTime]::Parse($currentBootText).ToUniversalTime()
$bootChanged = [bool]($currentBoot -gt $beforeBoot.AddSeconds(5))
if (-not $bootChanged) {
    throw 'Windows boot session did not change. A real restart is required between BeforeRestart and AfterRestart.'
}

$pre = Read-Json ([string]$state.BeforeOfficeReport) 'Pre-restart Office report'
$preErrors = @(Test-StrictOfficeReport $pre 'BeforeRestart')

$postReportPath = Join-Path $stateDir 'real-office-after-restart.json'
$post = Invoke-OfficeAcceptance $postReportPath
$postErrors = @(Test-StrictOfficeReport $post 'AfterRestart')

$failures = New-Object System.Collections.Generic.List[string]
foreach ($e in $preErrors) { $failures.Add([string]$e) }
foreach ($e in $postErrors) { $failures.Add([string]$e) }

$report = [ordered]@{
    EvidenceSchema = 1
    TestId = 'OFFICE-RESTART-PERSISTENCE-REAL-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    BeforeBootSessionUtc = $beforeBoot.ToString('o')
    AfterBootSessionUtc = $currentBoot.ToString('o')
    BootSessionChanged = $bootChanged
    PreRestartPersistencePass = ($preErrors.Count -eq 0)
    PostRestartPersistencePass = ($postErrors.Count -eq 0)
    RequiredHosts = @('Excel','Word','PowerPoint')
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = [bool]($bootChanged -and $failures.Count -eq 0)
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if (-not $report.OverallPass) { exit 1 }
exit 0
