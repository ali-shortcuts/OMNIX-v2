# OMNIX real Office acceptance gate
#
# Purpose:
#   Validate the installed OMNIX VSTO add-in against REAL locally installed
#   Excel, Word and PowerPoint. This is intentionally separate from CI because
#   GitHub-hosted Windows runners do not include desktop Microsoft Office.
#
# What it proves for EACH of the three required Office hosts:
#   1. Office COM application can start.
#   2. OMNIX registration exists with LoadBehavior=3 and its VSTO manifest target exists.
#   3. OMNIX appears in Application.COMAddIns.
#   4. OMNIX is ALREADY Connect=True after normal Office startup.
#   5. Office is closed cleanly.
#   6. Office is launched a second time and OMNIX is again automatically connected.
#
# A force-connect attempt is retained only as diagnostic evidence. It can show that the add-in is
# manually connectable, but it NEVER converts an automatic-load/persistence failure into PASS.
#
# It does NOT modify documents, bypass Office security, clear Resiliency data,
# or change Trust Center policy.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\real-office-acceptance.json",
    [int]$StartupDelayMs = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hosts = @(
    [pscustomobject]@{ Name='Excel';      ProgId='Excel.Application';      Process='EXCEL';    RegistryHost='Excel' },
    [pscustomobject]@{ Name='Word';       ProgId='Word.Application';       Process='WINWORD';  RegistryHost='Word' },
    [pscustomobject]@{ Name='PowerPoint'; ProgId='PowerPoint.Application'; Process='POWERPNT'; RegistryHost='PowerPoint' }
)

$logDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Get-OfficePlatform {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    foreach ($p in $paths) {
        try {
            $v = (Get-ItemProperty -Path $p -Name Platform -ErrorAction Stop).Platform
            if ($v) { return $v }
        } catch { }
    }
    return 'unknown'
}

function Resolve-ManifestTarget([string]$manifestValue) {
    $result = [ordered]@{
        Raw = $manifestValue
        Target = $null
        Exists = $false
        Error = $null
    }

    if ([string]::IsNullOrWhiteSpace($manifestValue)) {
        $result.Error = 'Manifest registry value is empty.'
        return [pscustomobject]$result
    }

    try {
        $value = $manifestValue.Trim()
        if ($value.EndsWith('|vstolocal', [StringComparison]::OrdinalIgnoreCase)) {
            $value = $value.Substring(0, $value.Length - '|vstolocal'.Length)
        }

        if ($value -match '^file:') {
            $uri = New-Object System.Uri($value)
            if (-not $uri.IsFile) { throw 'Manifest URI is not a local file URI.' }
            $value = $uri.LocalPath
        }

        $value = [Environment]::ExpandEnvironmentVariables($value.Trim('"'))
        $result.Target = $value
        $result.Exists = [bool](Test-Path -LiteralPath $value -PathType Leaf)
        if (-not $result.Exists) {
            $result.Error = 'Registered VSTO manifest target does not exist.'
        }
    }
    catch {
        $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }

    return [pscustomobject]$result
}

function Get-OmnixRegistryState([string]$hostName, [string]$officeVersion) {
    $major = ($officeVersion -split '\.')[0]
    $candidates = @()
    if ($major) { $candidates += "$major.0" }
    $candidates += @('16.0','15.0')
    $candidates = $candidates | Select-Object -Unique

    foreach ($v in $candidates) {
        $path = "HKCU:\Software\Microsoft\Office\$v\$hostName\Addins\OMNIX"
        if (Test-Path $path) {
            $p = Get-ItemProperty -Path $path
            $manifest = Resolve-ManifestTarget ([string]$p.Manifest)
            return [pscustomobject]@{
                Found = $true
                RegistryPath = $path
                VersionKey = $v
                LoadBehavior = $p.LoadBehavior
                Manifest = $manifest
            }
        }
    }
    return [pscustomobject]@{
        Found=$false
        RegistryPath=$null
        VersionKey=$null
        LoadBehavior=$null
        Manifest=(Resolve-ManifestTarget $null)
    }
}

function Release-ComObjectSafe($obj) {
    if ($null -ne $obj) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { }
    }
}

