# OMNIX real lifecycle acceptance (repair/reinstall + uninstall)
#
# This is a THREE-PHASE test for a real Windows machine with Office installed.
# It never runs the installer/uninstaller for the user and never changes Office security state.
#
#   Phase 1: Baseline
#     - run after OMNIX is installed and real Office E2E has passed.
#     - snapshots settings.dat hash, OMNIX registration, Office Resiliency tree fingerprints,
#       installed payload and exact development-certificate thumbprint (if present).
#
#   USER ACTION: run the SAME/newer authorized OMNIX installer normally (repair/reinstall/upgrade).
#
#   Phase 2: AfterRepair
#     - requires settings.dat unchanged (DPAPI-protected provider settings preserved),
#       OMNIX registration healthy, app payload present and Office Resiliency unchanged.
#
#   USER ACTION: uninstall OMNIX normally and choose NO when asked whether to delete settings/history.
#
#   Phase 3: AfterUninstall
#     - requires OMNIX-owned registration/payload removed,
#       settings.dat preserved unchanged,
#       Office Resiliency fingerprints unchanged,
#       and the exact development trust certificate (if one was imported) removed.
#
# The report stores hashes/booleans/paths only; it never exports registry payloads, API keys or docs.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Baseline','AfterRepair','AfterUninstall')]
    [string]$Phase,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$SettingsPath = "$env:LOCALAPPDATA\OMNIX\settings.dat",
    [string]$StatePath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-state.json",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stateDir = Split-Path -Parent $StatePath
if ($stateDir) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

