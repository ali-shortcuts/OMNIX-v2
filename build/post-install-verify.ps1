# ============================================================================
# post-install-verify.ps1
#
# Runs AUTOMATICALLY at the end of Setup (CurStepChanged/ssPostInstall) —
# the user does nothing. Uses real COM automation to launch Excel invisibly,
# check whether OMNIX actually appears in Application.COMAddIns, and if it
# does but isn't connected, tries to connect it and captures the EXACT
# exception if that fails. This is the automated equivalent of manually
# checking File > Options > Add-ins > COM Add-ins — done by the installer
# itself, logged, no user steps required.
# ============================================================================

$logDir = "$env:LOCALAPPDATA\OMNIX\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "post-install-verify.log"

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg"
    Add-Content -Path $log -Value $line
    Write-Host $line
}

Log "=== OMNIX post-install verification starting ==="

$excel = $null
try {
    Log "Launching Excel via COM automation (invisible, no document)..."
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    Log "Excel COM object created OK. Version: $($excel.Version)"

    $found = $false
    $connected = $false
    $addinDescription = ""
    foreach ($addin in $excel.COMAddIns) {
        if ($addin.Description -like "*OMNIX*" -or $addin.ProgId -like "*OMNIX*") {
            $found = $true
            $connected = $addin.Connect
            $addinDescription = $addin.Description
            Log "FOUND in COMAddIns: Description='$($addin.Description)' ProgId='$($addin.ProgId)' Connect=$($addin.Connect)"
        }
    }

    if (-not $found) {
        Log "RESULT: OMNIX was NOT found in Excel.COMAddIns at all."
        Log "This means Excel did not even attempt to register the add-in from the registry entry OMNIX wrote."
        Log "Most likely causes: (a) VSTO Runtime still not functional despite the install attempt, (b) a dependent DLL (e.g. Newtonsoft.Json.dll) failed to load, (c) the manifest signature is rejected by Office Trust Center."
    } elseif (-not $connected) {
        Log "RESULT: OMNIX IS in Excel.COMAddIns (Description='$addinDescription') but Connect=False (not loaded)."
        Log "Attempting to force-connect it now to capture the EXACT error..."
        try {
            foreach ($addin in $excel.COMAddIns) {
                if ($addin.Description -like "*OMNIX*") {
                    $addin.Connect = $true
                    Log "Force-connect succeeded with no exception. New Connect state: $($addin.Connect)"
                }
            }
        } catch {
            Log "FORCE-CONNECT THREW AN EXCEPTION (this is likely the real root cause): $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            if ($_.Exception.InnerException) {
                Log "Inner exception: $($_.Exception.InnerException.Message)"
            }
        }
    } else {
        Log "RESULT: OMNIX IS in Excel.COMAddIns AND Connect=True — the add-in loaded successfully."
    }
} catch {
    Log "EXCEPTION during verification itself: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
} finally {
    if ($excel -ne $null) {
        try { $excel.Quit() } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch {}
    }
    Log "=== OMNIX post-install verification finished ==="
}
