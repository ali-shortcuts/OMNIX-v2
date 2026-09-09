# OMNIX Office registration maintenance
#
# IMPORTANT: VSTO application-level add-ins are discovered under:
#   HKCU\Software\Microsoft\Office\<Application>\Addins\<AddinId>
# They are NOT registered under Office\16.0\... or Office\15.0\...
# See Microsoft VSTO deployment documentation.
#
# This script is user-authorized and per-user. It scans only Excel/Word/PowerPoint
# installation evidence and repairs ONLY OMNIX-owned HKCU registration. It never
# clears Office Resiliency/DisabledItems, changes Trust Center, launches Office,
# elevates, reads documents, or touches provider credentials.

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\office-registration-maintenance.json",
    [switch]$AuditOnly,
    [switch]$Remove,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SupportedVersions = @('16.0','15.0')
$Hosts = @(
    [pscustomobject]@{ Name='Excel'; Exe='EXCEL.EXE' },
    [pscustomobject]@{ Name='Word'; Exe='WINWORD.EXE' },
    [pscustomobject]@{ Name='PowerPoint'; Exe='POWERPNT.EXE' }
)

function Open-Hklm([Microsoft.Win32.RegistryView]$View) {
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
}

function Get-HklmString([string]$SubKey, [string]$ValueName) {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null; $key = $null
        try {
            $base = Open-Hklm $view
            $key = $base.OpenSubKey($SubKey, $false)
            if ($null -ne $key) {
                $value = [string]$key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim('"') }
            }
        } catch { }
        finally {
            if ($null -ne $key) { $key.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
    $null
}

function Get-HkcuString([string]$SubKey, [string]$ValueName) {
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return $null }
        $value = [string]$key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        $value.Trim('"')
    } catch { $null }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-KnownOfficeExePaths([string]$Version, [string]$Exe) {
    $folder = if ($Version -eq '16.0') { 'Office16' } else { 'Office15' }
    $paths = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $paths += (Join-Path $root ("Microsoft Office\root\$folder\$Exe"))
        $paths += (Join-Path $root ("Microsoft Office\$folder\$Exe"))
    }
    $paths
}

function Get-InstallRootExe([string]$Version, $OfficeHost) {
    $sub = "SOFTWARE\Microsoft\Office\$Version\$($OfficeHost.Name)\InstallRoot"
    $root = Get-HklmString $sub 'Path'
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-HkcuString ("Software\Microsoft\Office\$Version\$($OfficeHost.Name)\InstallRoot") 'Path'
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    Join-Path ([Environment]::ExpandEnvironmentVariables($root)) $OfficeHost.Exe
}

function Test-OfficeHostInstalledForVersion([string]$Version, $OfficeHost) {
    $installRootExe = Get-InstallRootExe $Version $OfficeHost
    if (-not [string]::IsNullOrWhiteSpace($installRootExe) -and (Test-Path -LiteralPath $installRootExe -PathType Leaf)) { return $true }

    foreach ($candidate in Get-KnownOfficeExePaths $Version $OfficeHost.Exe) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $true }
    }

    $appPath = Get-HklmString ("SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($OfficeHost.Exe)") ''
    if (-not [string]::IsNullOrWhiteSpace($appPath) -and (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        $client = Get-HklmString 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'ClientVersionToReport'
        if ($Version -eq '16.0' -and $client -match '^16\.') { return $true }
        if ($Version -eq '15.0' -and $client -match '^15\.') { return $true }
    }
    $false
}

function Test-OfficeHostInstalled($OfficeHost) {
    foreach ($version in $SupportedVersions) {
        if (Test-OfficeHostInstalledForVersion $version $OfficeHost) { return $true }
    }
    $false
}

function Get-ManifestUri([string]$HostName) {
    $path = Join-Path $InstallDir ("OMNIX.$HostName.vsto")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required VSTO deployment manifest is missing: OMNIX.$HostName.vsto"
    }
    $uri = New-Object System.Uri -ArgumentList $path
    ($uri.AbsoluteUri + '|vstolocal')
}

function Get-CanonicalRegistrationPath([string]$HostName) {
    "HKCU:\Software\Microsoft\Office\$HostName\Addins\OMNIX"
}

function Get-LegacyRegistrationPaths([string]$HostName) {
    @(
        "HKCU:\Software\Microsoft\Office\16.0\$HostName\Addins\OMNIX",
        "HKCU:\Software\Microsoft\Office\15.0\$HostName\Addins\OMNIX"
    )
}

function Remove-LegacyRegistration([string]$HostName) {
    foreach ($legacy in Get-LegacyRegistrationPaths $HostName) {
        if (Test-Path -LiteralPath $legacy) {
            Remove-Item -LiteralPath $legacy -Recurse -Force
        }
    }
}

