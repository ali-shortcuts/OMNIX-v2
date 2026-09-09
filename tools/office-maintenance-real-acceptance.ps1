# OMNIX real automatic Office registration maintenance acceptance
#
# Intended for the same interactive Windows machine used for final Excel/Word/PowerPoint E2E.
# It proves that the installed per-user maintenance task exists with LIMITED privileges, runs the
# installed scanner, repairs OMNIX-owned registration for supported Office hosts, preserves shared
# Office Resiliency state byte-for-byte (represented only by privacy-safe hashes), and launches no
# Office process. It never changes network/Trust Center/Resiliency and never opens documents.

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\office-maintenance-real-acceptance.json",
    [int]$RequiredHostCount = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'OMNIX Office Registration Maintenance'
$maintenanceScript = Join-Path $InstallDir 'office-registration-maintenance.ps1'
$maintenanceReport = Join-Path (Split-Path -Parent $OutputPath) 'office-registration-maintenance-real-run.json'

function Assert-OfficeClosed {
    $running = @()
    foreach ($name in @('EXCEL','WINWORD','POWERPNT')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
    if ($running.Count -gt 0) { throw "Close all Office applications before maintenance acceptance: $($running -join ', ')" }
}

function Get-Sha256Hex([byte[]]$bytes) {
    if ($null -eq $bytes) { $bytes = New-Object byte[] 0 }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Convert-ValueBytes($value) {
    if ($null -eq $value) { return [byte[]]@() }
    if ($value -is [byte[]]) { return [byte[]]$value }
    if ($value -is [string[]]) { return [Text.Encoding]::UTF8.GetBytes(($value -join "`0")) }
    return [Text.Encoding]::UTF8.GetBytes([string]$value)
}

function Get-KeyDigest([Microsoft.Win32.RegistryKey]$key, [string]$relative = '') {
    $lines = @()
    if ($null -eq $key) { return $lines }

    foreach ($name in @($key.GetValueNames() | Sort-Object)) {
        try {
            $kind = [string]$key.GetValueKind($name)
            $bytes = Convert-ValueBytes ($key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))
            $sha = Get-Sha256Hex $bytes
            $lines += "$relative|$name|$kind|$sha"
        } catch {
            $lines += "$relative|$name|UNREADABLE"
        }
    }

    foreach ($sub in @($key.GetSubKeyNames() | Sort-Object)) {
        $child = $null
        try {
            $child = $key.OpenSubKey($sub, $false)
            $childRel = if ([string]::IsNullOrEmpty($relative)) { $sub } else { "$relative\$sub" }
            foreach ($line in Get-KeyDigest $child $childRel) { $lines += $line }
        } finally {
            if ($null -ne $child) { $child.Dispose() }
        }
    }
    return $lines
}

function Get-ResiliencyFingerprint {
    $all = @()
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    foreach ($version in @('16.0','15.0')) {
        foreach ($officeHostName in @('Excel','Word','PowerPoint')) {
            $sub = "Software\Microsoft\Office\$version\$officeHostName\Resiliency"
            $key = $null
            try {
                $key = $hkcu.OpenSubKey($sub, $false)
                if ($null -eq $key) {
                    $all += "$version/$officeHostName|ABSENT"
                } else {
                    foreach ($line in Get-KeyDigest $key '') { $all += "$version/$officeHostName|$line" }
                }
            } finally {
                if ($null -ne $key) { $key.Dispose() }
            }
        }
    }
    $text = ($all | Sort-Object) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    return [pscustomobject]@{ EntryCount=$all.Count; Sha256=(Get-Sha256Hex $bytes) }
}

function Get-RegistrationRow([string]$version,[string]$officeHostName) {
    $path = "HKCU:\Software\Microsoft\Office\$version\$officeHostName\Addins\OMNIX"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Version=$version; Host=$officeHostName; Exists=$false; LoadBehavior=$null; ManifestOk=$false; Pass=$false }
    }
    $p = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    $manifest = [string]$p.Manifest
    $manifestFile = Join-Path $InstallDir ("OMNIX.$officeHostName.vsto")
    $uri = New-Object System.Uri -ArgumentList $manifestFile
    $expected = ($uri.AbsoluteUri + '|vstolocal')
    return [pscustomobject]@{
        Version=$version; Host=$officeHostName; Exists=$true; LoadBehavior=$p.LoadBehavior
        ManifestOk=[string]::Equals($manifest,$expected,[StringComparison]::OrdinalIgnoreCase)
        Pass=($p.LoadBehavior -eq 3 -and [string]::Equals($manifest,$expected,[StringComparison]::OrdinalIgnoreCase))
    }
}

$failures = @()
$result = [ordered]@{
    TestId = 'OFFICE-MAINTENANCE-REAL-001'
    EvidenceSchema = 2
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    RequiredHostCount = $RequiredHostCount
    MaintenanceTaskPresent = $false
    MaintenanceTaskLimited = $false
    MaintenanceTaskCurrentUser = $false
    MaintenanceTaskLogonTrigger = $false
    MaintenanceTaskActionBoundToInstalledScanner = $false
    MaintenanceRunPass = $false
    InstalledRegistrationCount = 0
    InstalledHostCount = 0
    RegisteredHostCount = 0
    AllInstalledRegistrationsPass = $false
    SharedOfficeResiliencyPreserved = $false
    OfficeProcessesRemainedClosed = $false
    BeforeResiliencySha256 = $null
    AfterResiliencySha256 = $null
    RegistrationResults = @()
    FailureCount = 0
    Failures = @()
    OverallPass = $false
    Privacy = 'Registry recovery values are compared only through SHA-256 fingerprints; no document data, paths from recovery values, provider responses or secrets are emitted.'
}

