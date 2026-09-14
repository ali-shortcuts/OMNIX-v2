# Anti-drift contract for the documented production evidence entrypoints.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$readmePath = Join-Path $root 'README.md'
$ciPath = Join-Path $root 'docs\CI-VERIFICATION.md'
$runbookPath = Join-Path $root 'docs\PRODUCTION-EVIDENCE-RUNBOOK.md'
$interactiveRunnerPath = Join-Path $root 'docs\INTERACTIVE-OFFICE-RUNNER.md'

foreach ($path in @($readmePath,$ciPath,$runbookPath,$interactiveRunnerPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "PRODUCTION_RUNBOOK_CONTRACT: required documentation missing: $path"
    }
}

$readme = Get-Content -LiteralPath $readmePath -Raw
$ci = Get-Content -LiteralPath $ciPath -Raw
$runbook = Get-Content -LiteralPath $runbookPath -Raw
$interactiveRunner = Get-Content -LiteralPath $interactiveRunnerPath -Raw

function Require-Text([string]$text,[string]$needle,[string]$label) {
    if ($text.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "PRODUCTION_RUNBOOK_CONTRACT: $label missing '$needle'."
    }
}

foreach ($needle in @(
    'tools/bound-real-acceptance.ps1 -Kind FullOfficeE2E',
    'tools/bound-real-acceptance.ps1 -Kind Provider',
    'tools/bound-real-acceptance.ps1 -Kind LocalOffline',
    'tools/bound-real-acceptance.ps1 -Kind RestartBefore',
    'tools/bound-real-acceptance.ps1 -Kind RestartAfter',
    'OMNIX-build-identity.json',
    'implementation harnesses',
    'final-production-gate.ps1',
    'final signed installer'
)) {
    Require-Text $readme $needle 'README'
}

foreach ($needle in @(
    'PRODUCTION-EVIDENCE-RUNBOOK.md',
    'bound-real-acceptance.ps1 -Kind FullOfficeE2E',
    'bound-real-acceptance.ps1 -Kind Provider',
    'bound-real-acceptance.ps1 -Kind LocalOffline',
    'bound-real-acceptance.ps1 -Kind RestartBefore',
    'bound-real-acceptance.ps1 -Kind RestartAfter',
    'OMNIX-build-identity.json',
    'ProductionReleaseApproved = false'
)) {
    Require-Text $ci $needle 'CI verification guide'
}

foreach ($needle in @(
    'Non-negotiable identity rule',
    'OMNIX-build-identity.json',
    'OMNIX.Core.dll',
    'OMNIX.Excel.dll',
    'OMNIX.Word.dll',
    'OMNIX.PowerPoint.dll',
    '-Kind FullOfficeE2E',
    '-Kind Provider',
    '-Kind LocalOffline',
    '-Kind RestartBefore',
    '-Kind RestartAfter',
    'INTERACTIVE-OFFICE-RUNNER.md',
    'omnix-office-interactive',
    'preflight',
    'Session 0',
    'sign-production.ps1',
    'payload-bound lifecycle evidence',
    '-Phase Baseline',
    '-Phase AfterRepair',
    '-Phase AfterUninstall',
    'PayloadIdentitySha256',
    'PayloadIdentityPreservedAcrossRepair=true',
    'all four primary assemblies',
    'consumer-security-acceptance.ps1',
    'final-production-gate.ps1',
    'OMNIX-FINAL-PRODUCTION-GATE-002',
    'DEVELOPMENT_ONLY'
)) {
    Require-Text $runbook $needle 'production evidence runbook'
}

foreach ($needle in @(
    'real-office-interactive',
    'omnix-office-interactive',
    'self-hosted',
    'Session 0',
    'LocalSystem',
    'Explorer',
    'mode: preflight',
    'mode: full-office-e2e',
    'real-machine-preflight.ps1',
    'bound-real-acceptance.ps1',
    'PrimaryAssembliesValidated=true',
    'does not automate',
    'OMNIX-FINAL-PRODUCTION-GATE-002'
)) {
    Require-Text $interactiveRunner $needle 'interactive Office runner guide'
}

if ($runbook.IndexOf('sign the final installer before producing exact-installer real-machine evidence',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'PRODUCTION_RUNBOOK_CONTRACT: runbook must require production signing before exact-installer evidence.'
}
if ($runbook.IndexOf('AfterUninstall cannot hash an application payload that should no longer exist',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'PRODUCTION_RUNBOOK_CONTRACT: runbook must explain how lifecycle identity survives uninstall.'
}
if ($interactiveRunner.IndexOf('Do not install/run it as a background Windows service',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'PRODUCTION_RUNBOOK_CONTRACT: interactive runner guide must forbid background Windows service execution.'
}
if ($interactiveRunner.IndexOf('Do not continue to Full Office E2E if preflight fails',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'PRODUCTION_RUNBOOK_CONTRACT: interactive runner guide must fail closed after preflight failure.'
}

Write-Host 'PRODUCTION-RUNBOOK-CONTRACT-003: PASS'
Write-Host 'Canonical bound evidence, interactive Office runner safety, payload-bound lifecycle and final production gate documentation are aligned.'
