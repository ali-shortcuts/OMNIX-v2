# Fail-closed source/build/freshness guard for OMNIX final production evidence.
# Canonical caller: tools/final-production-gate.ps1
#
# This guard is composable: it throws on rejection and returns normally on success. It does not
# call exit, install software, restart Windows, change networking, or alter security settings.

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
    [string]$ExpectedSourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bindingScript = Join-Path $scriptDir 'real-evidence-binding.ps1'
if (-not (Test-Path -LiteralPath $bindingScript -PathType Leaf)) { throw "Evidence binding helper missing: $bindingScript" }
. $bindingScript

function Read-Json([string]$path,[string]$label) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$label report not found: $path" }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { throw "$label report is not valid JSON: $path - $($_.Exception.Message)" }
}
function Add-Errors($target,$items) { foreach ($e in @($items)) { if (-not [string]::IsNullOrWhiteSpace([string]$e)) { $target.Add([string]$e) } } }
function Test-FreshTimestamp($report,[double]$maxAgeHours,[string]$label) {
    $errors = New-Object System.Collections.Generic.List[string]
    $parsed = [DateTime]::MinValue
    if ([string]::IsNullOrWhiteSpace([string]$report.TimestampUtc) -or -not [DateTime]::TryParse([string]$report.TimestampUtc,[ref]$parsed)) { $errors.Add("$label TimestampUtc is missing or invalid."); return $errors }
    $parsed = $parsed.ToUniversalTime(); $now = [DateTime]::UtcNow
    if ($parsed -gt $now.AddMinutes(10)) { $errors.Add("$label TimestampUtc is implausibly in the future.") }
    elseif ($parsed -lt $now.AddHours(-1 * $maxAgeHours)) { $errors.Add("$label evidence is stale; maximum age is $maxAgeHours hours.") }
    return $errors
}

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Length -le 0) { throw 'Installer is empty.' }
$installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()
$source = Resolve-OmnixSourceCommit -ExplicitSourceCommit $ExpectedSourceCommit

$office = Read-Json $OfficeE2EReport 'Office E2E'
$persistence = Read-Json $OfficePersistenceReport 'Office persistence'
$ui = Read-Json $OfficeUiReport 'Office UI'
$restart = Read-Json $OfficeRestartReport 'Restart persistence'
$offline = Read-Json $LocalOfflineReport 'Local offline'
$provider = Read-Json $ProviderReport 'Provider'
$lifecycle = Read-Json $LifecycleReport 'Lifecycle'
$security = Read-Json $ConsumerSecurityReport 'Consumer security'
$failures = New-Object System.Collections.Generic.List[string]

if ($office.TestId -ne 'OFFICE-E2E-REAL-001') { $failures.Add('Unexpected Office E2E TestId.') }
if ([int]$office.EvidenceSchema -lt 5) { $failures.Add('Office E2E evidence schema is too old for build binding.') }
if (-not [bool]$office.OverallPass) { $failures.Add('Office E2E did not pass.') }
if ([string]$office.Installer.Sha256 -ne $installerHash) { $failures.Add('Office E2E installer SHA256 does not match the production candidate.') }
if ($null -eq $office.Installer.HashMatchedExpected -or -not [bool]$office.Installer.HashMatchedExpected) { $failures.Add('Office E2E did not explicitly match the expected installer SHA256.') }

$expectedCore = ''
$expectedIdentity = ''
if ($null -eq $office.EvidenceBinding) {
    $failures.Add('Office E2E EvidenceBinding is missing. Use bound-real-acceptance.ps1.')
}
else {
    $expectedCore = ([string]$office.EvidenceBinding.CoreSha256).Trim().ToLowerInvariant()
    $expectedIdentity = ([string]$office.EvidenceBinding.PayloadIdentitySha256).Trim().ToLowerInvariant()
    if ([int]$office.EvidenceBinding.BindingSchema -lt 2) { $failures.Add('Office E2E binding schema is too old for installed payload identity.') }
    if ($expectedCore -notmatch '^[0-9a-f]{64}$') { $failures.Add('Office E2E CoreSha256 is invalid.') }
    if ($expectedIdentity -notmatch '^[0-9a-f]{64}$') { $failures.Add('Office E2E PayloadIdentitySha256 is invalid.') }
    if ([string]$office.EvidenceBinding.BuildIdentityTestId -ne 'OMNIX-BUILD-IDENTITY-001') { $failures.Add('Office E2E build identity TestId is missing or invalid.') }
    if (-not [bool]$office.EvidenceBinding.PrimaryAssembliesValidated) { $failures.Add('Office E2E did not validate the primary installed assemblies.') }
}

if ($expectedCore -match '^[0-9a-f]{64}$' -and $expectedIdentity -match '^[0-9a-f]{64}$') {
    foreach ($row in @(
        @{Report=$office;Age=168;Label='Office E2E'},
        @{Report=$persistence;Age=168;Label='Office persistence'},
        @{Report=$ui;Age=168;Label='Office UI'},
        @{Report=$restart;Age=168;Label='Windows restart persistence'},
        @{Report=$offline;Age=72;Label='Offline local AI'},
        @{Report=$provider;Age=72;Label='Live provider matrix'}
    )) {
        Add-Errors $failures (Test-OmnixEvidenceBinding -Report $row.Report -ExpectedSourceCommit $source -ExpectedCoreSha256 $expectedCore -ExpectedPayloadIdentitySha256 $expectedIdentity -MaxAgeHours $row.Age -Label $row.Label)
    }
}

if ($lifecycle.TestId -ne 'LIFECYCLE-REAL-002') { $failures.Add('Unexpected lifecycle TestId.') }
if ([string]$lifecycle.InstallerSha256 -ne $installerHash) { $failures.Add('Lifecycle evidence is for a different installer.') }
Add-Errors $failures (Test-FreshTimestamp $lifecycle 168 'Lifecycle')
if ($security.TestId -ne 'CONSUMER-SECURITY-REAL-001') { $failures.Add('Unexpected consumer-security TestId.') }
if ([string]$security.Installer.Sha256 -ne $installerHash) { $failures.Add('Consumer-security evidence is for a different installer.') }
Add-Errors $failures (Test-FreshTimestamp $security 72 'Consumer security')

if ($failures.Count -gt 0) { throw ('FINAL-EVIDENCE-BINDING-REJECTED: ' + ($failures -join ' | ')) }

[pscustomobject]@{
    TestId = 'FINAL-EVIDENCE-BINDING-GUARD-001'
    SourceCommit = $source
    InstallerSha256 = $installerHash
    CoreSha256 = $expectedCore
    PayloadIdentitySha256 = $expectedIdentity
    PrimaryAssembliesValidated = $true
    OfficeEvidenceMaxAgeHours = 168
    ProviderAndOfflineMaxAgeHours = 72
    ConsumerSecurityMaxAgeHours = 72
    OverallPass = $true
} | ConvertTo-Json -Depth 5
return