try {
    Assert-OfficeClosed
    if (-not (Test-Path -LiteralPath $maintenanceScript -PathType Leaf)) { throw "Installed maintenance scanner is missing: $maintenanceScript" }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)) { throw 'Installed OMNIX.Core.dll is missing.' }

    $before = Get-ResiliencyFingerprint
    $result.BeforeResiliencySha256 = $before.Sha256

    Import-Module ScheduledTasks -ErrorAction Stop
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $result.MaintenanceTaskPresent = ($null -ne $task)
    if (-not $result.MaintenanceTaskPresent) {
        $failures += 'Transparent per-user OMNIX Office maintenance task is missing.'
    } else {
        $result.MaintenanceTaskLimited = ([string]$task.Principal.RunLevel -ne 'Highest')
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $result.MaintenanceTaskCurrentUser = [string]::Equals([string]$task.Principal.UserId,$currentUser,[StringComparison]::OrdinalIgnoreCase)
        $result.MaintenanceTaskLogonTrigger = @($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -gt 0
        $actionText = (@($task.Actions | ForEach-Object { ([string]$_.Execute) + ' ' + ([string]$_.Arguments) }) -join ' ')
        $result.MaintenanceTaskActionBoundToInstalledScanner = ($actionText -match [Regex]::Escape('office-registration-maintenance.ps1')) -and ($actionText -match [Regex]::Escape($InstallDir))

        if (-not $result.MaintenanceTaskLimited) { $failures += 'Maintenance task is configured for elevated/highest execution.' }
        if (-not $result.MaintenanceTaskCurrentUser) { $failures += 'Maintenance task is not scoped to the current installing user.' }
        if (-not $result.MaintenanceTaskLogonTrigger) { $failures += 'Maintenance task has no current-user logon trigger.' }
        if (-not $result.MaintenanceTaskActionBoundToInstalledScanner) { $failures += 'Maintenance task action is not bound to the installed OMNIX scanner.' }
    }

    if (Test-Path -LiteralPath $maintenanceReport) { Remove-Item -LiteralPath $maintenanceReport -Force }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile','-NonInteractive','-File',$maintenanceScript,
        '-InstallDir',$InstallDir,'-OutputPath',$maintenanceReport,'-Quiet') -Wait -PassThru -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $maintenanceReport -PathType Leaf)) { throw "Maintenance scanner produced no report (exit=$($proc.ExitCode))." }
    $maintenance = Get-Content -LiteralPath $maintenanceReport -Raw | ConvertFrom-Json
    $result.MaintenanceRunPass = ($proc.ExitCode -eq 0 -and $maintenance.TestId -eq 'OFFICE-REGISTRATION-MAINTENANCE-001' -and [int]$maintenance.EvidenceSchema -ge 2 -and [bool]$maintenance.OverallPass)
    $result.InstalledRegistrationCount = [int]$maintenance.InstalledHostCount
    $result.InstalledHostCount = [int]$maintenance.UniqueInstalledHostCount
    if (-not $result.MaintenanceRunPass) { $failures += 'Installed Office registration maintenance scanner failed.' }
    if ($result.InstalledHostCount -lt $RequiredHostCount) { $failures += "Only $($result.InstalledHostCount) unique supported Office hosts were detected; required=$RequiredHostCount." }

    $rows = @()
    foreach ($mrow in @($maintenance.Results)) {
        if (-not [bool]$mrow.Installed) { continue }
        $rows += (Get-RegistrationRow ([string]$mrow.Version) ([string]$mrow.Host))
    }
    $result.RegistrationResults = $rows
    $passingHosts = @($rows | Where-Object { $_.Pass } | Select-Object -ExpandProperty Host -Unique)
    $result.RegisteredHostCount = $passingHosts.Count
    $result.AllInstalledRegistrationsPass = ($result.RegisteredHostCount -ge $RequiredHostCount -and @($rows | Where-Object { -not $_.Pass }).Count -eq 0)
    if (-not $result.AllInstalledRegistrationsPass) { $failures += 'One or more installed Office hosts do not have correct OMNIX per-user VSTO registration after maintenance.' }

    Assert-OfficeClosed
    $result.OfficeProcessesRemainedClosed = $true

    $after = Get-ResiliencyFingerprint
    $result.AfterResiliencySha256 = $after.Sha256
    $result.SharedOfficeResiliencyPreserved = ($before.Sha256 -eq $after.Sha256 -and $before.EntryCount -eq $after.EntryCount)
    if (-not $result.SharedOfficeResiliencyPreserved) { $failures += 'Shared Office Resiliency state changed during maintenance acceptance.' }
}
catch { $failures += $_.Exception.Message }

$result.FailureCount = $failures.Count
$result.Failures = $failures
$result.OverallPass = ($failures.Count -eq 0)

$dir = Split-Path -Parent $OutputPath
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 10
if (-not $result.OverallPass) { exit 1 }
exit 0
