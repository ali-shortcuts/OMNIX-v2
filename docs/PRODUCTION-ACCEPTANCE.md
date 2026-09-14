# OMNIX Production Acceptance Runbook

This document is the canonical operator path for real-machine production evidence.

A hosted CI PASS, a development preview, or a raw acceptance report is **not** production approval. The production candidate is approved only when the exact installer, exact source commit, installed payload identity, real Office behavior, restart persistence, local/offline behavior, live provider behavior, lifecycle behavior, consumer security state, and trusted production signature all satisfy the final fail-closed gate.

## Canonical rule

For Office E2E, offline-local-AI, live-provider, and restart evidence, use only:

```powershell
tools\bound-real-acceptance.ps1
```

The lower-level scripts such as `real-office-acceptance.ps1`, `real-office-ui-acceptance.ps1`, `full-office-e2e.ps1`, `local-offline-acceptance.ps1`, `provider-acceptance.ps1`, and `reboot-persistence-acceptance.ps1` are implementation harnesses. They may be useful for debugging, but their raw reports are intentionally insufficient for the final production gate because they do not by themselves prove the exact installed payload identity.

`bound-real-acceptance.ps1` executes the underlying harness, requires freshly generated evidence, validates the installed `OMNIX-build-identity.json`, re-hashes `OMNIX.Core.dll`, `OMNIX.Excel.dll`, `OMNIX.Word.dll`, and `OMNIX.PowerPoint.dll`, verifies the source commit, and only then adds `EvidenceBinding`.

If the identity is missing, stale, cross-build, source-mismatched, or any primary assembly hash differs, evidence creation fails closed.

## Before starting

Use one intended release candidate and do not swap files during the acceptance sequence.

Record the installer SHA-256:

```powershell
$Installer = 'C:\Path\To\OMNIX-AI-OFFICE-Setup.exe'
$InstallerSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Installer).Hash.ToLowerInvariant()
$InstallerSha
```

Use the exact source checkout corresponding to the intended installer. The installed payload must contain:

```text
%LOCALAPPDATA%\Programs\OMNIX\OMNIX-build-identity.json
```

That identity binds the source commit to the hashes of the four primary OMNIX assemblies.

## 1. Full Office E2E

Close Office applications before installation/upgrade, then run from the exact source checkout:

```powershell
.\tools\bound-real-acceptance.ps1 `
  -Kind FullOfficeE2E `
  -InstallerPath $Installer `
  -ExpectedInstallerSha256 $InstallerSha
```

This path covers the installed candidate's Office persistence, real Ribbon/task-pane UI, functional Office operations, task-pane lifecycle evidence, and real Office-context-to-AI round trip through the canonical full E2E harness.

A diagnostic force-connect is never allowed to convert an automatic-load failure into PASS.

## 2. Local AI while public Internet is disconnected

With a real Ollama or LM Studio model available locally and public Internet observably disconnected by the operator/environment, run:

```powershell
.\tools\bound-real-acceptance.ps1 -Kind LocalOffline
```

The script does not disable networking or alter firewall/security configuration. It observes the environment and requires a real local model completion.

## 3. Live provider evidence

With the intended provider configuration and credentials present through OMNIX's normal protected settings path, run:

```powershell
.\tools\bound-real-acceptance.ps1 -Kind Provider
```

Acceptance reports must not contain provider secrets, prompts, private Office content, or full provider response bodies.

## 4. Restart persistence

Run the pre-restart phase:

```powershell
.\tools\bound-real-acceptance.ps1 -Kind RestartBefore
```

Then restart Windows normally yourself. The acceptance tooling never restarts the machine.

After Windows starts again, return to the same exact source checkout and installed candidate and run:

```powershell
.\tools\bound-real-acceptance.ps1 -Kind RestartAfter
```

The post-restart phase rejects a changed source commit, changed Core hash, changed installed payload identity, or a report that does not prove a changed Windows boot session.

## 5. Lifecycle evidence

Lifecycle testing remains a separate exact-installer-bound harness because it intentionally exercises repair and uninstall phases:

```powershell
.\tools\lifecycle-acceptance.ps1 -Phase Baseline -InstallerPath $Installer
```

Run the required repair flow, then:

```powershell
.\tools\lifecycle-acceptance.ps1 -Phase AfterRepair -InstallerPath $Installer
```

Run the required uninstall flow, then:

```powershell
.\tools\lifecycle-acceptance.ps1 -Phase AfterUninstall -InstallerPath $Installer
```

The lifecycle harness fingerprints settings and only the shared Office recovery subtrees OMNIX promises not to modify. Do not weaken the test by deleting unrelated Office state.

## 6. Consumer security evidence

Run this on a normal consumer Windows machine with Defender Antivirus, real-time protection, behavior monitoring, and current signatures enabled. Do not add exclusions, turn protection off, bypass SmartScreen, or change firewall policy for the test.

Launch the exact installer normally and record the actual SmartScreen disposition, then run:

```powershell
.\tools\consumer-security-acceptance.ps1 `
  -InstallerPath $Installer `
  -SmartScreenDisposition NotBlocked
