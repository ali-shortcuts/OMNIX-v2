# Deterministic behavior acceptance for final-production-taskpane-guard.ps1.
# No Office installation, network, registry or machine-security changes are required.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$guard = Join-Path $scriptDir 'final-production-taskpane-guard.ps1'
if (-not (Test-Path -LiteralPath $guard -PathType Leaf)) { throw "Guard missing: $guard" }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('omnix-final-taskpane-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Write-Report([string]$name, [int]$schema, [bool]$includeTaskPane, [bool]$taskPanePass, [int]$hostCount, [bool]$twoRounds) {
    $report = [ordered]@{
        TestId = 'OFFICE-E2E-REAL-001'
        EvidenceSchema = $schema
        OverallPass = $true
    }
    if ($includeTaskPane) {
        $report.TaskPaneLifecycle = [ordered]@{
            TestId = 'TASKPANE-LIFECYCLE-REAL-001'
            ExitCode = if ($taskPanePass) { 0 } else { 1 }
            OverallPass = $taskPanePass
            InstalledHostCount = $hostCount
            TwoRoundsPerHostRequired = $twoRounds
        }
    }
    $path = Join-Path $tempRoot ($name + '.json')
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Quote-ProcessArg([string]$value) {
    return '"' + $value + '"'
}

function Invoke-Guard([string]$reportPath) {
    $argsLine = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArg $guard),
        '-OfficeE2EReport', (Quote-ProcessArg $reportPath)
    ) -join ' '
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsLine -Wait -PassThru -WindowStyle Hidden
    return [int]$p.ExitCode
}

function Test-CompositionContinues([string]$validReportPath) {
    $probe = Join-Path $tempRoot 'composition-probe.ps1'
    $sentinel = Join-Path $tempRoot 'composition-continued.txt'
    @'
param(
    [Parameter(Mandatory=$true)][string]$Guard,
    [Parameter(Mandatory=$true)][string]$Report,
    [Parameter(Mandatory=$true)][string]$Sentinel
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& $Guard -OfficeE2EReport $Report
Set-Content -LiteralPath $Sentinel -Value 'continued-after-guard' -Encoding ASCII
'@ | Set-Content -LiteralPath $probe -Encoding UTF8

    $argsLine = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArg $probe),
        '-Guard', (Quote-ProcessArg $guard),
        '-Report', (Quote-ProcessArg $validReportPath),
        '-Sentinel', (Quote-ProcessArg $sentinel)
    ) -join ' '
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsLine -Wait -PassThru -WindowStyle Hidden
    $sentinelPresent = Test-Path -LiteralPath $sentinel -PathType Leaf
    $sentinelText = if ($sentinelPresent) { (Get-Content -LiteralPath $sentinel -Raw).Trim() } else { $null }
    return [pscustomobject]@{
        ExitCode = [int]$p.ExitCode
        SentinelPresent = [bool]$sentinelPresent
        SentinelText = $sentinelText
        Pass = [bool]($p.ExitCode -eq 0 -and $sentinelPresent -and $sentinelText -eq 'continued-after-guard')
    }
}

$results = New-Object System.Collections.Generic.List[object]
try {
    $validPath = Write-Report 'valid' 5 $true $true 3 $true
    $cases = @(
        [pscustomobject]@{ Name='ValidSchema5ThreeHosts'; Path=$validPath; Expected=0 },
        [pscustomobject]@{ Name='LegacySchema4'; Path=(Write-Report 'legacy' 4 $true $true 3 $true); Expected=1 },
        [pscustomobject]@{ Name='MissingTaskPaneLifecycle'; Path=(Write-Report 'missing' 5 $false $false 0 $false); Expected=1 },
        [pscustomobject]@{ Name='FailedTaskPaneLifecycle'; Path=(Write-Report 'failed' 5 $true $false 3 $true); Expected=1 },
        [pscustomobject]@{ Name='OnlyTwoHosts'; Path=(Write-Report 'two-hosts' 5 $true $true 2 $true); Expected=1 },
        [pscustomobject]@{ Name='SingleRoundAllowed'; Path=(Write-Report 'single-round' 5 $true $true 3 $false); Expected=1 }
    )

    foreach ($case in $cases) {
        $actual = Invoke-Guard $case.Path
        $results.Add([ordered]@{
            Name = $case.Name
            ExpectedExitCode = [int]$case.Expected
            ActualExitCode = $actual
            Pass = [bool]($actual -eq [int]$case.Expected)
        })
    }

    $composition = Test-CompositionContinues $validPath
    $results.Add([ordered]@{
        Name = 'CallerContinuesAfterValidGuard'
        ExpectedExitCode = 0
        ActualExitCode = [int]$composition.ExitCode
        SentinelPresent = [bool]$composition.SentinelPresent
        SentinelText = $composition.SentinelText
        Pass = [bool]$composition.Pass
    })
}
finally {
    try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

$failed = @($results | Where-Object { -not $_.Pass })
$report = [ordered]@{
    TestId = 'FINAL-TASKPANE-GUARD-RUNTIME-001'
    CaseCount = $results.Count
    CallerContinuationProven = [bool](@($results | Where-Object { $_.Name -eq 'CallerContinuesAfterValidGuard' -and $_.Pass }).Count -eq 1)
    FailureCount = $failed.Count
    Results = $results
    OverallPass = ($failed.Count -eq 0)
}
$report | ConvertTo-Json -Depth 8

if (-not $report.OverallPass) { exit 1 }
exit 0