function Test-HostRound($host, [int]$round) {
    $app = $null
    $matched = $null
    $started = Get-Date
    $result = [ordered]@{
        Host = $host.Name
        Round = $round
        Installed = $true
        Started = $false
        Version = $null
        Registry = $null
        AddinFound = $false
        AddinProgId = $null
        AddinDescription = $null
        InitialConnect = $false
        AutomaticLoadPass = $false
        ForceConnectAttempted = $false
        ForceConnectSucceeded = $false
        FinalConnect = $false
        Error = $null
        DurationMs = 0
        Pass = $false
    }

    try {
        $app = New-Object -ComObject $host.ProgId
        $result.Started = $true
        Start-Sleep -Milliseconds $StartupDelayMs

        try { $app.Visible = $false } catch { }
        try { $app.DisplayAlerts = $false } catch { }
        try { $result.Version = [string]$app.Version } catch { $result.Version = 'unknown' }
        $result.Registry = Get-OmnixRegistryState $host.RegistryHost $result.Version

        foreach ($addin in @($app.COMAddIns)) {
            try {
                $desc = [string]$addin.Description
                $prog = [string]$addin.ProgId
                if ($desc -like '*OMNIX*' -or $prog -like '*OMNIX*') {
                    $matched = $addin
                    $result.AddinFound = $true
                    $result.AddinProgId = $prog
                    $result.AddinDescription = $desc
                    $result.InitialConnect = [bool]$addin.Connect
                    $result.AutomaticLoadPass = $result.InitialConnect
                    break
                }
            } catch { }
        }

        # Diagnostic only. Never use the forced state for Pass.
        if ($result.AddinFound -and -not $result.InitialConnect) {
            $result.ForceConnectAttempted = $true
            try {
                $matched.Connect = $true
                Start-Sleep -Milliseconds 700
                $result.ForceConnectSucceeded = [bool]$matched.Connect
            } catch {
                $result.Error = "Force-connect diagnostic failed: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            }
        }

        if ($result.AddinFound) {
            try { $result.FinalConnect = [bool]$matched.Connect } catch { $result.FinalConnect = $false }
        }

        $registrationPass = [bool](
            $null -ne $result.Registry -and
            $result.Registry.Found -and
            ($result.Registry.LoadBehavior -eq 3) -and
            $null -ne $result.Registry.Manifest -and
            $result.Registry.Manifest.Exists)

        $result.Pass = [bool](
            $result.Started -and
            $result.AddinFound -and
            $result.AutomaticLoadPass -and
            $registrationPass)
    }
    catch [System.Runtime.InteropServices.COMException] {
        # 0x80040154 = class not registered -> Office host not installed / not available.
        if ($_.Exception.HResult -eq -2147221164) {
            $result.Installed = $false
            $result.Error = 'Office COM class is not registered; this required host appears not installed.'
        } else {
            $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
        }
    }
    catch {
        $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $app) {
            try { $app.Quit() } catch { }
        }
        Release-ComObjectSafe $matched
        Release-ComObjectSafe $app
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $result.DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
    }

    return [pscustomobject]$result
}

# Do not interfere with a user's currently open Office session.
$running = @()
foreach ($h in $hosts) {
    if (Get-Process -Name $h.Process -ErrorAction SilentlyContinue) { $running += $h.Name }
}
if ($running.Count -gt 0) {
    throw "Close Office before running this acceptance gate. Currently running: $($running -join ', ')"
}

$all = New-Object System.Collections.Generic.List[object]
foreach ($host in $hosts) {
    $r1 = Test-HostRound $host 1
    $all.Add($r1)
    Start-Sleep -Milliseconds 900

    if ($r1.Installed) {
        $r2 = Test-HostRound $host 2
        $all.Add($r2)
        Start-Sleep -Milliseconds 900
    }
}

$installedHostNames = @($all | Where-Object { $_.Installed } | Select-Object -ExpandProperty Host -Unique)
$installedRows = @($all | Where-Object { $_.Installed })
$requiredHostCountPass = ($installedHostNames.Count -eq $hosts.Count)
$twoRoundsPerHostPass = $requiredHostCountPass
foreach ($host in $hosts) {
    if (@($installedRows | Where-Object { $_.Host -eq $host.Name }).Count -ne 2) {
        $twoRoundsPerHostPass = $false
    }
}
$automaticLoadEveryRoundPass = (@($installedRows | Where-Object { -not $_.AutomaticLoadPass }).Count -eq 0)
$allRowsPass = (@($installedRows | Where-Object { -not $_.Pass }).Count -eq 0)
$overallPass = [bool](
    $requiredHostCountPass -and
    $twoRoundsPerHostPass -and
    $automaticLoadEveryRoundPass -and
    $allRowsPass)

$report = [ordered]@{
    TestId = 'OFFICE-PERSISTENCE-REAL-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Machine = $env:COMPUTERNAME
    Windows = [Environment]::OSVersion.VersionString
    OfficePlatform = Get-OfficePlatform
    RequiredHosts = @($hosts | Select-Object -ExpandProperty Name)
    InstalledHosts = $installedHostNames
    RequiredHostCountPass = $requiredHostCountPass
    TwoRoundsPerHostPass = $twoRoundsPerHostPass
    AutomaticLoadEveryRoundPass = $automaticLoadEveryRoundPass
    OverallPass = $overallPass
    Results = $all
}

$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10

if (-not $overallPass) { exit 1 }
exit 0
