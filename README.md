# OMNIX — AI Office Bridge

**OMNIX** is a bridge between Microsoft Office (Excel, Word, PowerPoint) and AI models — local and cloud, including Vision — that lives directly inside Office as a **VSTO add-in** (C# / WPF). Download ONE `.exe`, run it, open Excel — the OMNIX ribbon tab is simply there.

> This repository is built against a single source of truth: [`OMNIX-MASTER-SPEC.md`](./OMNIX-MASTER-SPEC.md). Every architectural decision maps to it — see [docs/SPEC-COMPLIANCE.md](./docs/SPEC-COMPLIANCE.md).

```
Run the single .exe installer (per-user, no admin knowledge needed)
      ↓
Open Excel / Word / PowerPoint
      ↓
The OMNIX ribbon tab is there (right after Home)
      ↓
Click "Open Workspace" → docked side panel next to your document (not full-screen)
      ↓
Chat with AI — text or images (Vision) — with context of the current document
      ↓
Close, reopen, even restart Windows → everything stays
```

## Highlights

- **Real VSTO add-in** — three thin hosts (`OMNIX.Excel`, `OMNIX.Word`, `OMNIX.PowerPoint`) + one shared core (`OMNIX.Core`). No browser, no web app, no Node.js — WPF/C# only (Ironclad rules of the spec).
- **Docked Task Pane** — `CustomTaskPanes` docked right, 360 px default, resizable, width-clamped so it never covers your document. One pane + one chat context per document window.
- **AI Gateway** — the UI never talks to providers directly. The gateway routes Local-first, enforces Privacy Mode *before* every cloud call, streams tokens word-by-word, supports real cancellation (Stop truly aborts the HTTP request), retries transient network failures with backoff and suggests failover after repeated provider errors.
- **Providers** — Ollama (11434), LM Studio (1234), Google Gemini, Groq, OpenRouter (dynamic model list), and any OpenAI-compatible custom endpoint.
- **Vision** — chart/slide capture to in-memory PNG (temporary file deleted immediately), image attachments from the document or disk, and clear messaging when a model cannot accept images.
- **Whitelisted tools only** — read tools (`read_selection`, `read_document`, `read_presentation`, `capture_chart_as_image`, `capture_slide_as_image`) and write tools (`write_to_cell`, `insert_formula`, `rewrite_selected_text`, `insert_slide`, `add_speaker_notes`, `highlight_range`). Write tools always show a **before/after preview** and require your confirmation; changes are undoable with **Ctrl+Z** via native Office undo.
- **Privacy Mode** (default: **Ask before sending**) — `Local Only` / `Cloud Allowed` / `Ask before sending`, enforced in the Gateway layer, not only in the UI.
- **DPAPI-encrypted API keys** — stored in `%LOCALAPPDATA%\OMNIX\settings.dat`; never plain text, never logged.
- **Prompt-injection defense** — document content is always wrapped as untrusted data and never treated as instructions; suspicious payloads add an explicit guard reminder and are logged.
- **Honest errors** — categorized error codes (`NETWORK_ERROR`, `AUTH_ERROR`, `MODEL_ERROR`, `TIMEOUT`, …) with technical details and suggested fixes; never a generic "check your internet".

## Repository layout

```
OMNIX.sln
src/
  OMNIX.Core/          # everything shared: context engine, gateway, providers,
                       # tools, storage, theming, localization, WPF workspace UI
  OMNIX.Excel/         # thin VSTO host (ribbon XML + per-window task panes)
  OMNIX.Word/          # thin VSTO host
  OMNIX.PowerPoint/    # thin VSTO host
installer/
  installer.iss        # Inno Setup: per-user install, office detection, registry,
                       # cert trust, DisabledItems cleanup, install-debug.log
build/
  build.bat            # local one-click build (restore → msbuild → installer)
  create-signing-cert.ps1, package.ps1, ensure-vsto-sdk.ps1, defender-check.ps1
.github/workflows/build.yml   # windows-latest CI: build → single exe → release
docs/                 # architecture, install guide, CI verification, spec compliance
```

## Building

### GitHub Actions (recommended)
Push to GitHub; the included workflow builds on `windows-latest`, produces `OMNIX-Setup-1.0.0.exe` and attaches it to a Release on `v*` tags. Details: [docs/CI-VERIFICATION.md](./docs/CI-VERIFICATION.md).

### Local (Windows)
Requirements: Visual Studio 2022 with **.NET desktop development** + **Office development (VSTO)** workloads.

```
build\build.bat
```
Output: `installer\Output\OMNIX-Setup-1.0.0.exe`.

## Installing (end users)

1. Download `OMNIX-Setup-1.0.0.exe` from Releases — one file, nothing else.
2. Run it. Office is closed best; the installer detects your Office bitness and which apps you actually have.
3. Open Excel/Word/PowerPoint → the **OMNIX** tab → **Open Workspace**.
4. Open **Settings**, pick a provider, paste an API key (encrypted with DPAPI), test the connection.
5. If Windows SmartScreen shows "Windows protected your PC": More info → Run anyway (see honesty notes below).

Full guide + troubleshooting: [docs/INSTALL.md](./docs/INSTALL.md).

## Honesty notes (from the spec — we keep them visible)

- **Unsigned installer**: the shipped build uses a *temporary self-signed* certificate for the VSTO manifests. Until a real Authenticode certificate is bought (spec §10.2), SmartScreen may warn. The manifest certificate is imported into your *CurrentUser* TrustedPublisher + Root stores during install — no admin needed — so Office accepts the add-in silently.
- **Defender test**: CI runs a real scan with real-time protection ON and publishes `defender-report.txt`. That is CI-level evidence; consumer-machine behavior still needs human verification (spec Rule 9).
- **Per-user install**: each Windows user installs OMNIX separately (spec §10.4 documents this limitation).
- **CI cannot click Office**: a green CI build proves compilation + packaging; the *acceptance* is a human seeing the OMNIX tab inside real Office (spec §12) — that screenshot is the milestone proof.

## Chat history & data

- Settings + keys: `%LOCALAPPDATA%\OMNIX\settings.dat` (DPAPI-encrypted)
- Logs: `%LOCALAPPDATA%\OMNIX\logs\` (`startup-debug.log`, `gateway-debug.log`, `ui-debug.log`, `install-debug.log`)
- Chat history: `%LOCALAPPDATA%\OMNIX\history\` — per document, capped (default 500 messages / 30 days, configurable)

## License

MIT — see [LICENSE](./LICENSE).

---

## About

**Powered by Mr Ali**

Created and developed by Mr Ali, an independent developer building practical digital tools, automation solutions, and useful projects. Follow the channels above for updates, new projects, and useful content.

| Channel | Link |
| --- | --- |
| Email | mailto:Ali.hekmati2026@gmail.com |
| Telegram | https://t.me/Mr_Ali_2025 |
| Telegram Channel | https://t.me/Ali_shortcuts |
| Facebook | https://www.facebook.com/AliShortcuts |
| TikTok | https://www.tiktok.com/@ali_shortcuts |
| Instagram | https://www.instagram.com/ali_shortcuts |
| YouTube | https://www.youtube.com/@Ali_Shortcuts |
