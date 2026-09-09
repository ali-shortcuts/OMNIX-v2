# OMNIX production Authenticode signing helper
#
# This script never creates, exports, downloads or stores a private key. It signs only with an
# existing code-signing certificate already available to the current Windows user/machine through
# the normal certificate/key provider. The caller must provision that certificate securely outside
# the repository. Never commit a PFX/password or paste a private key into chat/CI logs.
#
# A successful invocation still does NOT approve release; tools/final-production-gate.ps1 must pass.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InstallerPath,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^[0-9A-Fa-f]{40,64}$')]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory=$true)]
    [ValidatePattern('^https://')]
    [string]$TimestampUrl,

    [string]$OutputPath = ".\release-evidence\production-signing.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small: $($installer.Length) bytes" }

$thumb = $CertificateThumbprint.Replace(' ','').ToUpperInvariant()
$cert = $null
foreach ($store in @('Cert:\CurrentUser\My','Cert:\LocalMachine\My')) {
    $candidate = Join-Path $store $thumb
    if (Test-Path -LiteralPath $candidate) {
        $cert = Get-Item -LiteralPath $candidate
        break
    }
}
if ($null -eq $cert) { throw "Signing certificate $thumb was not found in CurrentUser/My or LocalMachine/My." }
if (-not $cert.HasPrivateKey) { throw 'Selected certificate has no accessible private key.' }
if ([string]::Equals($cert.Subject, $cert.Issuer, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Self-signed certificates are not accepted by the OMNIX production signing helper.'
}
if ($cert.NotAfter -le (Get-Date)) { throw 'Signing certificate is expired.' }
if ($cert.NotBefore -gt (Get-Date)) { throw 'Signing certificate is not yet valid.' }

$codeSigningEku = $false
foreach ($eku in @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.37' })) {
    try {
        foreach ($oid in $eku.EnhancedKeyUsages) {
            if ($oid.Value -eq '1.3.6.1.5.5.7.3.3') { $codeSigningEku = $true }
        }
    } catch { }
}
if (-not $codeSigningEku) { throw 'Selected certificate does not advertise the Code Signing EKU (1.3.6.1.5.5.7.3.3).' }

$signtool = $null
$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
if (Test-Path $kitsRoot) {
    $candidates = @(Get-ChildItem -Path $kitsRoot -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending)
    if ($candidates.Count -gt 0) { $signtool = $candidates[0].FullName }
}
if ([string]::IsNullOrWhiteSpace($signtool)) {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { $signtool = $cmd.Source }
}
if ([string]::IsNullOrWhiteSpace($signtool)) { throw 'signtool.exe was not found. Install the Windows SDK signing tools.' }

$beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()

# /sha1 chooses the provisioned certificate; no private-key file/password appears on the command line.
# RFC3161 SHA-256 timestamping keeps the signature verifiable after the leaf certificate expires.
$signOutput = & $signtool sign /sha1 $thumb /fd SHA256 /tr $TimestampUrl /td SHA256 /v $installer.FullName 2>&1
$signExit = $LASTEXITCODE
if ($signExit -ne 0) {
    $safe = ($signOutput | Select-Object -Last 30) -join [Environment]::NewLine
    throw "signtool sign failed (exit=$signExit).`n$safe"
}

$verifyOutput = & $signtool verify /pa /all /v $installer.FullName 2>&1
$verifyExit = $LASTEXITCODE
if ($verifyExit -ne 0) {
    $safe = ($verifyOutput | Select-Object -Last 30) -join [Environment]::NewLine
    throw "signtool verify failed (exit=$verifyExit).`n$safe"
}

$signature = Get-AuthenticodeSignature -FilePath $installer.FullName
if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "PowerShell Authenticode verification is not Valid (status=$($signature.Status))."
}
if ($null -eq $signature.SignerCertificate) { throw 'No signer certificate is visible after signing.' }
if ([string]$signature.SignerCertificate.Thumbprint -ne $thumb) {
    throw 'The resulting signer thumbprint does not match the requested production certificate.'
}
if ($null -eq $signature.TimeStamperCertificate) { throw 'The resulting signature has no timestamp certificate.' }

$afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()
if ($beforeHash -eq $afterHash) { throw 'Installer hash did not change after Authenticode signing; signing result is suspicious.' }

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$report = [ordered]@{
    TestId = 'PRODUCTION-AUTHENTICODE-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    InstallerFileName = $installer.Name
    SizeBytes = [int64]$installer.Length
    Sha256BeforeSigning = $beforeHash
    Sha256AfterSigning = $afterHash
    SignatureStatus = [string]$signature.Status
    SignerSubject = [string]$signature.SignerCertificate.Subject
    SignerIssuer = [string]$signature.SignerCertificate.Issuer
    SignerThumbprint = [string]$signature.SignerCertificate.Thumbprint
    SelfSigned = [string]::Equals($signature.SignerCertificate.Subject, $signature.SignerCertificate.Issuer, [StringComparison]::OrdinalIgnoreCase)
    Timestamped = ($null -ne $signature.TimeStamperCertificate)
    TimestampUrl = $TimestampUrl
    PrivateKeyExportedByScript = $false
    OverallPass = $true
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 6
exit 0
