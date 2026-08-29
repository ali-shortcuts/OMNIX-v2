# CI Verification — what a green build proves, and what still needs a human

The OMNIX spec (Section 12) is explicit: code and green CI are **not** acceptance.
This document states exactly what the CI proves and what a human must verify.

## What a green CI run proves

1. `OMNIX.sln` compiles under MSBuild on `windows-latest` with .NET Framework 4.8 and the VSTO SDK.
2. ClickOnce/VSTO manifests are signed (temporary self-signed cert created in CI).
3. All three hosts produce `.vsto` + `.dll.manifest` + DLLs.
4. Inno Setup produces ONE `OMNIX-Setup-1.0.0.exe`.
5. Windows Defender (real-time protection ON) scanned the installer; the honest result is in `defender-report.txt`.

## First-run risk areas (honest, per Rule 9/12)

This codebase was written **without executing a Windows build**. The following
spots are the most likely first-build friction points, all with mechanical fixes:

| Area | Risk | Fix if MSBuild complains |
| --- | --- | --- |
| `ThisAddIn.Designer.cs` (×3) | Base-ctor argument shape of `AddInBase` differs in your SDK version | The error message prints the expected signature — align the 6 base args (this is exactly what VS regenerates) |
| VSTO targets path | Runner has `OfficeTools` vs `VisualStudioToolsForOffice` folder | Both candidates are imported with `Exists` guards; `ensure-vsto-sdk.ps1` installs the SDK if absent |
| PIA resolution | `$(VSTOPIAPath)` folder missing → references unresolved | Install the Office dev tools workload (workflow does it) or set `/p:VSTOPIAPath=…` |
| XAML Page build in a classic classlib | Very stable since MSBuild 4.0 — unlikely to fail | If it does, add `{60dc8134-eba5-43b8-bcc9-bb4bc16c2548}` to OMNIX.Core `ProjectTypeGuids` |
| Inno PascalScript | Minor syntax/version differences (Inno 6.3+ required for `DownloadPage`) | Error messages include line numbers; choco always installs the latest 6.x |

Debugging tip: the workflow uploads `build/logs/build.binlog` — open it in
[MSBuild Structured Log Viewer](https://msbuildlog.com/).

## Human acceptance checklist (spec Section 12 + Phase 2 output)

- [ ] Download the single `.exe` from GitHub Release; run it **without any other file**.
- [ ] Installer asks nothing unusual; VSTO Runtime UAC only when actually missing.
- [ ] `%LOCALAPPDATA%\OMNIX\logs\install-debug.log` shows every step + VERIFIED lines.
- [ ] `%LOCALAPPDATA%\OMNIX\logs\startup-debug.log` shows the static-ctor line as the FIRST line.
- [ ] OMNIX tab visible in Excel/Word/PowerPoint (only installed hosts) — **attach screenshot**.
- [ ] "Open Workspace" opens a docked right panel (~360 px), document stays interactive.
- [ ] Two workbooks open → two independent panes/contexts.
- [ ] Chat answers stream word-by-word; Stop truly stops (verify with network tool or provider usage page).
- [ ] `write_to_cell` preview → Apply → Ctrl+Z undoes it (Excel native undo).
- [ ] Privacy Mode "Ask before sending" shows the confirmation before the first cloud call.
- [ ] DPAPI check: `settings.dat` contains NO plain-text key (open in editor).
- [ ] Uninstall: no `Addins\OMNIX` keys, no program folder, no leftover certificate.
- [ ] Windows restarted → tab still there (persistence, Phase 20).
- [ ] Windows Defender (default settings, ON): run the installer on a real machine — record any warning honestly (Phase 2.9).

## Word HostPackage note

`ProjectExtensions` (design-time only, ignored by MSBuild) is included for Excel and
PowerPoint with the GUIDs taken from real shipped projects; the Word project omits
this optional block. Visual Studio recreates it automatically on first save.
