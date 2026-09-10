# OMNIX repository audit and consolidation

Audit date: 2026-09-10. Account: `ali-shortcuts`.

## Inventory and decision

Two related repositories were found in the connected account and owner-scoped repository searches. This inventory does not claim visibility into private repositories outside the connection's access.

| Repository | Audited source commit | Implementation | Decision |
| --- | --- | --- | --- |
| [OMNIX-v2](https://github.com/ali-shortcuts/OMNIX-v2) | `414df6c13143c49950f987c39f91b3d5304d9f3c` | C#/.NET Framework 4.8, WPF, three VSTO add-ins, Inno Setup | Continue the native product here |
| [OMINIX.exe](https://github.com/ali-shortcuts/OMINIX.exe) | `ca53620322df6ef3ce9776be873928cf7eee033a` | React/Vite/Express, Office.js manifest, .NET 8 console launcher | Historical feature/UI reference |

This follows the native repo's existing `CANONICAL-REBUILD.md` decision and the owner's September 3 master specification requiring the primary workspace inside desktop Office. Creating a third repository would duplicate the implementation and release history again. No repository deletion is needed to establish one canonical development line.

## Why the old executable is insufficient

These findings come from source inspection, not a Windows execution of that executable:

- `windows/src/Program.cs` starts `npm start` or `node dist/server.cjs`, then opens `http://localhost:3000` in the browser. It prints that the engine is active even after startup polling is exhausted.
- Its `RegisterOfficeAddin` function only copies `manifest.xml` to a folder; that function does not register a native VSTO add-in or prove that an Office Ribbon is installed.
- `.github/workflows/build-exe.yml` builds the web app but packages only the executable, manifest and batch script. The delivered archive does not include the server bundle, frontend assets, Node runtime or npm dependencies needed by the launcher's startup commands. The individually attached executable also lacks the neighboring manifest.
- `src/components/DiagnosticsModal.tsx` initializes Office, TLS and credential-vault checks with hard-coded `passed` values. Those labels are not runtime evidence.
- `src/services/aiService.ts` persists its provider settings through `localStorage`; the claimed Windows credential-vault check is not demonstrated by that path.

The presence of an `.exe` release asset therefore does not establish that the old package is a complete or working native Office application.

## Native application structure

The native line has one shared compiled Core library and Excel, Word and PowerPoint host projects. The hosts provide Ribbon commands and per-window WPF task panes. Core contains context adapters, bounded history, provider routing, credential protection, privacy checks and Office tool execution. The user interface does not need a local web server.

The AI Core currently runs inside each Office host process. A separate background Core process with authenticated named-pipe IPC, broader agent planning and cross-Office transactions from the larger specification are not established by this implementation. Offline inference also requires an installed local model/runtime; a responsive offline interface alone is not proof of local inference.

## Defects corrected in this change

| Finding | Correction |
| --- | --- |
| Existing install directory and registrations removed before VSTO prerequisites completed | Move prerequisite checks/install into `PrepareToInstall`; stop on failure/restart; let Inno Setup replace tracked files without deleting the install tree |
| Open Office processes could be acknowledged without actually closing them | Recheck before installation and stop with a save-and-close instruction |
| No explicit .NET Framework 4.8 prerequisite check | Check the actual target framework before modifying the application |
| 64-bit registry/constants used on 32-bit Windows; stale App Paths entry could hide a valid alternative | Guard 64-bit probes and check candidate executable paths independently |
| Failed or missing post-install verification could still return success to automation | Require the verifier and return custom setup exit code `10` on verification failure; support suppressed dialogs |
| Model catalog truncated at 300; manual selections could disappear | Keep the bounded catalog up to 5,000 entries and preserve the manual model |
| Late provider operations could populate another provider's controls | Cancel superseded operations, reject stale results and use separate diagnostic adapters |
| Model-catalog access mistaken for a working selected model | Test an actual text completion without depending on `/models`, with privacy enforcement before send |
| Complete custom `/chat/completions` URL had the suffix appended twice | Normalize base, model-catalog and completion URLs consistently; reject unsupported query credentials |
| Creator Telegram link contradicted the owner's corrected specification | Update the product and README to `@Ali_silent0` |

## Validation and honest release status

The changes add `tools/provider-diagnostics-acceptance.ps1`, which tests the compiled Core against deterministic provider doubles: manual models without catalogs, synthetic-only request content, empty responses, authentication failures, privacy denials, cancellation, large model lists and URL validation. No real cloud provider or Office document is used in those tests.

The Windows build workflow must run that script, the existing privacy test, solution compilation and installer compilation. Its Office-less installer test also checks that a pre-existing install marker survives preflight rejection and that no Office payload was written. Existing architecture and request-budget/error-redaction/image checks remain required.

Passing these checks supports a **Development Preview**. Actual Office loading, Ribbon/task-pane interaction, clean-machine installation, restart persistence, live providers, offline local-model inference and trusted production signing still require the existing real-machine gates. This audit does not report those unexecuted checks as passed.

## Implementation references

- [Microsoft: registry entries for VSTO add-ins](https://learn.microsoft.com/en-us/visualstudio/vsto/registry-entries-for-vsto-add-ins?view=visualstudio) — supports the host-scoped registration path.
- [Inno Setup event functions](https://jrsoftware.org/ishelp/topic_scriptevents.htm) — prerequisite stopping/restart handling and custom completion exit codes.
- [Inno Setup framework detection](https://jrsoftware.org/ishelp/topic_isxfunc_isdotnetinstalled.htm) — detects the required .NET Framework version.
