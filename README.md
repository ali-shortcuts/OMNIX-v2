# OMNIX

Native AI workspace for **Windows desktop Excel, Word and PowerPoint**.

OMNIX 4 is a clean implementation following the review of the previous repositories. This is the canonical repository. The browser-based `OMINIX.exe` repository and obsolete published installers were removed after a verified recovery archive was saved. Earlier code remains recoverable in Git history.

## Install

Download the single `OMNIX-Setup-4.0.0-preview.1.exe` from [Releases](https://github.com/ali-shortcuts/OMNIX-v2/releases). Close Office, run Setup, and respond to Microsoft's add-in trust prompts. Open a document and select **OMNIX → Open Workspace**.

Supported target: Windows 10/11, .NET Framework 4.8, and x86/x64 desktop Office 2013 or newer. Native ARM64 Office, Office for the web, and macOS are outside this build's target. The installer detects Office executable architecture rather than inferring it from Windows.

If Office integration fails, Setup returns an error. Open **OMNIX Diagnostics** from the Start menu. The installation error is also saved under `%LOCALAPPDATA%\OMNIX\v4`. Do not disable Office security or antivirus to make this preview load.

## Use

1. In **Providers**, choose a provider, API base URL and model. Enter an API key if required. Save, then use **Test model**. **Find models** is optional; exact model identifiers can always be entered manually.
2. In **Chat**, capture a selection when useful. Review its preview, then choose whether to include it in the next request. Image input requires a model that supports images.
3. Review an answer in **Review**, edit it if needed, then confirm **Apply to selection**. This preview writes one Excel cell or selected Word/PowerPoint text. It rejects stale selections. Excel formulas require a separate explicit choice.

Providers: Ollama, LM Studio, OpenAI, Google Gemini, Groq, OpenRouter and custom OpenAI-compatible endpoints. No models or free quotas are bundled or promised. Install and start a local model server separately when using Ollama or LM Studio.

## Structure

| Project | Responsibility |
| --- | --- |
| `Omnix.Excel`, `Omnix.Word`, `Omnix.PowerPoint` | Thin VSTO lifecycle, ribbon and per-window task panes |
| `Omnix.Desktop` | Native WPF workspace and guarded Office selection edits |
| `Omnix.Contracts` | Bounded IPC messages and encrypted local storage |
| `Omnix.Gateway` | Per-user named-pipe server, credentials, privacy checks and provider adapters |
| `Omnix.Setup` | Actual Office detection, prerequisites, registration and diagnostics |
| `Omnix.Tests` | Executed Windows component and transport checks |

There is no browser UI, Node.js dependency or Office-to-Core HTTP server. Provider calls use their actual HTTP APIs. The gateway starts on demand and exits after five idle minutes. Keys are encrypted using Windows DPAPI for the current user. Logs contain event categories, not API keys or document content.

## Build and evidence

On a Windows machine with Visual Studio 2022/MSBuild, run `build/build.ps1` in Windows PowerShell. It installs the VSTO SDK if needed, builds signed VSTO manifests, runs compiled component tests, validates the payload, verifies the Microsoft runtime signature and creates an Inno Setup EXE. The installed SDK build targets are used directly.

Each preview includes a SHA-256 file and a manifest bound to the exact source commit. The Windows workflow preserves test reports, native UI renders, payload inventory and build logs.

**A green Windows build is not a real Office acceptance result.** Preview manifests keep real Office runtime, reboot persistence and production signing marked unverified. See [acceptance](docs/ACCEPTANCE.md) for the remaining gates. The master requirements include a broader agent platform; multi-step autonomous plans, bulk document transactions, local model installation and full capability parity are not implemented by this preview.

Support: **@Ali_silent0**.
