# OMNIX real-machine evidence binding helpers.
#
# Release evidence is useful only when it can be tied to the exact source under review and to the
# exact OMNIX.Core payload that was exercised on the Windows machine. These helpers are intentionally
# read-only: they never install, register, mutate Office, restart Windows, or change networking.

Set-StrictMode -Version Latest

$script:OmnixEvidenceToolsDir = $PSScriptRoot
$script:OmnixEvidenceRepoRoot = Split-Path -Parent $script:OmnixEvidenceToolsDir

function Resolve-OmnixSourceCommit {
    param([string]$ExplicitSourceCommit)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSourceCommit)) {
        $candidate = $ExplicitSourceCommit.Trim().ToLowerInvariant()
        if ($candidate -notmatch '^[0-9a-f]{40}$') {
            throw 'Explicit OMNIX source commit must be exactly 40 hexadecimal characters.'
        }
        return $candidate
    }

    try {
        Push-Location $script:OmnixEvidenceRepoRoot
        try {
            $candidate = (& git rev-parse HEAD 2>$null).Trim().ToLowerInvariant()
            if ($LASTEXITCODE -eq 0 -and $candidate -match '^[0-9a-f]{40}$') {
                return $candidate
            }
        }
        finally {
            Pop-Location
        }
    }
    catch { }

    # Exact-source GitHub release ZIPs contain this marker at repository root.
    $marker = Join-Path $script:OmnixEvidenceRepoRoot 'SOURCE-COMMIT.txt'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $candidate = (Get-Content -LiteralPath $marker -Raw).Trim().ToLowerInvariant()
        if ($candidate -match '^[0-9a-f]{40}$') {
            return $candidate
        }
        throw "SOURCE-COMMIT.txt is present but invalid: $marker"
    }

    throw 'Could not resolve exact OMNIX source commit from Git or SOURCE-COMMIT.txt.'
}

function Get-OmnixCoreSha256 {
    param([Parameter(Mandatory=$true)][string]$CorePath)

    if (-not (Test-Path -LiteralPath $CorePath -PathType Leaf)) {
        throw "OMNIX.Core.dll not found for evidence binding: $CorePath"
    }
    $item = Get-Item -LiteralPath $CorePath
    if ($item.Length -le 0) {
        throw "OMNIX.Core.dll is empty for evidence binding: $CorePath"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
}

function New-OmnixEvidenceBinding {
    param(
        [Parameter(Mandatory=$true)][string]$CorePath,
        [string]$SourceCommit
    )

    $resolvedSource = Resolve-OmnixSourceCommit -ExplicitSourceCommit $SourceCommit
    $resolvedCore = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
    return [ordered]@{
        BindingSchema = 1
        SourceCommit = $resolvedSource
        CoreSha256 = Get-OmnixCoreSha256 -CorePath $resolvedCore
        CoreFileName = [IO.Path]::GetFileName($resolvedCore)
    }
}

function Test-OmnixEvidenceFreshness {
    param(
        [Parameter(Mandatory=$true)]$Report,
        [Parameter(Mandatory=$true)][double]$MaxAgeHours,
        [Parameter(Mandatory=$true)][string]$Label,
        [DateTime]$NowUtc = ([DateTime]::UtcNow)
    )

    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Report) {
        $errors.Add("$Label report is missing.")
        return $errors
    }
    if ($MaxAgeHours -le 0 -or $MaxAgeHours -gt 168) {
        $errors.Add("$Label freshness policy is invalid; MaxAgeHours must be > 0 and <= 168.")
        return $errors
    }

    $timestamp = [DateTime]::MinValue
    if ([string]::IsNullOrWhiteSpace([string]$Report.TimestampUtc) -or
        -not [DateTime]::TryParse([string]$Report.TimestampUtc, [ref]$timestamp)) {
        $errors.Add("$Label TimestampUtc is missing or invalid.")
        return $errors
    }

    $timestamp = $timestamp.ToUniversalTime()
    $now = $NowUtc.ToUniversalTime()
    if ($timestamp -gt $now.AddMinutes(10)) {
        $errors.Add("$Label TimestampUtc is implausibly in the future.")
    }
    elseif ($timestamp -lt $now.AddHours(-1 * $MaxAgeHours)) {
        $errors.Add("$Label evidence is stale; maximum age is $MaxAgeHours hours.")
    }
    return $errors
}

function Test-OmnixEvidenceBinding {
    param(
        [Parameter(Mandatory=$true)]$Report,
        [Parameter(Mandatory=$true)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory=$true)][string]$ExpectedCoreSha256,
        [Parameter(Mandatory=$true)][double]$MaxAgeHours,
        [Parameter(Mandatory=$true)][string]$Label,
        [DateTime]$NowUtc = ([DateTime]::UtcNow)
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $expectedSource = $ExpectedSourceCommit.Trim().ToLowerInvariant()
    $expectedCore = $ExpectedCoreSha256.Trim().ToLowerInvariant()

    if ($expectedSource -notmatch '^[0-9a-f]{40}$') {
        $errors.Add("$Label expected source commit is invalid.")
        return $errors
    }
    if ($expectedCore -notmatch '^[0-9a-f]{64}$') {
        $errors.Add("$Label expected Core SHA256 is invalid.")
        return $errors
    }

    if ($null -eq $Report) {
        $errors.Add("$Label report is missing.")
        return $errors
    }

    if ($null -eq $Report.EvidenceBinding) {
        $errors.Add("$Label EvidenceBinding is missing.")
    }
    else {
        if ([int]$Report.EvidenceBinding.BindingSchema -lt 1) {
            $errors.Add("$Label EvidenceBinding schema is invalid.")
        }
        $source = ([string]$Report.EvidenceBinding.SourceCommit).Trim().ToLowerInvariant()
        $core = ([string]$Report.EvidenceBinding.CoreSha256).Trim().ToLowerInvariant()
        if ($source -ne $expectedSource) {
            $errors.Add("$Label source commit does not match the release candidate.")
        }
        if ($core -ne $expectedCore) {
            $errors.Add("$Label OMNIX.Core SHA256 does not match the installed release candidate.")
        }
    }

    foreach ($freshnessError in @(Test-OmnixEvidenceFreshness -Report $Report -MaxAgeHours $MaxAgeHours -Label $Label -NowUtc $NowUtc)) {
        $errors.Add([string]$freshnessError)
    }
    return $errors
}
