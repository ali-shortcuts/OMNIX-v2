# ============================================================================
# package.ps1 — stages the VSTO build outputs of all three hosts into
# installer/payload/ so Inno Setup can compile the single-exe installer.
#
# Security rule: only the PUBLIC OMNIX.cer may be staged. A private signing key
# (PFX) must never enter installer/payload or the release artifact.
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

# Reject accidental private-key leakage before packaging.
$pfxFiles = @(Get-ChildItem (Join-Path $root "build\cert") -Filter "*.pfx" -File -ErrorAction SilentlyContinue)
if ($pfxFiles.Count -gt 0) {
    throw "Private signing key file(s) were found under build/cert. OMNIX packaging is fail-closed: remove PFX files and keep the private key in the Windows certificate store."
}

$cert = Join-Path $root "build\cert\OMNIX.cer"
if (Test-Path $cert) {
    Copy-Item $cert -Destination $payload -Force
    Write-Host "OMNIX.cer staged (public certificate only)."
} else {
    Write-Warning "No OMNIX.cer found — the installer will run without the development certificate trust helper."
}

$verifyScript = Join-Path $root "build\post-install-verify.ps1"
if (Test-Path $verifyScript) {
    Copy-Item $verifyScript -Destination $payload -Force
    Write-Host "post-install-verify.ps1 staged (automatic post-install COM verification)."
}

$certClassifier = Join-Path $root "build\classify-dev-cert.ps1"
if (Test-Path $certClassifier) {
    Copy-Item $certClassifier -Destination $payload -Force
    Write-Host "classify-dev-cert.ps1 staged (self-signed dev-cert detection; production certs are never root-imported)."
}

# Defensive payload check: no PFX/private-key files may be embedded in setup.
$payloadPrivateKeys = @(Get-ChildItem $payload -Recurse -Filter "*.pfx" -File -ErrorAction SilentlyContinue)
if ($payloadPrivateKeys.Count -gt 0) {
    throw "Private key detected in installer payload. Packaging aborted."
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

Write-Host "Staged $copied Office/VSTO files into $payload"
Get-ChildItem $payload | ForEach-Object { Write-Host ("  " + $_.Name) }
