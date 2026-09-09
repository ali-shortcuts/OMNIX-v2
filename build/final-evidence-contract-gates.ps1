# OMNIX final evidence anti-drift contract
# Structural/parser checks only. These checks NEVER substitute for real execution.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-RepoFile([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing required file: $relative")
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}

function Require-Contains([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-RepoFile $relative
    # String.Contains is literal; unlike -like it does not treat []/*/? as wildcard syntax.
    if (-not $text.Contains($needle)) { $failures.Add("${relative}: missing '$needle' — $reason") }
}

function Require-NotContains([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-RepoFile $relative
    if ($text.Contains($needle)) { $failures.Add("${relative}: forbidden '$needle' — $reason") }
}

function Require-PowerShellParses([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing required PowerShell file: $relative")
        return
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $failures.Add("${relative}: PowerShell parser error — $($parseError.Message)")
    }
}

# ---------------------------------------------------------------------------
# Deterministic WPF UI Automation evidence required for real rendered chat proof.
# ---------------------------------------------------------------------------
Require-Contains 'src/OMNIX.Core/Ui/ChatBubble.cs' 'OMNIX.AssistantMessageBody' 'Real AI E2E needs a deterministic rendered assistant body target.'
Require-Contains 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.ChatInput' 'Real Office UI E2E needs deterministic chat input.'
Require-Contains 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.SendButton' 'Real Office AI E2E needs deterministic Send invocation.'
Require-Contains 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.StatusText' 'Provider/privacy/runtime failures must be observable without guessing UI text.'
Require-Contains 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.ClearButton' 'Acceptance must be able to remove its temporary test conversation.'

# ---------------------------------------------------------------------------
# Office -> AI Gateway/provider -> rendered UI random-marker round-trip.
# ---------------------------------------------------------------------------
Require-PowerShellParses 'tools/real-office-ai-e2e.ps1'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'OFFICE-AI-E2E-REAL-001' 'Real Office AI route needs a stable evidence TestId.'
Require-Contains 'tools/real-office-ai-e2e.ps1' '[Guid]::NewGuid()' 'Every host must use an unpredictable per-run marker.'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'OMNIX.AssistantMessageBody' 'PASS must inspect the rendered assistant response, not only provider transport.'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'AllMarkerRoundTripsPass' 'Aggregate PASS must require Excel, Word and PowerPoint marker round-trips.'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'ProcessExitedCleanly' 'Real AI acceptance must verify Office processes exit cleanly.'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'MarkerSha256' 'Reports may retain marker hashes rather than response bodies.'
Require-Contains 'tools/real-office-ai-e2e.ps1' 'Temporary unsaved Office documents only' 'Acceptance must remain isolated from user documents.'
Require-NotContains 'tools/real-office-ai-e2e.ps1' 'SaveAs' 'AI E2E must never save its temporary Office files.'
Require-NotContains 'tools/real-office-ai-e2e.ps1' 'Restart-Computer' 'AI E2E must never restart Windows.'
Require-NotContains 'tools/real-office-ai-e2e.ps1' 'Disable-NetAdapter' 'AI E2E must never change networking.'
Require-NotContains 'tools/real-office-ai-e2e.ps1' 'New-NetFirewallRule' 'AI E2E must never change firewall policy.'

# ---------------------------------------------------------------------------
# Full Office E2E must include the AI route and exact installer hash binding.
# ---------------------------------------------------------------------------
Require-PowerShellParses 'tools/full-office-e2e.ps1'
Require-Contains 'tools/full-office-e2e.ps1' 'EvidenceSchema = 2' 'Final Office E2E schema must include AI round-trip evidence.'
Require-Contains 'tools/full-office-e2e.ps1' 'ExpectedInstallerSha256' 'Final E2E must support explicit intended-installer hash binding.'
Require-Contains 'tools/full-office-e2e.ps1' 'HashMatchedExpected' 'Evidence must record whether intended and executed installer hashes match.'
Require-Contains 'tools/full-office-e2e.ps1' 'real-office-ai-e2e.ps1' 'Full Office E2E must route real Office context through the real AI workspace.'
Require-Contains 'tools/full-office-e2e.ps1' 'AiRoundTrip' 'Aggregate evidence must expose real AI round-trip results.'
Require-Contains 'tools/full-office-e2e.ps1' 'SkipAiRoundTrip' 'Development may explicitly skip AI, while final production gate can reject a skipped run.'
Require-NotContains 'tools/full-office-e2e.ps1' 'Restart-Computer' 'Full E2E must never restart the user machine.'
Require-NotContains 'tools/full-office-e2e.ps1' 'Disable-NetAdapter' 'Full E2E must never alter networking.'

# ---------------------------------------------------------------------------
# Repair/reinstall/uninstall lifecycle: settings + shared Office state preservation.
# ---------------------------------------------------------------------------
Require-PowerShellParses 'tools/lifecycle-acceptance.ps1'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'LIFECYCLE-REAL-001' 'Lifecycle evidence needs a stable TestId.'
Require-Contains 'tools/lifecycle-acceptance.ps1' "ValidateSet('Baseline','AfterRepair','AfterUninstall')" 'Lifecycle proof must be explicit and staged.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'SettingsSha256' 'DPAPI-protected settings must be compared by hash without exposing contents.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'ResiliencyPreservedAcrossRepair' 'Repair must prove shared Office recovery state is preserved.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'ResiliencyPreservedAcrossUninstall' 'Uninstall must prove shared Office recovery state is preserved.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'OmnixRegistrationRemoved' 'Uninstall must remove OMNIX-owned Office registration.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'AppPayloadRemoved' 'Uninstall must remove OMNIX application payload.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'DevelopmentCertificateRemoved' 'Uninstall must clean only the exact OMNIX development trust material when applicable.'
Require-Contains 'tools/lifecycle-acceptance.ps1' 'BaselinePass' 'A failed baseline may never flow into a later lifecycle PASS.'
Require-NotContains 'tools/lifecycle-acceptance.ps1' 'Start-Process -FilePath $InstallerPath' 'Lifecycle evidence must not silently execute installers.'
Require-NotContains 'tools/lifecycle-acceptance.ps1' 'Restart-Computer' 'Lifecycle evidence must never restart Windows.'
Require-NotContains 'tools/lifecycle-acceptance.ps1' 'Disable-NetAdapter' 'Lifecycle evidence must never modify networking.'
Require-NotContains 'tools/lifecycle-acceptance.ps1' 'RegDelete' 'Lifecycle acceptance itself must stay read-only over the registry.'

# ---------------------------------------------------------------------------
# Final production gate: no dev-signature argument, all evidence cross-bound.
# ---------------------------------------------------------------------------
Require-PowerShellParses 'tools/final-production-gate.ps1'
Require-Contains 'tools/final-production-gate.ps1' 'OMNIX-FINAL-PRODUCTION-GATE-001' 'Production needs one canonical final TestId.'
Require-Contains 'tools/final-production-gate.ps1' 'release-readiness.ps1' 'Final gate must inherit persistence/UI/reboot/offline/provider/privacy/signature requirements.'
Require-Contains 'tools/final-production-gate.ps1' 'OFFICE-E2E-REAL-001' 'Final gate must require full Office E2E.'
Require-Contains 'tools/final-production-gate.ps1' 'OFFICE-AI-E2E-REAL-001' 'Final gate must require real Office->AI->UI evidence.'
Require-Contains 'tools/final-production-gate.ps1' 'LIFECYCLE-REAL-001' 'Final gate must require repair/uninstall lifecycle evidence.'
Require-Contains 'tools/final-production-gate.ps1' 'HashMatchedExpected' 'Final gate must reject Office E2E not explicitly bound to intended installer hash.'
Require-Contains 'tools/final-production-gate.ps1' 'SignatureStatus' 'Final gate must enforce production Authenticode through base evidence.'
Require-Contains 'tools/final-production-gate.ps1' 'SelfSigned' 'Self-signed installer must be rejected for production.'
$finalGate = Read-RepoFile 'tools/final-production-gate.ps1'
# Comments may explain the forbidden dev switch; reject only a real quoted argument in the child args.
if ($finalGate -match "(?m)^\s*'-AllowDevelopmentSignature'\s*,?\s*$" -or
    $finalGate -match '(?m)^\s*"-AllowDevelopmentSignature"\s*,?\s*$') {
    $failures.Add('tools/final-production-gate.ps1: final production gate passes the development-signature escape argument.')
}
Require-NotContains 'tools/final-production-gate.ps1' 'Restart-Computer' 'Final gate only aggregates evidence; it must never restart Windows.'
Require-NotContains 'tools/final-production-gate.ps1' 'Disable-NetAdapter' 'Final gate only aggregates evidence; it must never alter networking.'

# Production signing helper must use an already provisioned certificate and never export a private key.
Require-PowerShellParses 'build/sign-production.ps1'
Require-Contains 'build/sign-production.ps1' 'PRODUCTION-AUTHENTICODE-001' 'Production signing needs auditable evidence.'
Require-Contains 'build/sign-production.ps1' 'CertificateThumbprint' 'Signing must select an already provisioned certificate by thumbprint.'
Require-Contains 'build/sign-production.ps1' '/tr $TimestampUrl' 'Production Authenticode must use RFC3161 timestamping.'
Require-Contains 'build/sign-production.ps1' 'PrivateKeyExportedByScript = $false' 'Signing helper must document that it never exports the private key.'
Require-NotContains 'build/sign-production.ps1' 'Export-PfxCertificate' 'Production helper must never export private keys.'
Require-NotContains 'build/sign-production.ps1' 'ConvertTo-SecureString' 'No PFX password material should be handled by this helper.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX FINAL-EVIDENCE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX FINAL-EVIDENCE CONTRACT: PASS'
Write-Host 'Final evidence structures are intact. Real Office/provider/reboot/lifecycle execution and trusted production signing remain separate runtime requirements.'
exit 0
