# CI Verification - what a green build proves, and what still requires a real machine

The OMNIX release contract is explicit: code compilation and green hosted CI are **not** production acceptance.

This document records what current GitHub Actions actually proves and what must still be executed on the intended Windows/Office environment. The canonical real-machine procedure is [PRODUCTION-ACCEPTANCE.md](./PRODUCTION-ACCEPTANCE.md).

## What current hosted CI proves

For the exact source commit checked out by the workflow, current Windows CI verifies the following classes of evidence:

1. `OMNIX.sln` compiles with .NET Framework 4.8, the VSTO SDK, Office PIAs, WPF, and the native Excel/Word/PowerPoint host projects.
2. Excel, Word, and PowerPoint each produce the required VSTO DLL, deployment manifest, and application manifest artifacts.
3. The validated compiled handoff is staged into a single installer payload rather than packaging transient build folders directly.
4. `build/package.ps1` generates `OMNIX-build-identity.json` containing the exact Git source commit plus SHA-256 values for `OMNIX.Core.dll`, `OMNIX.Excel.dll`, `OMNIX.Word.dll`, and `OMNIX.PowerPoint.dll`.
5. The payload inventory is generated and the installer build fails closed if required Office/Core files or the installed build identity are absent.
6. Inno Setup compiles a single development installer executable.
7. Deterministic runtime acceptance covers the AI Gateway privacy boundary, encrypted chat-history storage/migration, provider diagnostics, request budgets, tool isolation, image normalization, evidence guards, and installed-payload tamper detection.
8. Windows PowerShell 5.1 parses the production-evidence scripts and the evidence-critical scripts are kept ASCII-safe for that compatibility baseline.
9. The development artifact manifest records the exact source commit and installer hash and explicitly reports `ProductionReleaseApproved=false`.
10. The development-preview workflow waits for exact-head CI gates, downloads the exact build artifact, verifies runtime-hardening evidence, builds an exact-source ZIP, writes CI provenance, and only then publishes a prerelease when explicitly triggered by the preview marker.

A successful hosted build therefore proves a reproducible **development artifact** for that exact commit. It does not prove that desktop Office loaded the add-in on a real user machine.

## Current payload identity contract

Every current staged/installed payload must contain:

```text
OMNIX-build-identity.json
```

The identity binds the exact source commit to SHA-256 values for the four primary OMNIX assemblies:

```text
OMNIX.Core.dll
OMNIX.Excel.dll
OMNIX.Word.dll
OMNIX.PowerPoint.dll
```

The deterministic `PAYLOAD-IDENTITY-BINDING-RUNTIME-001` acceptance rejects at least these conditions:

- tampered Core assembly;
- tampered Office-host assembly;
- missing build identity;
- source-checkout mismatch.

Real-machine `EvidenceBinding` schema 2 additionally carries the installed payload identity hash. The final production binding guard rejects reports from another source, another Core, another payload identity, or an expired evidence window.

## Defender evidence: important limitation

Hosted CI performs a custom Microsoft Defender scan of the built development installer when Defender tooling is available and records the actual protection state in `defender-report.txt`/artifact metadata.

That scan is **not** the consumer-security release gate. If hosted CI reports `RealTimeProtectionEnabled=false`, the scan may still be useful for build diagnostics, but it cannot be described as a normal protected consumer-machine scenario.

Production security evidence must be created separately with `tools/consumer-security-acceptance.ps1` on a real Windows consumer test machine with Defender Antivirus, real-time protection, behavior monitoring, and current signatures enabled, plus an honest normal SmartScreen observation. The test must not weaken or bypass those protections.

## What hosted CI does not prove

Hosted GitHub Windows runners do not provide the real desktop Office environment needed for the production claims below. Green CI does **not** by itself prove:

- automatic OMNIX loading in installed desktop Excel, Word, and PowerPoint;
- real Ribbon visibility and `Open Workspace` behavior;
- a visible docked WPF task pane that remains isolated per Office window;
- real Office read/write/undo behavior against user-hosted Office applications;
- real Office-context -> workspace -> AI Gateway/provider -> rendered streaming response E2E;
- persistence across an actual user-initiated Windows restart;
- a real local Ollama/LM Studio response while public Internet is observably disconnected;
- current live-provider behavior for the intended accounts/quotas/models;
- repair/uninstall behavior on the final production candidate;
- consumer Defender + SmartScreen behavior under normal protection;
- trusted, timestamped production Authenticode signing.

Those remain mandatory real-machine release gates.

## Canonical real-machine evidence path

For Office E2E, local-offline, live-provider, and restart evidence, operators must use:

```powershell
.\tools\bound-real-acceptance.ps1
```

Do not use raw PASS output from the lower-level Office/provider/offline/restart harnesses as production evidence. Those scripts are implementation details for the canonical wrapper. The wrapper runs the harness, requires a newly generated report, validates the installed build identity and primary assembly hashes, and only then writes the bound evidence consumed by the final gate.

See [PRODUCTION-ACCEPTANCE.md](./PRODUCTION-ACCEPTANCE.md) for the exact sequence and commands.

Lifecycle and consumer-security acceptance remain separate exact-candidate harnesses because they intentionally exercise repair/uninstall state and normal Windows security state respectively.

## Final production condition

The canonical production entrypoint is:

```powershell
.\tools\final-production-gate.ps1 -InstallerPath <exact-final-installer>
```

It runs the evidence-binding guard before the task-pane guard and before the complete production core.

The only production approval result is:

```json
{
  "TestId": "OMNIX-FINAL-PRODUCTION-GATE-002",
  "FailureCount": 0,
  "OverallPass": true
}
```

Anything else is not a production release.

## Build debugging

The hosted build uploads MSBuild binary logs where configured. Open `build/logs/*.binlog` with MSBuild Structured Log Viewer when diagnosing compilation or VSTO target resolution.

Build-system troubleshooting must never be converted into a compatibility claim. A compiler PASS is evidence about the build environment; `FULLY_TESTED` Office compatibility requires real-machine Office evidence for that specific Windows/Office environment.
