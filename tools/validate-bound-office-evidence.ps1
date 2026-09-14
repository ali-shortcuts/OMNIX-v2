# OMNIX coherent bound Office evidence-set validator.
#
# This script is read-only with respect to Office and the installed OMNIX payload. It validates
# that the four canonical real Office reports are individually passing, fresh, installer-bound,
# and cryptographically cross-bound to one source/Core/payload identity before they are accepted
# as one evidence set.

[CmdletBinding()]
param(
    [string]$LogRoot = "$env:LOCALAPPDATA\OMNIX\logs",
    [Parameter(Mandatory=$true)]
    [string]$SourceCommit,
    [Parameter(Mandatory=$true)]
    [string]$ExpectedInstallerSha256,
    [ValidateRange(1,168)]
    [int]$MaxAgeHours = 168,
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\bound-office-evidence-validation.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bindingScript = Join-Path $scriptDir 'real-evidence-binding.ps1'
$failures = New-Object System.Collections.Generic.List[string]
$reportRows = New-Object System.Collections.Generic.List[object]
$reports = @{}
$baselineCore = $null
$baselinePayloadIdentity = $null
$expectedSource = $SourceCommit.Trim().ToLowerInvariant()
$expectedInstaller = $ExpectedInstallerSha256.Trim().ToLowerInvariant()

function Add-Failure([string]$Message) {
    $script:failures.Add($Message)
}

function Read-Report([string]$Path,[string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Failure "$Label is missing: $Path"
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-Failure "$Label is not valid JSON: $($_.Exception.Message)"
        return $null
    }
}

try {
    if ($expectedSource -notmatch '^[0-9a-f]{40}$') {
        Add-Failure 'SourceCommit must be exactly 40 hexadecimal characters.'
    }
    if ($expectedInstaller -notmatch '^[0-9a-f]{64}$') {
        Add-Failure 'ExpectedInstallerSha256 must be exactly 64 hexadecimal characters.'
    }
    if (-not (Test-Path -LiteralPath $bindingScript -PathType Leaf)) {
        Add-Failure "Evidence binding helper is missing: $bindingScript"
    }
    else {
        . $bindingScript
    }

    $required = @(
        [pscustomobject]@{ File='full-office-e2e.json'; Label='Full Office E2E'; Baseline=$true },
        [pscustomobject]@{ File='real-office-acceptance.json'; Label='Office persistence'; Baseline=$false },
        [pscustomobject]@{ File='real-office-ui-acceptance.json'; Label='Office UI'; Baseline=$false },
        [pscustomobject]@{ File='taskpane-lifecycle-real-acceptance.json'; Label='Task-pane lifecycle'; Baseline=$false }
    )

    foreach ($item in $required) {
        $path = Join-Path $LogRoot $item.File
        $report = Read-Report -Path $path -Label $item.Label
        if ($null -ne $report) {
            $reports[$item.File] = $report
        }
    }

    $baseline = $reports['full-office-e2e.json']
    if ($null -ne $baseline) {
        if ($null -eq $baseline.EvidenceBinding) {
            Add-Failure 'Full Office E2E EvidenceBinding is missing.'
        }
        else {
            if ([int]$baseline.EvidenceBinding.BindingSchema -lt 2) {
                Add-Failure 'Full Office E2E EvidenceBinding schema is too old.'
            }
            if ([string]$baseline.EvidenceBinding.BuildIdentityTestId -ne 'OMNIX-BUILD-IDENTITY-001') {
                Add-Failure 'Full Office E2E BuildIdentityTestId is missing or invalid.'
            }
            if (-not [bool]$baseline.EvidenceBinding.PrimaryAssembliesValidated) {
                Add-Failure 'Full Office E2E did not prove primary assembly validation.'
            }

            $baselineSource = ([string]$baseline.EvidenceBinding.SourceCommit).Trim().ToLowerInvariant()
            $baselineCore = ([string]$baseline.EvidenceBinding.CoreSha256).Trim().ToLowerInvariant()
            $baselinePayloadIdentity = ([string]$baseline.EvidenceBinding.PayloadIdentitySha256).Trim().ToLowerInvariant()
            if ($baselineSource -ne $expectedSource) {
                Add-Failure 'Full Office E2E source commit does not match the requested source.'
            }
            if ($baselineCore -notmatch '^[0-9a-f]{64}$') {
                Add-Failure 'Full Office E2E CoreSha256 is invalid.'
            }
            if ($baselinePayloadIdentity -notmatch '^[0-9a-f]{64}$') {
                Add-Failure 'Full Office E2E PayloadIdentitySha256 is invalid.'
            }
        }

        if (-not [bool]$baseline.OverallPass) {
            Add-Failure 'Full Office E2E report is not passing.'
        }

        if ($null -eq $baseline.Installer) {
            Add-Failure 'Full Office E2E installer evidence is missing.'
        }
        else {
            $reportedInstaller = ([string]$baseline.Installer.Sha256).Trim().ToLowerInvariant()
            if ($reportedInstaller -ne $expectedInstaller) {
                Add-Failure 'Full Office E2E installer SHA256 does not match the requested installer.'
            }
            if (-not [bool]$baseline.Installer.HashMatchedExpected) {
                Add-Failure 'Full Office E2E did not prove the installer hash matched the expected value.'
            }
        }
    }

    foreach ($item in $required) {
        $report = $reports[$item.File]
        if ($null -eq $report) { continue }

        if (-not [bool]$report.OverallPass) {
            Add-Failure "$($item.Label) report OverallPass is not true."
        }

        $binding = $report.EvidenceBinding
        $row = [ordered]@{
            File = $item.File
            TestId = [string]$report.TestId
            OverallPass = [bool]$report.OverallPass
            SourceCommit = if ($null -ne $binding) { [string]$binding.SourceCommit } else { $null }
            CoreSha256 = if ($null -ne $binding) { [string]$binding.CoreSha256 } else { $null }
            PayloadIdentitySha256 = if ($null -ne $binding) { [string]$binding.PayloadIdentitySha256 } else { $null }
            BuildIdentityTestId = if ($null -ne $binding) { [string]$binding.BuildIdentityTestId } else { $null }
            PrimaryAssembliesValidated = if ($null -ne $binding) { [bool]$binding.PrimaryAssembliesValidated } else { $false }
        }
        $reportRows.Add([pscustomobject]$row)

        if ($null -ne $baselineCore -and $baselineCore -match '^[0-9a-f]{64}$' -and
            $null -ne $baselinePayloadIdentity -and $baselinePayloadIdentity -match '^[0-9a-f]{64}$' -and
            $expectedSource -match '^[0-9a-f]{40}$' -and
            (Get-Command Test-OmnixEvidenceBinding -ErrorAction SilentlyContinue)) {
            foreach ($bindingError in @(Test-OmnixEvidenceBinding `
                -Report $report `
                -ExpectedSourceCommit $expectedSource `
                -ExpectedCoreSha256 $baselineCore `
                -ExpectedPayloadIdentitySha256 $baselinePayloadIdentity `
                -MaxAgeHours $MaxAgeHours `
                -Label $item.Label)) {
                Add-Failure ([string]$bindingError)
            }
        }
    }
}
catch {
    Add-Failure ('Unexpected coherent evidence validation exception: ' + $_.Exception.Message)
}

$validation = [ordered]@{
    TestId = 'BOUND-OFFICE-EVIDENCE-SET-001'
    EvidenceSchema = 1
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    SourceCommit = $expectedSource
    InstallerSha256 = $expectedInstaller
    CoreSha256 = $baselineCore
    PayloadIdentitySha256 = $baselinePayloadIdentity
    RequiredReportCount = 4
    ValidatedReportCount = $reportRows.Count
    MaxAgeHours = $MaxAgeHours
    Reports = $reportRows
    FailureCount = $failures.Count
    Failures = $failures
    OverallPass = ($failures.Count -eq 0 -and $reportRows.Count -eq 4)
    Safety = 'Validation only: no Office launch, install, registry, network, security, restart, or document mutation.'
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$validation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$validation | ConvertTo-Json -Depth 12

if (-not $validation.OverallPass) { exit 1 }
exit 0
