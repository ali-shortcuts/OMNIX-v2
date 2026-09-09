# ============================================================================
# package.ps1 — stages the complete VSTO outputs of Excel, Word and PowerPoint
# into installer/payload/ so Inno Setup can build one installer.
#
# Release-safety invariants:
#   * Packaging MUST fail if any host DLL/.vsto/.dll.manifest is missing.
#   * OMNIX.Core.dll MUST be present in the staged payload.
#   * A successful source build is not enough; a hollow installer is a failure.
#   * Only the PUBLIC OMNIX.cer may be staged. No PFX/private key may enter the
#     installer payload or CI artifact.
# ============================================================================
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $root 'installer\payload'

if (Test-Path $payload) { Remove-Item -Recurse -Force $payload }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

$hosts = @('OMNIX.Excel', 'OMNIX.Word', 'OMNIX.PowerPoint')
$allowedExtensions = @('.dll', '.vsto', '.manifest', '.config')
$copiedSources = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)

function Copy-PayloadFile([string]$sourcePath) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required packaging input is missing: $sourcePath"
    }
    $item = Get-Item -LiteralPath $sourcePath
    if ($item.Length -le 0) {
        throw "Required packaging input is empty: $sourcePath"
    }
    Copy-Item -LiteralPath $item.FullName -Destination $payload -Force
    [void]$copiedSources.Add($item.FullName)
}

foreach ($host in $hosts) {
    $bin = Join-Path $root "src\$host\bin\Release"
    if (-not (Test-Path -LiteralPath $bin -PathType Container)) {
        throw "Build output directory missing: $bin — run the Release build first."
    }

    # These three files are the minimum valid VSTO deployment identity for each host.
    $hostDll = Join-Path $bin "$host.dll"
    $appManifest = "$hostDll.manifest"
    $deployManifest = Join-Path $bin "$host.vsto"
    foreach ($required in @($hostDll, $appManifest, $deployManifest)) {
        Copy-PayloadFile $required
    }

    # Stage runtime dependencies/configuration from the same verified Release folder.
    $runtimeFiles = @(Get-ChildItem -LiteralPath $bin -File -ErrorAction Stop | Where-Object {
        $allowedExtensions -contains $_.Extension
    })
    if ($runtimeFiles.Count -eq 0) {
        throw "No runtime files were discovered in $bin even though the build reported success."
    }
    foreach ($file in $runtimeFiles) {
        Copy-PayloadFile $file.FullName
    }
}

# Validate the staged payload itself, not merely the source directories.
$requiredPayload = @(
    'OMNIX.Excel.dll',
    'OMNIX.Excel.dll.manifest',
    'OMNIX.Excel.vsto',
    'OMNIX.Word.dll',
    'OMNIX.Word.dll.manifest',
    'OMNIX.Word.vsto',
    'OMNIX.PowerPoint.dll',
    'OMNIX.PowerPoint.dll.manifest',
    'OMNIX.PowerPoint.vsto',
    'OMNIX.Core.dll'
)
foreach ($name in $requiredPayload) {
    $staged = Join-Path $payload $name
    if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) {
        throw "HOLLOW_INSTALLER_GUARD: required staged payload file is missing: $name"
    }
    if ((Get-Item -LiteralPath $staged).Length -le 0) {
        throw "HOLLOW_INSTALLER_GUARD: staged payload file is empty: $name"
    }
}

# Reject accidental private-key leakage before packaging.
$pfxFiles = @(Get-ChildItem (Join-Path $root 'build\cert') -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
if ($pfxFiles.Count -gt 0) {
    throw 'Private signing key file(s) were found under build/cert. OMNIX packaging is fail-closed: remove PFX files and keep the private key in the Windows certificate store.'
}

$cert = Join-Path $root 'build\cert\OMNIX.cer'
if (Test-Path -LiteralPath $cert -PathType Leaf) {
    Copy-Item -LiteralPath $cert -Destination $payload -Force
    Write-Host 'OMNIX.cer staged (public certificate only).'
} else {
    Write-Warning 'No OMNIX.cer found — the installer will run without the development certificate trust helper.'
}

$verifyScript = Join-Path $root 'build\post-install-verify.ps1'
if (Test-Path -LiteralPath $verifyScript -PathType Leaf) {
    Copy-Item -LiteralPath $verifyScript -Destination $payload -Force
    Write-Host 'post-install-verify.ps1 staged.'
} else {
    throw 'post-install-verify.ps1 is required for installer runtime verification.'
}

$certClassifier = Join-Path $root 'build\classify-dev-cert.ps1'
if (Test-Path -LiteralPath $certClassifier -PathType Leaf) {
    Copy-Item -LiteralPath $certClassifier -Destination $payload -Force
    Write-Host 'classify-dev-cert.ps1 staged.'
} else {
    throw 'classify-dev-cert.ps1 is required for exact development-certificate handling.'
}

# Defensive payload check: no PFX/private-key files may be embedded in setup.
$payloadPrivateKeys = @(Get-ChildItem $payload -Recurse -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
if ($payloadPrivateKeys.Count -gt 0) {
    throw 'Private key detected in installer payload. Packaging aborted.'
}

# Friendly post-install note.
$readmeFirst = Join-Path $payload 'README-first.txt'
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

$payloadFiles = @(Get-ChildItem -LiteralPath $payload -File | Sort-Object Name)
Write-Host "Staged $($copiedSources.Count) source runtime files; payload contains $($payloadFiles.Count) files."
foreach ($file in $payloadFiles) {
    Write-Host ("  {0,-55} {1,12} bytes" -f $file.Name, $file.Length)
}

# Machine-readable inventory used by CI/artifact evidence.
$inventoryDir = Join-Path $root 'build\artifact'
New-Item -ItemType Directory -Force -Path $inventoryDir | Out-Null
$inventory = foreach ($file in $payloadFiles) {
    [ordered]@{
        Name = $file.Name
        SizeBytes = [int64]$file.Length
        Sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    }
}
$inventory | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $inventoryDir 'payload-inventory.json') -Encoding UTF8

Write-Host 'OMNIX PAYLOAD GATE: PASS — all three Office hosts and OMNIX.Core are present.'
