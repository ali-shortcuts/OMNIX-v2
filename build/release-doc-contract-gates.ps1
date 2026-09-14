# Anti-drift contract for OMNIX release/production documentation.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$readmePath = Join-Path $root 'README.md'
$ciPath = Join-Path $root 'docs\CI-VERIFICATION.md'
$runbookPath = Join-Path $root 'docs\PRODUCTION-ACCEPTANCE.md'

foreach ($path in @($readmePath,$ciPath,$runbookPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "RELEASE_DOC_CONTRACT: required documentation is missing: $path"
    }
}

$readme = Get-Content -LiteralPath $readmePath -Raw
$ci = Get-Content -LiteralPath $ciPath -Raw
$runbook = Get-Content -LiteralPath $runbookPath -Raw

foreach ($needle in @(
    'docs/PRODUCTION-ACCEPTANCE.md',
    'tools\bound-real-acceptance.ps1',
    'OMNIX-build-identity.json',
    'OMNIX-FINAL-PRODUCTION-GATE-002',
    'implementation harnesses'
)) {
    if ($readme.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "RELEASE_DOC_CONTRACT: README missing canonical release concept '$needle'."
    }
}

foreach ($needle in @(
    'PRODUCTION-ACCEPTANCE.md',
    'bound-real-acceptance.ps1',
    'PAYLOAD-IDENTITY-BINDING-RUNTIME-001',
    'RealTimeProtectionEnabled=false',
    'OMNIX-FINAL-PRODUCTION-GATE-002'
)) {
    if ($ci.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "RELEASE_DOC_CONTRACT: CI verification doc missing '$needle'."
    }
}

foreach ($needle in @(
    'tools\bound-real-acceptance.ps1',
    '-Kind FullOfficeE2E',
    '-Kind LocalOffline',
    '-Kind Provider',
    '-Kind RestartBefore',
    '-Kind RestartAfter',
    'OMNIX-build-identity.json',
    'PayloadIdentitySha256',
    'lifecycle-acceptance.ps1',
    'consumer-security-acceptance.ps1',
    'sign-production.ps1',
    'final-production-gate.ps1',
    'OMNIX-FINAL-PRODUCTION-GATE-002'
)) {
    if ($runbook.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "RELEASE_DOC_CONTRACT: production runbook missing '$needle'."
    }
}

$stale = @(
    'OMNIX-Setup-1.0.0.exe',
    'without executing a Windows build'
)
foreach ($needle in $stale) {
    if ($readme.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $ci.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $runbook.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "RELEASE_DOC_CONTRACT: stale release statement returned: '$needle'."
    }
}

# The runbook must explicitly distinguish raw harness output from bound production evidence.
if ($runbook.IndexOf('raw reports are intentionally insufficient',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'RELEASE_DOC_CONTRACT: production runbook no longer states that raw harness reports are insufficient.'
}
if ($runbook.IndexOf('Anything else is not a production release',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'RELEASE_DOC_CONTRACT: production runbook lost the fail-closed final result statement.'
}

Write-Host 'OMNIX RELEASE-DOC-CONTRACT-001: PASS'
exit 0