```

Use the disposition that actually occurred (`NotBlocked`, `WarnedButAllowed`, `Blocked`, or `NotTested`). `Blocked` and `NotTested` do not satisfy production approval.

A hosted GitHub runner Defender scan is useful CI evidence but does not replace this consumer-machine gate. In particular, a CI machine with Defender real-time protection disabled cannot satisfy this requirement.

## 7. Trusted production signing

Development/self-signed manifest trust is not the production signing model. The production installer must be signed using an already provisioned trusted code-signing certificate and an RFC3161 timestamp:

```powershell
.\build\sign-production.ps1 `
  -InstallerPath $Installer `
  -CertificateThumbprint '<trusted-code-signing-thumbprint>' `
  -TimestampUrl 'https://<trusted-rfc3161-timestamp-service>'
```

The helper does not create, export, download, or store a private key.

Because Authenticode signing changes the installer bytes, the signed installer becomes the production candidate. Any installer-hash-bound evidence that predates the final signed bytes must be regenerated for that final candidate where required by the production gate.

## 8. Final production gate

After all required reports exist for the same exact release candidate, run:

```powershell
.\tools\final-production-gate.ps1 -InstallerPath $Installer
```

The wrapper first executes the exact-build/freshness binding guard, then the real task-pane guard, then the complete production core. A valid guard returns to its caller; any rejection stops the production path.

The only production approval result is:

```json
{
  "TestId": "OMNIX-FINAL-PRODUCTION-GATE-002",
  "FailureCount": 0,
  "OverallPass": true
}
```

Anything else is not a production release.

## Evidence freshness

The final binding guard applies bounded freshness so a historical PASS cannot be replayed indefinitely:

| Evidence | Maximum age |
| --- | ---: |
| Office E2E / persistence / UI / restart | 168 hours |
| Lifecycle | 168 hours |
| Live provider | 72 hours |
| Local offline AI | 72 hours |
| Consumer security | 72 hours |

Reports with implausibly future timestamps are rejected.

## Installed payload identity

Every current installer payload must include `OMNIX-build-identity.json`. Its build identity records the exact source commit and SHA-256 values for:

```text
OMNIX.Core.dll
OMNIX.Excel.dll
OMNIX.Word.dll
OMNIX.PowerPoint.dll
```

`EvidenceBinding` schema 2 also carries `PayloadIdentitySha256` and requires `PrimaryAssembliesValidated=true`. The final binding guard requires the same payload identity across all bound real-machine reports.

This protects against replaying a valid report from another source commit or mixing evidence from different installed binaries.

## Current honesty boundary

Development preview publication is intentionally separate from production approval. A preview may have successful compilation, deterministic runtime tests, source packaging, provenance verification, payload identity validation, and CI malware scanning while still lacking the required real Office/restart/live-provider/consumer-security/trusted-signing evidence.

Do not label OMNIX production-ready until `OMNIX-FINAL-PRODUCTION-GATE-002` passes for the intended signed installer on the intended Windows/Office environment.
