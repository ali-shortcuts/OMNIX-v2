# ============================================================================
# post-install-verify.ps1
# OMNIX v3: verify every Office host registered at the Microsoft-documented
# VSTO path: HKCU\Software\Microsoft\Office\<Host>\Addins\OMNIX
# ============================================================================

$ErrorActionPreference = 'Stop'
$logDir = Join-Path $env:LOCALAPPDATA 'OMNIX\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'post-install-verify.log'

function Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $log -Value $line
    Write-Host $line
}

function Get-OmnixRegistrationPath([string]$hostName) {
    "HKCU:\Software\Microsoft\Office\$hostName\Addins\OMNIX"
}

function Test-OmnixRegistration([string]$hostName) {
    Test-Path -LiteralPath (Get-OmnixRegistrationPath $hostName)
}

function Release-ComObject($obj) {
    if ($null -ne $obj) {
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch {}
    }
}

function Get-ComAddIns($app) {
    $collection = $app.COMAddIns
    $items = @()
    try {
        $count = [int]$collection.Count
        for ($i = 1; $i -le $count; $i++) {
            try { $items += $collection.Item($i) } catch {}
        }
    } catch {}
    [pscustomobject]@{ Collection=$collection; Items=$items }
}

function Verify-Host([string]$hostName, [string]$progId) {
    if (-not (Test-OmnixRegistration $hostName)) {
        Log "SKIP [$hostName]: no canonical OMNIX VSTO registry registration exists."
        return $true
    }

    $app = $null
    $comAddIns = $null
    $addinItems = @()
    $found = $false
    $connected = $false

    try {
        Log "START [$hostName]: creating $progId COM automation object..."
        $app = New-Object -ComObject $progId
        try { $app.Visible = $false } catch {}
        try { $app.DisplayAlerts = $false } catch {}
        try { Log "INFO [$hostName]: version=$($app.Version)" } catch {}

        $wrapped = Get-ComAddIns $app
        $comAddIns = $wrapped.Collection
        $addinItems = @($wrapped.Items)

        foreach ($addin in $addinItems) {
            try {
                $description = [string]$addin.Description
                $addinProgId = [string]$addin.ProgId
                if (($description -like '*OMNIX*') -or ($addinProgId -like '*OMNIX*')) {
                    $found = $true
                    $connected = [bool]$addin.Connect
                    Log "FOUND [$hostName]: Description='$description' ProgId='$addinProgId' Connect=$connected"

                    if (-not $connected) {
                        Log "DIAGNOSTIC [$hostName]: automatic load failed; attempting Connect=true only to capture the actual VSTO load result. This does NOT convert the automatic-load failure into PASS."
                        try {
                            $addin.Connect = $true
                            Log "DIAGNOSTIC [$hostName]: Connect after manual diagnostic request=$([bool]$addin.Connect)"
                        } catch {
                            Log "ERROR [$hostName]: Connect=true threw $($_.Exception.GetType().FullName): $($_.Exception.Message)"
                            if ($_.Exception.InnerException) { Log "ERROR [$hostName]: inner=$($_.Exception.InnerException.Message)" }
                        }
                    }
                    break
                }
            } catch {
                Log "WARN [$hostName]: COMAddIns item inspection failed: $($_.Exception.Message)"
            }
        }

        if (-not $found) {
            Log "FAIL [$hostName]: canonical registry entry exists but Application.COMAddIns does not expose OMNIX."
            Log "HINT [$hostName]: inspect VSTO runtime, deployment/application manifest trust, dependent DLLs, Office Disabled Items, and startup-debug.log."
            return $false
        }
        if (-not $connected) {
            Log "FAIL [$hostName]: OMNIX was found but was NOT automatically Connect=True at Office startup."
            return $false
        }

        Log "PASS [$hostName]: OMNIX discovered and automatically connected."
        return $true
    }
    catch {
        Log "FAIL [$hostName]: verification exception $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        return $false
    }
    finally {
        try { if ($null -ne $app) { $app.Quit() } } catch {}
        foreach ($addin in $addinItems) { Release-ComObject $addin }
        Release-ComObject $comAddIns
        Release-ComObject $app
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

Log '=== OMNIX post-install verification starting ==='

$results = @()
$results += [pscustomobject]@{ Host='Excel';      Passed=(Verify-Host 'Excel'      'Excel.Application') }
$results += [pscustomobject]@{ Host='Word';       Passed=(Verify-Host 'Word'       'Word.Application') }
$results += [pscustomobject]@{ Host='PowerPoint'; Passed=(Verify-Host 'PowerPoint' 'PowerPoint.Application') }

$registeredHosts = @($results | Where-Object { Test-OmnixRegistration $_.Host })
$failed = @($registeredHosts | Where-Object { -not $_.Passed })

Log "SUMMARY: registered_hosts=$($registeredHosts.Count) failed=$($failed.Count)"
foreach ($r in $registeredHosts) {
    Log ("SUMMARY [{0}]: {1}" -f $r.Host, $(if ($r.Passed) {'PASS'} else {'FAIL'}))
}
Log '=== OMNIX post-install verification finished ==='

if ($registeredHosts.Count -eq 0) {
    Log 'FAIL: canonical OMNIX Office registration was not found for any host.'
    exit 20
}
if ($failed.Count -gt 0) { exit 21 }
exit 0
