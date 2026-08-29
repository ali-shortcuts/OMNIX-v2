# ============================================================================
# create-signing-cert.ps1 — creates a temporary self-signed code-signing
# certificate for the ClickOnce/VSTO manifests (spec 2.5 / 10.2 honesty:
# this is a TEMPORARY cert; a real Authenticode cert removes SmartScreen
# warnings later — documented in README).
# Outputs: build/cert/OMNIX.cer + build/cert/OMNIX.pfx + build/cert/thumbprint.txt
# ============================================================================
$ErrorActionPreference = "Stop"

$certDir = Join-Path $PSScriptRoot "cert"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null

$existing = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Where-Object { $_.Subject -like "CN=OMNIX*" } |
    Sort-Object NotAfter -Descending | Select-Object -First 1

if ($existing) {
    $cert = $existing
    Write-Host "Reusing existing OMNIX code-signing cert: $($cert.Thumbprint)"
}
else {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert `
        -Subject "CN=OMNIX, O=Mr Ali" `
        -KeyUsage DigitalSignature -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(5) `
        -CertStoreLocation Cert:\CurrentUser\My
    Write-Host "Created new self-signed code-signing cert: $($cert.Thumbprint)"
}

$cerPath = Join-Path $certDir "OMNIX.cer"
$pfxPath = Join-Path $certDir "OMNIX.pfx"

Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
$plainPassword = "omnix-dev-only"
$secPassword = ConvertTo-SecureString -String $plainPassword -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $secPassword | Out-Null

Set-Content -Path (Join-Path $certDir "thumbprint.txt") -Value $cert.Thumbprint
Write-Host "Cert files written:"
Write-Host "  $cerPath"
Write-Host "  $pfxPath (dev password: $plainPassword)"
Write-Host "Thumbprint: $($cert.Thumbprint)"
