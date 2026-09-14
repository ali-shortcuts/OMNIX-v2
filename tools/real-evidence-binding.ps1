# OMNIX real-machine evidence binding helpers.
#
# Release evidence is useful only when it can be tied to the exact source under review and to the
# exact installed payload that was exercised on the Windows machine. The installed payload carries
# OMNIX-build-identity.json, generated during packaging from the exact Git commit and the hashes of
# OMNIX.Core + all three Office host assemblies. These helpers verify that identity before creating
# any EvidenceBinding.
#
# These helpers are intentionally read-only: they never install, register, mutate Office, restart
# Windows, or change networking.

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

function Get-OmnixFileSha256 {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found for evidence binding: $Path"
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -le 0) {
        throw "$Label is empty for evidence binding: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
}

function Get-OmnixCoreSha256 {
    param([Parameter(Mandatory=$true)][string]$CorePath)
    return Get-OmnixFileSha256 -Path $CorePath -Label 'OMNIX.Core.dll'
}

function Read-VerifiedOmnixBuildIdentity {
    param(
        [Parameter(Mandatory=$true)][string]$CorePath,
        [string]$SourceCommit
    )

    $resolvedCore = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
    $installDir = Split-Path -Parent $resolvedCore
    $identityPath = Join-Path $installDir 'OMNIX-build-identity.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw "Installed OMNIX build identity is missing: $identityPath"
    }

    try {
        $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Installed OMNIX build identity is invalid JSON: $identityPath - $($_.Exception.Message)"
    }

    if ($identity.TestId -ne 'OMNIX-BUILD-IDENTITY-001') {
        throw 'Installed OMNIX build identity has an unexpected TestId.'
    }
    if ([int]$identity.EvidenceSchema -lt 1) {
        throw 'Installed OMNIX build identity schema is too old.'
    }

    $identitySource = ([string]$identity.SourceCommit).Trim().ToLowerInvariant()
    if ($identitySource -notmatch '^[0-9a-f]{40}$') {
        throw 'Installed OMNIX build identity SourceCommit is invalid.'
    }

    $resolvedSource = Resolve-OmnixSourceCommit -ExplicitSourceCommit $SourceCommit
    if ($identitySource -ne $resolvedSource) {
        throw "Installed OMNIX payload source does not match the release checkout. Installed=$identitySource Expected=$resolvedSource"
    }

    $expected = [ordered]@{
        'OMNIX.Core.dll' = ([string]$identity.CoreSha256).Trim().ToLowerInvariant()
        'OMNIX.Excel.dll' = ([string]$identity.ExcelSha256).Trim().ToLowerInvariant()
        'OMNIX.Word.dll' = ([string]$identity.WordSha256).Trim().ToLowerInvariant()
        'OMNIX.PowerPoint.dll' = ([string]$identity.PowerPointSha256).Trim().ToLowerInvariant()
    }

    foreach ($entry in $expected.GetEnumerator()) {
        if ($entry.Value -notmatch '^[0-9a-f]{64}$') {
            throw "Installed OMNIX build identity contains an invalid SHA256 for $($entry.Key)."
        }
        $actual = Get-OmnixFileSha256 -Path (Join-Path $installDir $entry.Key) -Label $entry.Key
        if ($actual -ne $entry.Value) {
            throw "Installed OMNIX assembly does not match build identity: $($entry.Key)."
        }
    }

    return [pscustomobject]@{
        TestId = [string]$identity.TestId
        EvidenceSchema = [int]$identity.EvidenceSchema
        SourceCommit = $identitySource
        CoreSha256 = [string]$expected['OMNIX.Core.dll']
        ExcelSha256 = [string]$expected['OMNIX.Excel.dll']
        WordSha256 = [string]$expected['OMNIX.Word.dll']
        PowerPointSha256 = [string]$expected['OMNIX.PowerPoint.dll']
        IdentityPath = $identityPath
        IdentitySha256 = Get-OmnixFileSha256 -Path $identityPath -Label 'OMNIX-build-identity.json'
    }
}

function New-OmnixEvidenceBinding {
    param(
        [Parameter(Mandatory=$true)][string]$CorePath,
        [string]$SourceCommit
    )

    $verified = Read-VerifiedOmnixBuildIdentity -CorePath $CorePath -SourceCommit $SourceCommit
    return [ordered]@{
        BindingSchema = 2
        SourceCommit = $verified.SourceCommit
        CoreSha256 = $verified.CoreSha256
        PayloadIdentitySha256 = $verified.IdentitySha256
        BuildIdentityTestId = $verified.TestId
        PrimaryAssembliesValidated = $true
        CoreFileName = 'OMNIX.Core.dll'
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
        [Parameter(Mandatory=$true)][string]$ExpectedPayloadIdentitySha256,
        [Parameter(Mandatory=$true)][double]$MaxAgeHours,
        [Parameter(Mandatory=$true)][string]$Label,
        [DateTime]$NowUtc = ([DateTime]::UtcNow)
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $expectedSource = $ExpectedSourceCommit.Trim().ToLowerInvariant()
    $expectedCore = $ExpectedCoreSha256.Trim().ToLowerInvariant()
    $expectedIdentity = $ExpectedPayloadIdentitySha256.Trim().ToLowerInvariant()

    if ($expectedSource -notmatch '^[0-9a-f]{40}$') {
        $errors.Add("$Label expected source commit is invalid.")
        return $errors
    }
    if ($expectedCore -notmatch '^[0-9a-f]{64}$') {
        $errors.Add("$Label expected Core SHA256 is invalid.")
        return $errors
    }
    if ($expectedIdentity -notmatch '^[0-9a-f]{64}$') {
        $errors.Add("$Label expected payload identity SHA256 is invalid.")
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
        if ([int]$Report.EvidenceBinding.BindingSchema -lt 2) {
            $errors.Add("$Label EvidenceBinding schema is too old for installed payload identity.")
        }
        $source = ([string]$Report.EvidenceBinding.SourceCommit).Trim().ToLowerInvariant()
        $core = ([string]$Report.EvidenceBinding.CoreSha256).Trim().ToLowerInvariant()
        $identity = ([string]$Report.EvidenceBinding.PayloadIdentitySha256).Trim().ToLowerInvariant()
        if ($source -ne $expectedSource) {
            $errors.Add("$Label source commit does not match the release candidate.")
        }
        if ($core -ne $expectedCore) {
            $errors.Add("$Label OMNIX.Core SHA256 does not match the installed release candidate.")
        }
        if ($identity -ne $expectedIdentity) {
            $errors.Add("$Label installed payload identity SHA256 does not match the release candidate.")
        }
        if ([string]$Report.EvidenceBinding.BuildIdentityTestId -ne 'OMNIX-BUILD-IDENTITY-001') {
            $errors.Add("$Label build identity TestId is missing or invalid.")
        }
        if (-not [bool]$Report.EvidenceBinding.PrimaryAssembliesValidated) {
            $errors.Add("$Label did not prove validation of the primary installed assemblies.")
        }
    }

    foreach ($freshnessError in @(Test-OmnixEvidenceFreshness -Report $Report -MaxAgeHours $MaxAgeHours -Label $Label -NowUtc $NowUtc)) {
        $errors.Add([string]$freshnessError)
    }
    return $errors
}
