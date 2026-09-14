# Deterministic behavior acceptance for validate-bound-office-evidence.ps1.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$validator = Join-Path $scriptDir 'validate-bound-office-evidence.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    throw "Bound Office evidence validator is missing: $validator"
}

$sourceCommit = ('a' * 40)
$installerSha = ('d' * 64)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('omnix-bound-office-' + [Guid]::NewGuid().ToString('N'))
$logRoot = Join-Path $tempRoot 'logs'
$installDir = Join-Path $tempRoot 'installed'
$coreSha = $null
$payloadSha = $null
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

function Write-InstalledPayload {
    $files = [ordered]@{
        'OMNIX.Core.dll' = 'deterministic-core-payload-v1'
        'OMNIX.Excel.dll' = 'deterministic-excel-payload-v1'
        'OMNIX.Word.dll' = 'deterministic-word-payload-v1'
        'OMNIX.PowerPoint.dll' = 'deterministic-powerpoint-payload-v1'
    }
    foreach ($entry in $files.GetEnumerator()) {
        Set-Content -LiteralPath (Join-Path $script:installDir $entry.Key) -Value $entry.Value -Encoding ASCII
    }

    $script:coreSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:installDir 'OMNIX.Core.dll')).Hash.ToLowerInvariant()
    $excelSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:installDir 'OMNIX.Excel.dll')).Hash.ToLowerInvariant()
    $wordSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:installDir 'OMNIX.Word.dll')).Hash.ToLowerInvariant()
    $powerPointSha = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:installDir 'OMNIX.PowerPoint.dll')).Hash.ToLowerInvariant()

    $identityPath = Join-Path $script:installDir 'OMNIX-build-identity.json'
    [ordered]@{
        TestId = 'OMNIX-BUILD-IDENTITY-001'
        EvidenceSchema = 1
        SourceCommit = $script:sourceCommit
        CoreSha256 = $script:coreSha
        ExcelSha256 = $excelSha
        WordSha256 = $wordSha
        PowerPointSha256 = $powerPointSha
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $identityPath -Encoding UTF8
    $script:payloadSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $identityPath).Hash.ToLowerInvariant()
}

function New-Binding {
    param([string]$PayloadSha = $script:payloadSha,[string]$BuildIdentityTestId = 'OMNIX-BUILD-IDENTITY-001')
    return [ordered]@{
        BindingSchema = 2
        SourceCommit = $script:sourceCommit
        CoreSha256 = $script:coreSha
        PayloadIdentitySha256 = $PayloadSha
        BuildIdentityTestId = $BuildIdentityTestId
        PrimaryAssembliesValidated = $true
        CoreFileName = 'OMNIX.Core.dll'
    }
}

function Write-ValidEvidenceSet {
    $timestamp = [DateTime]::UtcNow.ToString('o')
    $binding = New-Binding

    [ordered]@{
        TestId = 'OFFICE-E2E-REAL-001'
        TimestampUtc = $timestamp
        OverallPass = $true
        Installer = [ordered]@{
            Sha256 = $script:installerSha
            HashMatchedExpected = $true
        }
        EvidenceBinding = $binding
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:logRoot 'full-office-e2e.json') -Encoding UTF8

    foreach ($row in @(
        @{ File='real-office-acceptance.json'; TestId='OFFICE-PERSISTENCE-REAL-001' },
        @{ File='real-office-ui-acceptance.json'; TestId='OFFICE-UI-REAL-001' },
        @{ File='taskpane-lifecycle-real-acceptance.json'; TestId='TASKPANE-LIFECYCLE-REAL-001' }
    )) {
        [ordered]@{
            TestId = $row.TestId
            TimestampUtc = $timestamp
            OverallPass = $true
            EvidenceBinding = (New-Binding)
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:logRoot $row.File) -Encoding UTF8
    }
}

function Reset-ValidState {
    Write-InstalledPayload
    Write-ValidEvidenceSet
}

