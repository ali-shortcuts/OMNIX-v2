# OMNIX v4 — Cleanroom Rebuild

This branch is a real cleanroom rebuild. Previous OMNIX implementation files are **not** carried forward into this source tree.

## Product contract

OMNIX is a native Microsoft Office AI bridge for supported Windows desktop versions of Excel, Word, and PowerPoint.

- Native C#/.NET Framework code.
- WPF workspace hosted as a docked Office task pane.
- Three thin Office hosts: Excel, Word, PowerPoint.
- One shared Core: context, AI gateway, provider routing, privacy, secure storage, diagnostics.
- Local AI and cloud/custom providers are abstracted behind one provider contract.
- Office document content is always treated as untrusted data.
- AI never receives unrestricted shell, registry, filesystem, or process control.
- Cloud sends are blocked by the gateway in Local Only mode.
- API keys are stored with Windows DPAPI, never plaintext.
- No browser/Node.js/localhost web app is the primary UI.

## Current cleanroom phase

The cleanroom source tree is being rebuilt in this order:

1. Shared Core contracts and security boundaries.
2. Office context adapters.
3. WPF workspace shell.
4. Excel/Word/PowerPoint host integration.
5. Provider adapters and streaming.
6. Installer, Office discovery, registration, repair, uninstall.
7. CI build gates.
8. Real Windows + Office acceptance testing.

Nothing is called production-ready until the exact installer has passed real Excel, Word, and PowerPoint tests on Windows.
