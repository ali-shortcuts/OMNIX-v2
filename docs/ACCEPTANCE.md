# Acceptance and scope

The user reported repeated failure in actual Office. That report takes precedence over earlier claims inferred from CI success. The exact failing stage on the user's PC is not yet known.

## Preservation and cleanup

Two matching repositories were found under `ali-shortcuts`: `OMNIX-v2` (1350187105) and `OMINIX.exe` (1355517711). A recovery archive was saved before cleanup. It contains complete advertised Git refs/history, all 10 releases and 22 release assets, issue/PR metadata and comments/reviews, labels/milestones, recent workflow-run records, and both requirements documents. Every release asset's size and available GitHub SHA-256 digest were verified. All 51 archive files were read back and matched to their originals.

Archive: `OMNIX-before-rebuild-2026-09-10.tar.xz` (271,549,936 bytes), SHA-256 `fa321eb8a3a9f70ab0cd8402dac42865acf3d033be0acf6982e489418c1995d3`.

The redundant repository was deleted and its absence verified. Canonical releases `v3.0.0-dev.15` and `v3.0.0-dev.12` were withdrawn. The canonical repository and Git history remain.

## Changes aimed at deployment failures

- Rewritten components and three thin VSTO hosts, with no legacy application logic in the active build.
- Office interop types embedded in host assemblies, with a build check rejecting external PIA dependencies. The previous builds required PIAs without bundling or validating them.
- Each host has its own complete output directory. Shared runtime files cannot be overwritten by another host while staging manifests.
- No local edits to Microsoft's VSTO build targets and no broad antivirus exclusions.
- Microsoft VSTO Installer handles manifest/dependency/trust validation. OMNIX does not import root certificates or relax Office trust policy.
- Prerequisites and open Office processes are checked before installed files change. Post-install failure is visible and returns a nonzero status.
- The old registration maintenance task is removed only after identifying its expected OMNIX action, preventing it from restoring obsolete paths after sign-in.
- Provider startup is deferred until workspace use. Office startup does not make model calls.

These address specific risks found in the source. They do not prove the root cause of the user's observed failure without machine evidence.

## Required real-machine acceptance

For each supported Office bitness under test, record the installer version/hash, Windows version and Office executable version. Verify:

1. Installation completes under the intended Windows user. Required Microsoft trust prompts are accepted under existing policy. Cancelled trust prompts report failure.
2. Open Word, Excel and PowerPoint individually. The OMNIX ribbon appears and the workspace is docked to the correct document window.
3. Open a second document window. Both panes operate independently. Close/reopen windows and Office without duplicate panes or stale document edits.
4. Test one actual configured cloud model and one local model, including authentication failure, invalid model, offline operation, cancellation and remote-consent refusal.
5. Capture a small selection, obtain a response, review/apply it and undo it. Change the selection or document before Apply and confirm the write is rejected.
6. Restart Windows and repeat startup. Verify encrypted settings survive and that the retired maintenance task does not rewrite registration.
7. Uninstall/reinstall/upgrade without deleting documents, saved keys or unrelated Office add-ins.
8. For production, obtain a trusted timestamped signing identity and validate consumer endpoint protection behavior.

Unattended component tests and UI renders do not satisfy these gates. `ProductionReleaseApproved` stays false until evidence exists.

## Requirements retained

The documents in `docs/reference/` are preserved requirement history. Their common direction is native Office UI, secure credentials, controlled document access and honest verification. The current implementation retains VSTO/WPF and adds native IPC to meet the later specification. The full agent/tool catalog, streaming, persistent multi-session chat, automated document creation and broad vision capture workflows remain beyond this preview's implemented scope.

Primary deployment references: [Microsoft VSTO deployment](https://learn.microsoft.com/en-us/visualstudio/vsto/deploying-a-vsto-solution-by-using-windows-installer?view=vs-2022), [VSTO Installer and exit codes](https://learn.microsoft.com/en-us/visualstudio/vsto/deploying-an-office-solution-by-using-clickonce?view=vs-2022#create-a-custom-installer), [solution trust](https://learn.microsoft.com/en-us/visualstudio/vsto/trusting-office-solutions-by-using-inclusion-lists?view=vs-2022).