function Assert-OfficeClosed {
    $running = @()
    foreach ($name in @('EXCEL','WINWORD','POWERPNT')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
    if ($running.Count -gt 0) {
        throw "Close Excel, Word and PowerPoint before lifecycle acceptance. Running: $($running -join ', ')"
    }
}

function Get-FileHashOrNull([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function Convert-ValueStable($value) {
    if ($null -eq $value) { return '<null>' }
    if ($value -is [byte[]]) { return [Convert]::ToBase64String($value) }
    if ($value -is [Array]) {
        $parts = @()
        foreach ($v in $value) { $parts += [string](Convert-ValueStable $v) }
        return '[' + ($parts -join ',') + ']'
    }
    return [string]$value
}

function Get-TextSha256([string]$text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $safeText = if ($null -eq $text) { '' } else { $text }
        $bytes = [Text.Encoding]::UTF8.GetBytes($safeText)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-RegistryTreeFingerprint([string]$path) {
    if (-not (Test-Path $path)) {
        return [pscustomobject]@{ Exists=$false; Sha256=$null; EntryCount=0 }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $keys = @((Get-Item -Path $path -ErrorAction Stop)) + @(Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue)
    foreach ($key in ($keys | Sort-Object -Property Name)) {
        $lines.Add('KEY|' + [string]$key.Name)
        try {
            $props = Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
            $names = @($props.PSObject.Properties | Where-Object {
                $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')
            } | Select-Object -ExpandProperty Name | Sort-Object)
            foreach ($name in $names) {
                $value = $props.$name
                $lines.Add('VAL|' + $key.Name + '|' + $name + '|' + (Convert-ValueStable $value))
            }
        } catch { }
    }

    $joined = [string]::Join("`n", $lines)
    return [pscustomobject]@{
        Exists = $true
        Sha256 = Get-TextSha256 $joined
        EntryCount = $lines.Count
    }
}

function Get-ResiliencySnapshot {
    $rows = @()
    foreach ($version in @('16.0','15.0')) {
        foreach ($host in @('Excel','Word','PowerPoint')) {
            $path = "HKCU:\Software\Microsoft\Office\$version\$host\Resiliency"
            $fp = Get-RegistryTreeFingerprint $path
            $rows += [ordered]@{
                Version = $version
                Host = $host
                Exists = [bool]$fp.Exists
                Sha256 = $fp.Sha256
                EntryCount = [int]$fp.EntryCount
            }
        }
    }
    return $rows
}

function Compare-Resiliency($baseline, $current) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($b in @($baseline)) {
        $c = @($current | Where-Object { $_.Version -eq $b.Version -and $_.Host -eq $b.Host }) | Select-Object -First 1
        if ($null -eq $c) {
            $errors.Add("Resiliency snapshot missing for $($b.Version)/$($b.Host).")
            continue
        }
        if ([bool]$c.Exists -ne [bool]$b.Exists) {
            $errors.Add("Office Resiliency existence changed for $($b.Version)/$($b.Host).")
            continue
        }
        if ([bool]$b.Exists -and [string]$c.Sha256 -ne [string]$b.Sha256) {
            $errors.Add("Office Resiliency fingerprint changed for $($b.Version)/$($b.Host).")
        }
    }
    return $errors
}

function Resolve-ManifestTarget([string]$manifestValue) {
    if ([string]::IsNullOrWhiteSpace($manifestValue)) { return $null }
    try {
        $value = $manifestValue.Trim()
        if ($value.EndsWith('|vstolocal', [StringComparison]::OrdinalIgnoreCase)) {
            $value = $value.Substring(0, $value.Length - '|vstolocal'.Length)
        }
        if ($value -match '^file:') {
            $uri = New-Object System.Uri($value)
            if (-not $uri.IsFile) { return $null }
            $value = $uri.LocalPath
        }
        return [Environment]::ExpandEnvironmentVariables($value.Trim('"'))
    } catch { return $null }
}

function Get-RegistrationSnapshot {
    $rows = @()
    foreach ($version in @('16.0','15.0')) {
        foreach ($host in @('Excel','Word','PowerPoint')) {
            $path = "HKCU:\Software\Microsoft\Office\$version\$host\Addins\OMNIX"
            if (Test-Path $path) {
                $p = Get-ItemProperty -Path $path
                $manifest = Resolve-ManifestTarget ([string]$p.Manifest)
                $rows += [ordered]@{
                    Version = $version
                    Host = $host
                    Path = $path
                    Exists = $true
                    LoadBehavior = [int]$p.LoadBehavior
                    ManifestTarget = $manifest
                    ManifestExists = [bool]($manifest -and (Test-Path -LiteralPath $manifest -PathType Leaf))
                    FriendlyName = [string]$p.FriendlyName
                }
            }
        }
    }
    return $rows
}

function Test-HealthyRegistration($rows) {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($host in @('Excel','Word','PowerPoint')) {
        $hostRows = @($rows | Where-Object { $_.Host -eq $host -and $_.Exists })
        if ($hostRows.Count -lt 1) {
            $errors.Add("OMNIX registration missing for $host.")
            continue
        }
        foreach ($r in $hostRows) {
            if ([int]$r.LoadBehavior -ne 3) { $errors.Add("$host/$($r.Version) LoadBehavior is not 3.") }
            if (-not [bool]$r.ManifestExists) { $errors.Add("$host/$($r.Version) registered manifest target is missing.") }
            if ([string]$r.FriendlyName -ne 'OMNIX') { $errors.Add("$host/$($r.Version) FriendlyName is unexpected.") }
        }
    }
    return $errors
}

function Get-DevCertThumbprint([string]$installDir) {
    $marker = Join-Path $installDir 'dev-cert-thumbprint.txt'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $null }
    try {
        $text = (Get-Content -LiteralPath $marker -Raw).Trim().Replace(' ','')
        if ($text -match '^[0-9A-Fa-f]{40,64}$') { return $text.ToUpperInvariant() }
    } catch { }
    return $null
}

function Test-CertPresent([string]$storeName, [string]$thumbprint) {
    if ([string]::IsNullOrWhiteSpace($thumbprint)) { return $false }
    $path = "Cert:\CurrentUser\$storeName\$thumbprint"
    return [bool](Test-Path -LiteralPath $path)
}

function Get-CurrentSnapshot {
    $settingsHash = Get-FileHashOrNull $SettingsPath
    $thumb = Get-DevCertThumbprint $InstallDir
    return [ordered]@{
        CapturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        InstallDirExists = [bool](Test-Path -LiteralPath $InstallDir -PathType Container)
        CoreExists = [bool](Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)
        SettingsExists = [bool](Test-Path -LiteralPath $SettingsPath -PathType Leaf)
        SettingsSha256 = $settingsHash
        Registrations = @(Get-RegistrationSnapshot)
        Resiliency = @(Get-ResiliencySnapshot)
        DevelopmentCertThumbprint = $thumb
        DevelopmentCertTrustedPublisherPresent = [bool](Test-CertPresent 'TrustedPublisher' $thumb)
        DevelopmentCertRootPresent = [bool](Test-CertPresent 'Root' $thumb)
    }
}

Assert-OfficeClosed

if ($Phase -eq 'Baseline') {
    $baseline = Get-CurrentSnapshot
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $baseline.CoreExists) { $errors.Add('OMNIX.Core.dll is not installed; baseline cannot be established.') }
    if (-not $baseline.SettingsExists) { $errors.Add('settings.dat does not exist; create/save OMNIX settings before lifecycle acceptance.') }
    foreach ($e in @(Test-HealthyRegistration $baseline.Registrations)) { $errors.Add([string]$e) }

    $baselinePass = ($errors.Count -eq 0)
    $state = [ordered]@{
        TestId = 'LIFECYCLE-REAL-001'
        EvidenceSchema = 1
        BaselinePass = $baselinePass
        Baseline = $baseline
        Repair = $null
        Uninstall = $null
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    $report = [ordered]@{
        TestId = 'LIFECYCLE-REAL-001'
        EvidenceSchema = 1
        Phase = 'Baseline'
        FailureCount = $errors.Count
        Failures = @($errors)
        BaselinePass = $baselinePass
        RepairPass = $false
        UninstallPass = $false
        OverallPass = $false
        NextAction = 'Run the authorized OMNIX installer normally as repair/reinstall/upgrade, then run this script with -Phase AfterRepair.'
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    $report | ConvertTo-Json -Depth 8
    if ($errors.Count -gt 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Lifecycle baseline state not found: $StatePath. Run -Phase Baseline first."
}
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
if ($state.TestId -ne 'LIFECYCLE-REAL-001' -or $null -eq $state.Baseline) {
    throw 'Lifecycle state is invalid or not a LIFECYCLE-REAL-001 baseline.'
}
if (-not [bool]$state.BaselinePass) {
    throw 'Lifecycle baseline did not PASS; establish a clean passing baseline before continuing.'
}

$baseline = $state.Baseline
$current = Get-CurrentSnapshot
$errors = New-Object System.Collections.Generic.List[string]

if ($Phase -eq 'AfterRepair') {
    if (-not $current.CoreExists) { $errors.Add('OMNIX.Core.dll is missing after repair/reinstall.') }
    if (-not $current.SettingsExists) { $errors.Add('settings.dat is missing after repair/reinstall.') }
    if ([string]$current.SettingsSha256 -ne [string]$baseline.SettingsSha256) {
        $errors.Add('settings.dat changed during repair/reinstall; exact settings/API-key payload was not preserved.')
    }
    foreach ($e in @(Compare-Resiliency $baseline.Resiliency $current.Resiliency)) { $errors.Add([string]$e) }
    foreach ($e in @(Test-HealthyRegistration $current.Registrations)) { $errors.Add([string]$e) }

    $repairPass = ($errors.Count -eq 0)
    $state.Repair = [ordered]@{
        CapturedUtc = $current.CapturedUtc
        Pass = $repairPass
        SettingsPreserved = ([string]$current.SettingsSha256 -eq [string]$baseline.SettingsSha256)
        ResiliencyPreserved = (@(Compare-Resiliency $baseline.Resiliency $current.Resiliency).Count -eq 0)
        RegistrationHealthy = (@(Test-HealthyRegistration $current.Registrations).Count -eq 0)
        Snapshot = $current
    }
    $state | ConvertTo-Json -Depth 11 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    $report = [ordered]@{
        TestId = 'LIFECYCLE-REAL-001'
        EvidenceSchema = 1
        Phase = 'AfterRepair'
        FailureCount = $errors.Count
        Failures = @($errors)
        BaselinePass = $true
        RepairPass = $repairPass
        UninstallPass = $false
        OverallPass = $false
        NextAction = 'Uninstall OMNIX normally and choose NO when asked to remove settings/chat history. Then run -Phase AfterUninstall.'
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    $report | ConvertTo-Json -Depth 8
    if (-not $repairPass) { exit 1 }
    exit 0
}

# AfterUninstall
if ($null -eq $state.Repair -or -not [bool]$state.Repair.Pass) {
    $errors.Add('A passing AfterRepair phase is required before AfterUninstall.')
}
if ($current.CoreExists -or $current.InstallDirExists) {
    $errors.Add('OMNIX application payload/install directory still exists after uninstall.')
}
if (-not $current.SettingsExists) {
    $errors.Add('settings.dat was removed; lifecycle acceptance requires choosing NO to user-data deletion.')
} elseif ([string]$current.SettingsSha256 -ne [string]$baseline.SettingsSha256) {
    $errors.Add('settings.dat changed or was replaced across uninstall.')
}
if (@($current.Registrations).Count -ne 0) {
    $errors.Add('One or more OMNIX Office add-in registry keys remain after uninstall.')
}
foreach ($e in @(Compare-Resiliency $baseline.Resiliency $current.Resiliency)) { $errors.Add([string]$e) }

$baselineThumb = [string]$baseline.DevelopmentCertThumbprint
$certRemovalPass = $true
if (-not [string]::IsNullOrWhiteSpace($baselineThumb)) {
    if (Test-CertPresent 'TrustedPublisher' $baselineThumb) {
        $errors.Add('Exact OMNIX development certificate still exists in CurrentUser TrustedPublisher after uninstall.')
        $certRemovalPass = $false
    }
    if (Test-CertPresent 'Root' $baselineThumb) {
        $errors.Add('Exact OMNIX development certificate still exists in CurrentUser Root after uninstall.')
        $certRemovalPass = $false
    }
}

$uninstallPass = ($errors.Count -eq 0)
$state.Uninstall = [ordered]@{
    CapturedUtc = $current.CapturedUtc
    Pass = $uninstallPass
    SettingsPreserved = ($current.SettingsExists -and [string]$current.SettingsSha256 -eq [string]$baseline.SettingsSha256)
    OmnixRegistrationRemoved = (@($current.Registrations).Count -eq 0)
    AppPayloadRemoved = (-not $current.CoreExists -and -not $current.InstallDirExists)
    ResiliencyPreserved = (@(Compare-Resiliency $baseline.Resiliency $current.Resiliency).Count -eq 0)
    DevelopmentCertificateRemoved = $certRemovalPass
}
$state | ConvertTo-Json -Depth 11 | Set-Content -LiteralPath $StatePath -Encoding UTF8

$report = [ordered]@{
    TestId = 'LIFECYCLE-REAL-001'
    EvidenceSchema = 1
    Phase = 'AfterUninstall'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    FailureCount = $errors.Count
    Failures = @($errors)
    BaselinePass = [bool]$state.BaselinePass
    RepairPass = [bool]$state.Repair.Pass
    SettingsPreservedAcrossRepair = [bool]$state.Repair.SettingsPreserved
    ResiliencyPreservedAcrossRepair = [bool]$state.Repair.ResiliencyPreserved
    RegistrationHealthyAfterRepair = [bool]$state.Repair.RegistrationHealthy
    UninstallPass = $uninstallPass
    SettingsPreservedAcrossUninstall = [bool]$state.Uninstall.SettingsPreserved
    OmnixRegistrationRemoved = [bool]$state.Uninstall.OmnixRegistrationRemoved
    AppPayloadRemoved = [bool]$state.Uninstall.AppPayloadRemoved
    ResiliencyPreservedAcrossUninstall = [bool]$state.Uninstall.ResiliencyPreserved
    DevelopmentCertificateRemoved = [bool]$state.Uninstall.DevelopmentCertificateRemoved
    OverallPass = [bool]([bool]$state.BaselinePass -and [bool]$state.Repair.Pass -and $uninstallPass)
    Privacy = 'Hash-only lifecycle evidence; no settings contents, API keys, registry values or Office documents are copied into the report.'
    Safety = 'Read-only snapshots. Installer/uninstaller actions are explicitly performed by the user through supported UI.'
}
$report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 9

if (-not $report.OverallPass) { exit 1 }
exit 0
