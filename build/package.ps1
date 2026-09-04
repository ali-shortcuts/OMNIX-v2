# ============================================================================
# package.ps1 — stages the VSTO build outputs of all three hosts into
# installer/payload/ so Inno Setup can compile the single-exe installer.
# Layout (spec: ONE folder the installer copies):
#   installer/payload/OMNIX.Excel.vsto + OMNIX.Excel.dll + OMNIX.Excel.dll.manifest
#   installer/payload/OMNIX.Word.vsto   + ...
#   installer/payload/OMNIX.PowerPoint.vsto + ...
#   installer/payload/OMNIX.Core.dll, Newtonsoft.Json.dll, shared manifests
#   installer/payload/OMNIX.cer (signing cert for TrustedPublisher import)
# ============================================================================
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $root "installer\payload"

if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

$hosts = @("OMNIX.Excel", "OMNIX.Word", "OMNIX.PowerPoint")
$copied = 0

foreach ($h in $hosts) {
    $bin = Join-Path $root "src\$h\bin\Release"
    if (-not (Test-Path $bin)) {
        Write-Error "Build output missing: $bin — run the build first."
        exit 1
    }
    Get-ChildItem $bin -File | Where-Object {
        $_.Extension -in @(".dll", ".vsto", ".manifest", ".config")
    } | ForEach-Object {
        Copy-Item $_.FullName -Destination $payload -Force
        $copied++
    }
}

$cert = Join-Path $root "build\cert\OMNIX.cer"
if (Test-Path $cert) {
    Copy-Item $cert -Destination $payload -Force
    Write-Host "OMNIX.cer staged (signed install)."
} else {
    Write-Warning "No OMNIX.cer found — the installer will run WITHOUT manifest trust import (dev build)."
}

$verifyScript = Join-Path $root "build\post-install-verify.ps1"
if (Test-Path $verifyScript) {
    Copy-Item $verifyScript -Destination $payload -Force
    Write-Host "post-install-verify.ps1 staged (automatic post-install COM verification)."
}

# Friendly post-install note shown by the installer ([Run] shellexec).
$readmeFirst = Join-Path $payload "README-first.txt"
@'
OMNIX — what to do next
=======================
1) Close and reopen Excel / Word / PowerPoint.
2) You will find the OMNIX tab right after the Home tab.
3) Click "Open Workspace" - the panel opens docked to the RIGHT of your document.
4) Open Settings inside the panel, choose a provider, paste your API key
   (it is stored encrypted with Windows DPAPI) and press "Test connection".

Privacy Mode default is "Ask before sending": before any request goes to a
cloud provider, OMNIX asks you once. "Local Only" keeps data on this PC.

Logs: %LOCALAPPDATA%\OMNIX\logs\
'@ | Set-Content -Path $readmeFirst -Encoding UTF8

Write-Host "Staged $copied files into $payload"

Get-ChildItem $payload | ForEach-Object { Write-Host ("  " + $_.Name) }
