# OMNIX final evidence anti-drift contract. Structural/parser checks only.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$failures=New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$r){$p=Join-Path $root $r;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){$failures.Add("Missing: $r");return ''};return Get-Content -LiteralPath $p -Raw}
function Need([string]$r,[string]$n,[string]$why){$t=Read-Repo $r;if(-not$t.Contains($n)){$failures.Add("${r}: missing '$n' — $why")}}
function Forbid([string]$r,[string]$n,[string]$why){$t=Read-Repo $r;if($t.Contains($n)){$failures.Add("${r}: forbidden '$n' — $why")}}
function Parse-Ps([string]$r){$p=Join-Path $root $r;if(-not(Test-Path -LiteralPath $p -PathType Leaf)){$failures.Add("Missing: $r");return};$tok=$null;$err=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err);foreach($e in @($err)){$failures.Add("${r}: parser error — $($e.Message)")}}

# Deterministic rendered workspace evidence.
Need 'src/OMNIX.Core/Ui/ChatBubble.cs' 'OMNIX.AssistantMessageBody' 'real AI output must be observable in rendered WPF UI.'
Need 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.ChatInput' 'chat input must be deterministic for UIA.'
Need 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.SendButton' 'send action must be deterministic for UIA.'
Need 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.StatusText' 'runtime/provider failures must be observable.'
Need 'src/OMNIX.Core/Ui/Views/ChatView.xaml' 'OMNIX.ClearButton' 'acceptance must clean its own test chat.'

# Office -> AI -> rendered UI random-marker proof.
Parse-Ps 'tools/real-office-ai-e2e.ps1'
Need 'tools/real-office-ai-e2e.ps1' 'OFFICE-AI-E2E-REAL-001' 'stable TestId required.'
Need 'tools/real-office-ai-e2e.ps1' '[Guid]::NewGuid()' 'marker must be unpredictable.'
Need 'tools/real-office-ai-e2e.ps1' 'OMNIX.AssistantMessageBody' 'PASS must inspect the rendered assistant answer.'
Need 'tools/real-office-ai-e2e.ps1' 'AllMarkerRoundTripsPass' 'all three Office hosts are mandatory.'
Need 'tools/real-office-ai-e2e.ps1' 'ProcessExitedCleanly' 'test must not leave Office orphan processes.'
Need 'tools/real-office-ai-e2e.ps1' 'MarkerSha256' 'report stores marker hash, not model response.'
Forbid 'tools/real-office-ai-e2e.ps1' 'SaveAs' 'temporary test documents must never be saved.'
Forbid 'tools/real-office-ai-e2e.ps1' 'Restart-Computer' 'test must never restart Windows.'
Forbid 'tools/real-office-ai-e2e.ps1' 'Disable-NetAdapter' 'test must never alter networking.'
Forbid 'tools/real-office-ai-e2e.ps1' 'New-NetFirewallRule' 'test must never alter firewall policy.'

# Full Office E2E exact-installer binding + AI route + guarded writes.
Parse-Ps 'tools/full-office-e2e.ps1'
Need 'tools/full-office-e2e.ps1' 'EvidenceSchema = 3' 'Office E2E v3 evidence required.'
Need 'tools/full-office-e2e.ps1' 'ExpectedInstallerSha256' 'intended installer hash must be explicit.'
Need 'tools/full-office-e2e.ps1' 'HashMatchedExpected' 'hash-match result must be recorded.'
Need 'tools/full-office-e2e.ps1' 'office-write-boundary-acceptance.ps1' 'full E2E must prove approved-but-invalid writes remain blocked.'
Need 'tools/full-office-e2e.ps1' 'WriteBoundary' 'write-boundary result must be aggregated.'
Need 'tools/full-office-e2e.ps1' 'real-office-ai-e2e.ps1' 'full E2E must include real AI route.'
Need 'tools/full-office-e2e.ps1' 'AiRoundTrip' 'AI round-trip result must be aggregated.'
Parse-Ps 'tools/office-write-boundary-acceptance.ps1'
Need 'tools/office-write-boundary-acceptance.ps1' 'OFFICE-WRITE-BOUNDARY-REAL-001' 'stable three-host write-boundary TestId required.'
Need 'tools/office-write-boundary-acceptance.ps1' 'AllBoundaryChecksPass' 'all invalid-write boundaries must pass.'
Forbid 'tools/full-office-e2e.ps1' 'Restart-Computer' 'full E2E must never restart Windows.'
Forbid 'tools/full-office-e2e.ps1' 'Disable-NetAdapter' 'full E2E must never alter networking.'

