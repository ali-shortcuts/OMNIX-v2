# Classifies the manifest-signing public certificate bundled with a development build.
# Exit 0: self-signed development certificate; thumbprint written to OutputPath.
# Exit 2: CA/non-self-signed certificate; installer must NOT modify trust stores.
# Exit 1: invalid/unreadable certificate.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CertPath,
    [Parameter(Mandatory=$true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $CertPath)) { throw "Certificate not found." }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)

    $isSelfSigned = [string]::Equals(
        $cert.Subject,
        $cert.Issuer,
        [StringComparison]::OrdinalIgnoreCase)

    if (-not $isSelfSigned) {
        # A production/CA-signed publisher certificate relies on the normal Windows trust chain.
        # The OMNIX installer must never add it to Root/TrustedPublisher itself.
        exit 2
    }

    $dir = Split-Path -Parent $OutputPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-Content -LiteralPath $OutputPath -Value $cert.Thumbprint -Encoding ASCII
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
