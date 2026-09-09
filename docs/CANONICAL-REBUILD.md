# OMNIX Canonical Rebuild

This branch is the canonical native OMNIX Office rebuild.

The obsolete installer generations used an incorrect versioned VSTO registration path. The current rebuild uses the Microsoft host-scoped application-level add-in path:

- `HKCU\Software\Microsoft\Office\Excel\Addins\OMNIX`
- `HKCU\Software\Microsoft\Office\Word\Addins\OMNIX`
- `HKCU\Software\Microsoft\Office\PowerPoint\Addins\OMNIX`

Installer, repair/maintenance, post-install verification, and real-machine acceptance all use this same registration model. Legacy versioned OMNIX keys are cleanup-only.

A development preview may publish only after exact-head build, architecture-contract, and runtime acceptance workflows pass. The release workflow then retires only the exact obsolete releases `v1.0.9` and `v3.0.0-dev.3`.

Production approval still requires real Excel/Word/PowerPoint runtime evidence, restart persistence, provider/local-AI validation, consumer security validation, and trusted timestamped Authenticode signing.