function Invoke-Validator([string]$CaseName) {
    $outputPath = Join-Path $script:tempRoot ($CaseName + '.json')
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) { $powershell = 'powershell.exe' }
    $arguments = @(
        '-NoProfile','-File',$script:validator,
        '-LogRoot',$script:logRoot,
        '-InstallDir',$script:installDir,
        '-SourceCommit',$script:sourceCommit,
        '-ExpectedInstallerSha256',$script:installerSha,
        '-MaxAgeHours','168',
        '-OutputPath',$outputPath
    )
    & $powershell @arguments | Out-Null
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        OutputPath = $outputPath
    }
}

function Require-Pass([string]$CaseName) {
    $result = Invoke-Validator $CaseName
    if ($result.ExitCode -ne 0) {
        throw "$CaseName should have passed but exited $($result.ExitCode)."
    }
    $report = Get-Content -LiteralPath $result.OutputPath -Raw | ConvertFrom-Json
    if ($report.TestId -ne 'BOUND-OFFICE-EVIDENCE-SET-001' -or
        -not [bool]$report.InstalledPayloadValidated -or
        -not [bool]$report.OverallPass -or
        [int]$report.FailureCount -ne 0) {
        throw "$CaseName did not produce a valid passing coherent evidence report."
    }
}

function Require-Rejection([string]$CaseName) {
    $result = Invoke-Validator $CaseName
    if ($result.ExitCode -eq 0) {
        throw "$CaseName should have been rejected but exited 0."
    }
    $report = Get-Content -LiteralPath $result.OutputPath -Raw | ConvertFrom-Json
    if ([bool]$report.OverallPass -or [int]$report.FailureCount -lt 1) {
        throw "$CaseName rejection did not produce fail-closed evidence."
    }
}

try {
    Reset-ValidState
    Require-Pass 'valid-coherent-set'

    Reset-ValidState
    $tamperedPath = Join-Path $logRoot 'real-office-ui-acceptance.json'
    $tampered = Get-Content -LiteralPath $tamperedPath -Raw | ConvertFrom-Json
    $tampered.EvidenceBinding.PayloadIdentitySha256 = ('e' * 64)
    $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tamperedPath -Encoding UTF8
    Require-Rejection 'payload-identity-mismatch'

    Reset-ValidState
    $failedPath = Join-Path $logRoot 'taskpane-lifecycle-real-acceptance.json'
    $failed = Get-Content -LiteralPath $failedPath -Raw | ConvertFrom-Json
    $failed.OverallPass = $false
    $failed | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $failedPath -Encoding UTF8
    Require-Rejection 'subreport-overall-failure'

    Reset-ValidState
    $installerPath = Join-Path $logRoot 'full-office-e2e.json'
    $installerReport = Get-Content -LiteralPath $installerPath -Raw | ConvertFrom-Json
    $installerReport.Installer.Sha256 = ('f' * 64)
    $installerReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $installerPath -Encoding UTF8
    Require-Rejection 'installer-hash-mismatch'

    Reset-ValidState
    $identityPath = Join-Path $logRoot 'real-office-acceptance.json'
    $identityReport = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $identityReport.EvidenceBinding.BuildIdentityTestId = 'INVALID-BUILD-IDENTITY'
    $identityReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $identityPath -Encoding UTF8
    Require-Rejection 'build-identity-testid-mismatch'

    Reset-ValidState
    Set-Content -LiteralPath (Join-Path $installDir 'OMNIX.Excel.dll') -Value 'tampered-installed-excel-payload' -Encoding ASCII
    Require-Rejection 'installed-assembly-tamper'

    [ordered]@{
        TestId = 'BOUND-OFFICE-EVIDENCE-VALIDATOR-RUNTIME-001'
        PositiveCoherentSetAccepted = $true
        PayloadIdentityMismatchRejected = $true
        FailedSubreportRejected = $true
        InstallerHashMismatchRejected = $true
        InvalidBuildIdentityRejected = $true
        InstalledAssemblyTamperRejected = $true
        OverallPass = $true
    } | ConvertTo-Json -Depth 4
    exit 0
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
