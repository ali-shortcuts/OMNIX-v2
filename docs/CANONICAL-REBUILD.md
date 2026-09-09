# OMNIX Canonical Rebuild

`main` is the single canonical native OMNIX Office code line.

The obsolete installer generations used an incorrect versioned VSTO registration path. The canonical rebuild uses the Microsoft host-scoped application-level add-in path:

- `HKCU\Software\Microsoft\Office\Excel\Addins\OMNIX`
- `HKCU\Software\Microsoft\Office\Word\Addins\OMNIX`
- `HKCU\Software\Microsoft\Office\PowerPoint\Addins\OMNIX`

Installer, repair/maintenance, post-install verification, and real-machine acceptance all use this same registration model. Legacy versioned OMNIX keys are cleanup-only.

Development previews may publish from `main` only after exact-head build, architecture-contract, and runtime acceptance workflows pass. The verified replacement preview `v3.0.0-dev.12` replaced the obsolete `v1.0.9` and `v3.0.0-dev.3` releases.

Do not revive the old localhost/browser-oriented OMNIX architecture or the legacy versioned Office registration model.

Production approval still requires real Excel/Word/PowerPoint runtime evidence, restart persistence, provider/local-AI validation, consumer security validation, and trusted timestamped Authenticode signing.
