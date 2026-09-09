# ============================================================================
# create-signing-cert.ps1 — creates/reuses a temporary self-signed code-signing
# certificate for DEVELOPMENT/CI VSTO manifest signing only.
#
# Security rule: the private key stays in the CurrentUser certificate store.
# We export only the public .cer needed by the development installer trust flow.
# No PFX/private-key file and no hard-coded private-key password are written to disk.
#
# Production release remains separately gated: a self-signed certificate is NOT a
# production trust claim and tools/release-readiness.ps1 rejects it by default.
# ============================================================================

$ErrorActionPreference = "Stop"

$certDir = Join-Path $PSScriptRoot "cert"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

# Remove obsolete private-key exports from earlier build logic if they exist locally.
Remove-Item (Join-Path $certDir "OMNIX.pfx") -Force -ErrorAction SilentlyContinue

$existing = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -eq "CN=OMNIX, O=Mr Ali" -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if ($existing) {
    $cert = $existing
    Write-Host "Reusing existing OMNIX development code-signing certificate: $($cert.Thumbprint)"
}
else {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject "CN=OMNIX, O=Mr Ali" `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable `
        -HashAlgorithm SHA256 `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(2) `
        -CertStoreLocation Cert:\CurrentUser\My
    Write-Host "Created new non-exportable OMNIX development code-signing certificate: $($cert.Thumbprint)"
}

if (-not $cert.HasPrivateKey) {
    throw "OMNIX development signing certificate does not have a private key."
}

$cerPath = Join-Path $certDir "OMNIX.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
Set-Content -Path (Join-Path $certDir "thumbprint.txt") -Value $cert.Thumbprint

Write-Host "Development signing public certificate written: $cerPath"
Write-Host "Private key remains non-exportable in Cert:\CurrentUser\My"
Write-Host "Thumbprint: $($cert.Thumbprint)"
