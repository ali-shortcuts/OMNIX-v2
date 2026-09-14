# CI Verification — what green CI proves and what still needs a real machine

The OMNIX release contract is explicit: compilation and hosted CI are necessary evidence, not production acceptance.

For the canonical real-machine procedure, use [PRODUCTION-EVIDENCE-RUNBOOK.md](PRODUCTION-EVIDENCE-RUNBOOK.md).

## What the current hosted CI proves

For one exact checked-out source commit, the required workflows can prove all of the following when they complete successfully:

1. `OMNIX.sln` compiles on `windows-2022` with .NET Framework 4.8 and the VSTO/Office build SDK.
2. Excel, Word and PowerPoint produce their VSTO DLL, `.dll.manifest` and `.vsto` outputs.
3. CI uses a temporary non-exportable development certificate for VSTO manifest signing; no PFX/private key is staged into the installer artifact.
4. The validated compiled handoff is staged into the installer payload rather than packaging arbitrary transient build folders.
5. `OMNIX-build-identity.json` is generated from the exact Git commit and records SHA-256 for `OMNIX.Core.dll`, `OMNIX.Excel.dll`, `OMNIX.Word.dll` and `OMNIX.PowerPoint.dll`.
6. The payload inventory contains the required Office hosts, Core, build identity and maintenance helpers before Inno Setup compilation.
7. Inno Setup produces one development installer and the build manifest records its exact byte size and SHA-256.
8. Deterministic runtime acceptance exercises Gateway privacy ordering, encrypted history, provider diagnostics, request budgets, Office tool request isolation, provider-error redaction and image normalization.
9. The architecture/anti-drift workflow executes Windows PowerShell 5.1 parser/ASCII compatibility checks plus synthetic installed-payload tamper tests. Tampered Core/host assemblies, missing build identity, mismatched source identity, stale evidence and cross-build evidence must fail closed.
10. Release-provenance acceptance verifies that preview runtime evidence can be packaged and bound to the exact source/run.
11. The development preview publisher waits for the exact-head `build`, `architecture-contract`, `request-budget-runtime` and `release-provenance-contract` workflows to succeed before it can publish a prerelease.
12. A published development preview includes checksum-bound installer/source/runtime/provenance assets tied to that exact source commit.

## What hosted CI does not prove

GitHub-hosted runners do not provide the real interactive consumer Office environment required for production. A green CI result does **not** prove:

- automatic OMNIX load in real desktop Excel, Word and PowerPoint;
- real Ribbon visibility and `Open Workspace` task-pane behavior;
- per-window Office isolation across actual Office windows;
- real Office context/read/write/undo behavior on a consumer machine;
- the complete Office → Workspace → AI Gateway/provider → rendered streaming UI round trip;
- persistence across an actual Windows restart;
- live provider/account/model behavior and quotas on the intended machine/account;
- local Ollama/LM Studio operation while public Internet is genuinely disconnected;
- same-build repair and uninstall behavior on the intended Office installation;
- consumer Defender/SmartScreen behavior with normal protections enabled;
- trusted timestamped production Authenticode signing.

Those are real-machine release gates and must be produced through the canonical runbook.

## Defender evidence boundary

The build workflow removes its temporary build exclusion before performing the installer custom scan and records the observed Defender state in `defender-report.txt`.

Do not convert that hosted scan into a consumer-security claim. If the hosted runner reports `RealTimeProtectionEnabled: False`, the scan is CI diagnostic evidence only. Production consumer-security acceptance requires the separate real-machine harness with real-time protection and behavior monitoring enabled and a normal SmartScreen observation.

## Development preview boundary

A development preview may legitimately report all of the following at once:

```text
ArtifactType = DEVELOPMENT_ONLY
ProductionReleaseApproved = false
RealOfficeRuntimeTested = false
```

while still having successful exact-head build/runtime/provenance workflows. That is not a contradiction; it is the intended honesty boundary.

The release workflow verifies the installer SHA-256 against both the build manifest and the build checksum before renaming/uploading the installer. It also creates the source ZIP directly from the exact tested Git commit, adds `SOURCE-COMMIT.txt`, packages sanitized runtime-hardening evidence for the exact runtime workflow run, and writes `ci-provenance.json` with the required exact-head workflow run IDs.

## Canonical real-machine evidence path

Do **not** run raw Office/provider/offline/restart scripts and treat their raw PASS files as production evidence.

For these evidence classes, use:

```text
tools/bound-real-acceptance.ps1 -Kind FullOfficeE2E
tools/bound-real-acceptance.ps1 -Kind Provider
tools/bound-real-acceptance.ps1 -Kind LocalOffline
tools/bound-real-acceptance.ps1 -Kind RestartBefore
tools/bound-real-acceptance.ps1 -Kind RestartAfter
```

The bound runner verifies the installed `OMNIX-build-identity.json`, exact source commit and hashes of all four primary OMNIX assemblies before adding evidence binding.

Lifecycle and consumer-security use their canonical exact-installer entrypoints, and the complete evidence set is consumed by `tools/final-production-gate.ps1`.

See [PRODUCTION-EVIDENCE-RUNBOOK.md](PRODUCTION-EVIDENCE-RUNBOOK.md) for command order and the signing/hash rule.

## Final acceptance

The only final production PASS is a fresh result from the canonical final gate for the exact intended installer:

```json
{
  "TestId": "OMNIX-FINAL-PRODUCTION-GATE-002",
  "FailureCount": 0,
  "OverallPass": true
}
```

Anything else remains development/test evidence, not production approval.

## Build diagnostics

The build workflow uploads MSBuild binary logs under `build/logs/*.binlog`. Open them with MSBuild Structured Log Viewer when diagnosing compile/target problems.
