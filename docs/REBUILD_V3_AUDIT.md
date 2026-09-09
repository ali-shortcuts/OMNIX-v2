# OMNIX v3 Native Rebuild Audit

Branch: `rebuild/omNix-office-native-v3`

## Objective

Rebuild OMNIX as the production Office-native line: Excel + Word + PowerPoint VSTO hosts, shared C#/WPF core, compact task panes, Office-aware context, local-first AI routing, provider abstraction, vision where visual context is actually needed, safe document mutation, and an installer that registers only the supported Office hosts that really exist.

## Architectural decision

`OMNIX-v2` is the authoritative implementation base. The older `OMINIX.exe` repository remains a feature/UX reference only. Its localhost/browser architecture must not be reintroduced into the production path.

## Verified structure already present

- `OMNIX.Core`
- `OMNIX.Excel`
- `OMNIX.Word`
- `OMNIX.PowerPoint`
- native Ribbon XML + VSTO hosts
- per-window Custom Task Panes
- C#/WPF workspace
- provider gateway/adapters
- Ollama / LM Studio / Gemini / Groq / OpenRouter / custom OpenAI-compatible paths
- Office context adapters
- context limiting
- privacy/security/errors/logging/settings/storage/theming/tools
- Inno Setup installer

## First rebuild fixes completed

### 1. All-host post-install verification

The previous verifier tested only Excel. That was insufficient because the product contract is Excel + Word + PowerPoint.

`build/post-install-verify.ps1` now:

- discovers which hosts OMNIX actually registered;
- launches each registered host through COM automation;
- verifies OMNIX appears in `Application.COMAddIns`;
- verifies `Connect=True`;
- performs a controlled `Connect=true` attempt if disconnected to expose the real VSTO load error;
- logs Excel, Word and PowerPoint independently;
- exits non-zero when a registered host fails;
- does not report a green installation when zero Office hosts are registered.

## Critical findings still under rebuild

### P0 — Installer host detection is too narrow

Current host detection relies heavily on per-user Office registry paths under `HKCU\Software\Microsoft\Office\15.0/16.0`. Real Click-to-Run/MSI installations can exist without those exact keys being populated before first launch. Detection must be expanded to executable/App Paths/Click-to-Run registration evidence and tested on x86/x64 Office.

### P0 — Office resiliency cleanup is too broad

The current installer has a routine that can clear Office `Resiliency\DisabledItems` values broadly. Those values can represent unrelated third-party add-ins. OMNIX must never wipe unrelated Office resiliency state. The rebuild must replace this with OMNIX-scoped repair behavior only, or leave opaque disabled-item entries untouched and provide explicit diagnostics.

### P0 — Real Office acceptance remains mandatory

CI compilation cannot prove Ribbon rendering or VSTO activation in a consumer Office installation. Final acceptance requires a real Windows + Office run for all installed hosts.

### P1 — VSTO runtime bootstrap policy is unstable

Recent commits show experimentation around `vstor_redist.exe`. The final installer must use one documented prerequisite policy based on actual target Office/.NET environments, not repeated heuristic retries. A restart-required state must remain explicit.

### P1 — Self-signed manifest trust is development-grade

Current builds may trust a self-signed certificate in CurrentUser stores. This is acceptable only for development/testing with explicit documentation. Production distribution should use a real signing certificate and should not normalize self-signed root trust as the final product design.

### P1 — Task-pane lifecycle cleanup

The three host services create per-window controllers and panes. Cleanup/disposal on document/window close must be verified to prevent stale controllers, event subscriptions, streaming operations and COM references.

### P1 — Office context vs. "vision"

OMNIX must not treat screenshots as its primary understanding layer. Structured Office context is authoritative:

- Excel: workbook/sheet/selection/values/formulas/tables/charts metadata
- Word: document/selection/paragraphs/headings/tables
- PowerPoint: presentation/slides/shapes/text/notes

Vision is supplemental for charts, slide appearance, embedded images and other visual-only information.

### P1 — Write safety

All write tools must remain allow-listed, scoped and previewed. Destructive or broad mutations require explicit user approval and must preserve native Office undo where possible.

## Rebuild gates

### Gate A — Build integrity

- solution restores/builds on Windows runner
- installer builds
- no browser/Node/local web UI dependency introduced

### Gate B — Installation integrity

- correct Office bitness and hosts detected
- only installed hosts registered
- registry/manifests read back successfully
- no unrelated Office settings modified
- repair/uninstall are idempotent

### Gate C — Runtime integrity

For each registered host:

- OMNIX appears in COMAddIns
- Connect=True
- Ribbon tab appears
- Open Workspace creates one compact pane for the active document window
- close/reopen does not duplicate panes or processes

### Gate D — Context integrity

- Excel selection/context verified
- Word selection/context verified
- PowerPoint slide/selection context verified
- large contexts are bounded

### Gate E — AI integrity

- local provider discovery is asynchronous
- UI works with no Internet
- cloud failure does not break the UI
- provider errors are categorized
- privacy policy is enforced before cloud transmission

### Gate F — Real-machine persistence

For Excel, Word and PowerPoint independently:

1. Install OMNIX.
2. Open host.
3. Verify OMNIX Ribbon.
4. Open workspace.
5. Close host.
6. Reopen host.
7. Verify OMNIX again.
8. Restart Windows.
9. Verify again.

No release-ready claim is allowed until these gates have evidence.

## Anti-drift rules

Do not:

- return to the `OMINIX.exe` localhost/browser architecture;
- bypass Office or Windows security;
- silently enable Office-wide trust settings;
- clear unrelated Office Add-in state;
- claim Office versions as supported without evidence;
- equate UI-offline with local-AI inference;
- claim PASS from compilation alone.

## Release definition

The target product is:

`Install once -> supported Office host registration -> OMNIX Ribbon -> compact native task pane -> structured Office context -> local/cloud AI gateway -> safe tools -> diagnostics -> persistence across restarts.`
