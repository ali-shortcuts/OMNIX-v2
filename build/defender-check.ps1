# ============================================================================
# defender-check.ps1 — spec Phase 2.9: run an HONEST Windows Defender check on
# the produced installer (Defender stays ENABLED — it is never disabled for this test).
# The result is written to build/defender-report.txt and uploaded as a CI artifact.
#
# HONEST LIMITATION (Rule 9): GitHub runners are not consumer machines. A clean
# scan here does NOT guarantee zero SmartScreen/Defender warnings for end users
# (unsigned installer patterns). This report is evidence, not a promise.
# ============================================================================
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root "build\defender-report.txt"
$exe = Get-ChildItem (Join-Path $root "installer\Output") -Filter "OMNIX-Setup-*.exe" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

function Log($line) {
    $line | Tee-Object -FilePath $report -Append | Write-Host
}

if (Test-Path $report) { Remove-Item $report -Force }
Log "=== OMNIX Windows Defender check ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ==="

if (-not $exe) {
    Log "INSTALL_ERROR: no OMNIX-Setup exe found in installer/Output."
    exit 1
}
Log "Target: $($exe.FullName) ($([math]::Round($exe.Length/1MB,2)) MB)"

# 1) Is real-time protection actually ON? (must be for an honest test)
$mp = $null
try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
if ($mp) {
    Log "Defender service: installed"
    Log "RealTimeProtectionEnabled: $($mp.RealTimeProtectionEnabled)"
    Log "AntivirusEnabled: $($mp.AntivirusEnabled)"
    Log "AntivirusSignatureLastUpdated: $($mp.AntivirusSignatureLastUpdated)"
    if (-not $mp.RealTimeProtectionEnabled) {
        Log "WARNING: real-time protection is OFF on this runner — the scan ran but is NOT the consumer-realistic scenario (Rule 9 honesty note)."
    }
} else {
    Log "WARNING: Get-MpComputerStatus unavailable on this runner image. Continuing with a passive signature + threat check."
}

# 2) Explicit scan of the installer
try {
    Start-MpScan -ScanType CustomScan -ScanPath $exe.FullName
    Log "Custom scan of the installer completed without exception."
} catch {
    Log "Start-MpScan failed: $($_.Exception.Message)"
}

# 3) Did anything get quarantined / detected?
try {
    $threats = Get-MpThreatDetection -ErrorAction Stop
    if ($threats) {
        Log "THREAT DETECTIONS:"
        $threats | ForEach-Object { Log ("  " + $_.InitialDetectionTime + " " + $_.ProcessName + " " + ($_ .Resources -join ", ")) }
    } else {
        Log "No threat detections recorded for this session."
    }
} catch {
    Log "Get-MpThreatDetection failed: $($_.Exception.Message)"
}

Log "=== END OF DEFENDER REPORT (honest CI-level evidence; real-machine verification still required) ==="
