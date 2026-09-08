# ============================================================================
# post-install-verify.ps1
# OMNIX v3 rebuild: verify every Office host that the installer registered.
# This script is intentionally Office-runtime focused: a green build is not enough.
# It verifies discovery in COMAddIns and attempts a controlled Connect=true when needed.
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

function Test-OmnixRegistration([string]$hostName) {
    foreach ($version in @('16.0','15.0')) {
        $path = "HKCU:\Software\Microsoft\Office\$version\$hostName\Addins\OMNIX"
        if (Test-Path $path) { return $true }
    }
    return $false
}

function Release-ComObject($obj) {
    if ($null -ne $obj) {
        try { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch {}
    }
}

function Verify-Host([string]$hostName, [string]$progId) {
    if (-not (Test-OmnixRegistration $hostName)) {
        Log "SKIP [$hostName]: no OMNIX registry registration was written for this host."
        return $true
    }

    $app = $null
    $comAddIns = $null
    $found = $false
    $connected = $false
    $matchedProgId = ''
    $matchedDescription = ''

    try {
        Log "START [$hostName]: creating $progId COM automation object..."
        $app = New-Object -ComObject $progId
        try { $app.Visible = $false } catch {}
        try { $app.DisplayAlerts = $false } catch {}
        try { Log "INFO [$hostName]: version=$($app.Version)" } catch {}

        $comAddIns = $app.COMAddIns
        foreach ($addin in @($comAddIns)) {
            try {
                if (($addin.Description -like '*OMNIX*') -or ($addin.ProgId -like '*OMNIX*')) {
                    $found = $true
                    $matchedProgId = [string]$addin.ProgId
                    $matchedDescription = [string]$addin.Description
                    $connected = [bool]$addin.Connect
                    Log "FOUND [$hostName]: Description='$matchedDescription' ProgId='$matchedProgId' Connect=$connected"

                    if (-not $connected) {
                        Log "ACTION [$hostName]: OMNIX is registered but disconnected. Attempting Connect=true to capture the real load result."
                        try {
                            $addin.Connect = $true
                            $connected = [bool]$addin.Connect
                            Log "RESULT [$hostName]: Connect after request=$connected"
                        } catch {
                            Log "ERROR [$hostName]: Connect=true threw $($_.Exception.GetType().FullName): $($_.Exception.Message)"
                            if ($_.Exception.InnerException) {
                                Log "ERROR [$hostName]: inner=$($_.Exception.InnerException.Message)"
                            }
                        }
                    }
                }
            } finally {
                Release-ComObject $addin
            }
        }

        if (-not $found) {
            Log "FAIL [$hostName]: OMNIX registry entry exists, but OMNIX was not exposed by Application.COMAddIns."
            Log "HINT [$hostName]: inspect VSTO runtime, manifest deployment/signature, dependent DLLs, Office Disabled Items, and startup-debug.log."
            return $false
        }
        if (-not $connected) {
            Log "FAIL [$hostName]: OMNIX was found but did not reach Connect=True."
            return $false
        }

        Log "PASS [$hostName]: OMNIX discovered and connected."
        return $true
    }
    catch {
        Log "FAIL [$hostName]: verification exception $($_.Exception.GetType().FullName): $($_.Exception.Message)"
        return $false
    }
    finally {
        try { if ($null -ne $app) { $app.Quit() } } catch {}
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
    Log 'FAIL: installer verification found no OMNIX Office registrations at all.'
    exit 20
}
if ($failed.Count -gt 0) { exit 21 }
exit 0