function Get-RegistrationState([string]$HostName, [string]$ExpectedManifest) {
    $path = Get-CanonicalRegistrationPath $HostName
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Exists=$false; Correct=$false; LoadBehavior=$null; Manifest=$null; Path=$path }
    }
    $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    $load = if ($null -ne $item) { $item.LoadBehavior } else { $null }
    $manifest = if ($null -ne $item) { [string]$item.Manifest } else { $null }
    $correct = ($load -eq 3 -and [string]::Equals($manifest, $ExpectedManifest, [StringComparison]::OrdinalIgnoreCase))
    [pscustomobject]@{ Exists=$true; Correct=$correct; LoadBehavior=$load; Manifest=$manifest; Path=$path }
}

function Ensure-Registration([string]$HostName, [string]$Manifest) {
    $path = Get-CanonicalRegistrationPath $HostName
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Description' -Value 'OMNIX AI Office' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'FriendlyName' -Value 'OMNIX' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'LoadBehavior' -Value 3 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Manifest' -Value $Manifest -PropertyType String -Force | Out-Null
}

function Remove-OmnixRegistration([string]$HostName) {
    $canonical = Get-CanonicalRegistrationPath $HostName
    if (Test-Path -LiteralPath $canonical) { Remove-Item -LiteralPath $canonical -Recurse -Force }
    Remove-LegacyRegistration $HostName
}

$report = [ordered]@{
    TestId = 'OFFICE-REGISTRATION-MAINTENANCE-002'
    EvidenceSchema = 3
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    AuditOnly = [bool]$AuditOnly
    Remove = [bool]$Remove
    RegistrationPathModel = 'HKCU\Software\Microsoft\Office\<Host>\Addins\OMNIX'
    InstalledHostCount = 0
    CorrectBeforeCount = 0
    RepairedCount = 0
    CorrectAfterCount = 0
    RemovedCount = 0
    Failures = @()
    Results = @()
    Safety = 'Executable-backed detection; versionless Microsoft-documented VSTO Addins path; per-user OMNIX-owned keys only; no Office Resiliency/Trust Center/document/network/provider-secret changes.'
    OverallPass = $false
}

$failures = @()
$rows = @()

try {
    if (-not $Remove -and -not (Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)) {
        throw 'OMNIX.Core.dll is missing from the configured installation directory.'
    }

    foreach ($officeHost in $Hosts) {
        if ($Remove) {
            try {
                Remove-OmnixRegistration $officeHost.Name
                $report.RemovedCount++
                $rows += [pscustomobject]@{ Host=$officeHost.Name; Installed=$null; CorrectBefore=$null; Changed=$true; CorrectAfter=$null; Pass=$true }
            } catch {
                $failures += "$($officeHost.Name): removal failed: $($_.Exception.Message)"
            }
            continue
        }

        $installed = Test-OfficeHostInstalled $officeHost
        if (-not $installed) { continue }
        $report.InstalledHostCount++

        try {
            $manifest = Get-ManifestUri $officeHost.Name
            $before = Get-RegistrationState $officeHost.Name $manifest
            if ($before.Correct) { $report.CorrectBeforeCount++ }
            $changed = $false

            if (-not $AuditOnly) {
                Remove-LegacyRegistration $officeHost.Name
                if (-not $before.Correct) {
                    Ensure-Registration $officeHost.Name $manifest
                    $changed = $true
                    $report.RepairedCount++
                }
            }

            $after = Get-RegistrationState $officeHost.Name $manifest
            $pass = if ($AuditOnly) { [bool]$before.Correct } else { [bool]$after.Correct }
            if ($after.Correct) { $report.CorrectAfterCount++ }
            if (-not $pass) { $failures += "$($officeHost.Name) OMNIX registration is not correct at $($after.Path)." }

            $rows += [pscustomobject]@{
                Host=$officeHost.Name
                Installed=$true
                RegistrationPath=$after.Path
                CorrectBefore=[bool]$before.Correct
                Changed=[bool]$changed
                CorrectAfter=[bool]$after.Correct
                Pass=[bool]$pass
            }
        }
        catch {
            $failures += "$($officeHost.Name): $($_.Exception.Message)"
            $rows += [pscustomobject]@{ Host=$officeHost.Name; Installed=$true; CorrectBefore=$false; Changed=$false; CorrectAfter=$false; Pass=$false }
        }
    }
}
catch {
    $failures += $_.Exception.Message
}

$report.Results = $rows
$report.Failures = $failures
$report.OverallPass = ($failures.Count -eq 0)

try {
    $dir = Split-Path -Parent $OutputPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} catch { }

if (-not $Quiet) { $report | ConvertTo-Json -Depth 8 }
if (-not $report.OverallPass) { exit 1 }
exit 0