# Stable lifecycle wrapper + precise core.
Parse-Ps 'tools/lifecycle-acceptance.ps1'
Need 'tools/lifecycle-acceptance.ps1' 'lifecycle-core-acceptance.ps1' 'canonical entrypoint must delegate to the precise v2 engine.'
Parse-Ps 'tools/lifecycle-core-acceptance.ps1'
Need 'tools/lifecycle-core-acceptance.ps1' 'LIFECYCLE-REAL-002' 'precise lifecycle TestId required.'
Need 'tools/lifecycle-core-acceptance.ps1' "ValidateSet('Baseline','AfterRepair','AfterUninstall')" 'three explicit lifecycle phases required.'
Need 'tools/lifecycle-core-acceptance.ps1' 'InstallerSha256' 'lifecycle must be bound to exact repair candidate.'
Need 'tools/lifecycle-core-acceptance.ps1' 'CoreSha256' 'same-build repair must preserve installed Core hash.'
Need 'tools/lifecycle-core-acceptance.ps1' 'DisabledItems' 'shared DisabledItems recovery state must be preserved.'
Need 'tools/lifecycle-core-acceptance.ps1' 'CrashingAddinList' 'shared crashing-addin state must be preserved.'
Need 'tools/lifecycle-core-acceptance.ps1' 'DoNotDisableAddinList' 'shared do-not-disable state must be preserved.'
Need 'tools/lifecycle-core-acceptance.ps1' 'SharedOfficeRecoveryStatePreservedAcrossRepair' 'repair preservation must be reported.'
Need 'tools/lifecycle-core-acceptance.ps1' 'SharedOfficeRecoveryStatePreservedAcrossUninstall' 'uninstall preservation must be reported.'
Need 'tools/lifecycle-core-acceptance.ps1' 'DevelopmentCertificateRemoved' 'exact development trust cleanup must be proven.'
Forbid 'tools/lifecycle-core-acceptance.ps1' 'RegDelete' 'lifecycle evidence engine must remain registry read-only.'
Forbid 'tools/lifecycle-core-acceptance.ps1' 'Restart-Computer' 'lifecycle engine must never restart Windows.'
Forbid 'tools/lifecycle-core-acceptance.ps1' 'Disable-NetAdapter' 'lifecycle engine must never change network state.'

# Stable final gate wrapper + v2 production core.
Parse-Ps 'tools/final-production-gate.ps1'
Need 'tools/final-production-gate.ps1' 'final-production-core.ps1' 'canonical final gate must delegate to the production core.'
Forbid 'tools/final-production-gate.ps1' 'AllowDevelopmentSignature' 'canonical production entrypoint must expose no dev-signature escape.'
Parse-Ps 'tools/final-production-core.ps1'
Need 'tools/final-production-core.ps1' 'OMNIX-FINAL-PRODUCTION-GATE-002' 'canonical final TestId required.'
Need 'tools/final-production-core.ps1' 'release-readiness.ps1' 'base persistence/UI/reboot/offline/provider/privacy/signature gate must be inherited.'
Need 'tools/final-production-core.ps1' 'OFFICE-E2E-REAL-001' 'full Office E2E is mandatory.'
Need 'tools/final-production-core.ps1' 'OFFICE-WRITE-BOUNDARY-REAL-001' 'real three-host write-boundary evidence is mandatory.'
Need 'tools/final-production-core.ps1' 'OFFICE-AI-E2E-REAL-001' 'real Office context-to-AI rendered UI route is mandatory.'
Need 'tools/final-production-core.ps1' 'LIFECYCLE-REAL-002' 'precise repair/uninstall lifecycle is mandatory.'
Need 'tools/final-production-core.ps1' 'CONSUMER-SECURITY-REAL-001' 'consumer protection evidence is mandatory.'
Need 'tools/final-production-core.ps1' 'InstallerSha256' 'lifecycle installer hash must cross-bind to final installer.'
Need 'tools/final-production-core.ps1' 'HashMatchedExpected' 'Office E2E intended hash must be true.'
Need 'tools/final-production-core.ps1' 'SharedOfficeRecoveryStatePreservedAcrossUninstall' 'final gate must enforce shared recovery preservation.'
Need 'tools/final-production-core.ps1' 'SignatureStatus' 'trusted Authenticode must be enforced.'
Need 'tools/final-production-core.ps1' 'Timestamped' 'production signature must be timestamped.'
Forbid 'tools/final-production-core.ps1' 'AllowDevelopmentSignature' 'production core must have no dev-signature bypass.'
Forbid 'tools/final-production-core.ps1' 'Restart-Computer' 'final aggregator must never restart Windows.'
Forbid 'tools/final-production-core.ps1' 'Disable-NetAdapter' 'final aggregator must never alter networking.'

# Production signer: provisioned certificate only, no private-key export/password files.
Parse-Ps 'build/sign-production.ps1'
Need 'build/sign-production.ps1' 'PRODUCTION-AUTHENTICODE-001' 'signing evidence required.'
Need 'build/sign-production.ps1' 'CertificateThumbprint' 'signer must use pre-provisioned certificate.'
Need 'build/sign-production.ps1' '/tr $TimestampUrl' 'RFC3161 timestamping required.'
Need 'build/sign-production.ps1' 'PrivateKeyExportedByScript = $false' 'private key must not be exported by helper.'
Forbid 'build/sign-production.ps1' 'Export-PfxCertificate' 'private key export is forbidden.'
Forbid 'build/sign-production.ps1' 'ConvertTo-SecureString' 'PFX passwords are not handled by this helper.'

if($failures.Count -gt 0){Write-Host 'OMNIX FINAL-EVIDENCE CONTRACT: FAIL' -ForegroundColor Red;foreach($f in $failures){Write-Host " - $f" -ForegroundColor Red};exit 1}
Write-Host 'OMNIX FINAL-EVIDENCE CONTRACT: PASS'
Write-Host 'Structures are intact; real Office/provider/reboot/lifecycle/consumer-security execution and trusted production signing remain runtime requirements.'
exit 0
