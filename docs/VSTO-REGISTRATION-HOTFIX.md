# OMNIX VSTO Registration Hotfix

Root cause of the preview that installed files but did not appear in Excel/Word/PowerPoint:

The previous installer wrote OMNIX under versioned Office keys such as:

`HKCU\Software\Microsoft\Office\16.0\Excel\Addins\OMNIX`

VSTO application-level add-ins are discovered from the versionless application path:

`HKCU\Software\Microsoft\Office\Excel\Addins\OMNIX`

(and the equivalent Word / PowerPoint paths).

This hotfix:

- registers Excel, Word and PowerPoint at the canonical versionless VSTO Addins path;
- removes the old OMNIX-only versioned registration keys;
- keeps `LoadBehavior=3` and the installed `file:///...vsto|vstolocal` manifest;
- updates post-install verification to inspect the canonical path and require automatic `Connect=True`;
- updates background registration maintenance to repair only canonical OMNIX keys;
- removes both canonical and legacy OMNIX keys during uninstall;
- leaves Office Resiliency, DisabledItems and Trust Center unchanged.

This document is intentionally committed with the development-preview publish marker. The prerelease workflow remains fail-closed until the exact commit passes build, architecture, and runtime gates.