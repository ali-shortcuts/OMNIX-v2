# OMNIX — Native AI Bridge for Microsoft Office

OMNIX is a Windows Office AI bridge: a native **C# / WPF / VSTO** add-in that connects **Excel, Word and PowerPoint** to local AI runtimes, cloud providers and custom OpenAI-compatible endpoints from one docked workspace inside Office.

> **Release status:** active v3 rebuild. The code compiles and development previews are produced from exact-head CI, but this repository does **not** call the current branch production-ready until the real-machine release gates in [issue #53](https://github.com/ali-shortcuts/OMNIX-v2/issues/53) pass. A green hosted CI build is not a substitute for opening real desktop Excel/Word/PowerPoint.

Download the newest **Development Preview** `.exe` from [GitHub Releases](https://github.com/ali-shortcuts/OMNIX-v2/releases). This is the canonical native Office repository. The separate `OMINIX.exe` repository contains an older browser/server prototype; its executable is not this native installer. See the [repository audit and consolidation decision](docs/REPOSITORY-AUDIT-2026-09-10.md).

The installer checks Office, .NET Framework 4.8 and VSTO prerequisites before replacing existing files. Close all Office applications before installing. A prerequisite restart stops the upgrade so the existing installation is preserved. Post-install verification failure returns exit code `10`, including in silent mode.

In Settings, a manually entered model is kept even if a server has no model catalog. **Test Connection** sends a small text request to that selected model, subject to the configured privacy mode; provider usage charges may apply. A successful text test does not claim Vision support.

## Product contract

```text
Microsoft Office
  Excel / Word / PowerPoint
        │
        ▼
Native OMNIX Ribbon + docked WPF Workspace
        │
        ▼
Office Context Engine
  structured selection/document/slide context
  + bounded visual capture when needed
        │
        ▼
Privacy Gate + Context Limiter + Whitelisted Tool Executor
        │
        ▼
OMNIX AI Gateway
        │
        ├── Local AI: Ollama / LM Studio
        ├── Cloud: Gemini / Groq / OpenRouter / Mistral / Hugging Face / Cerebras
        └── Custom OpenAI-compatible endpoint
```

OMNIX is the bridge, not the destination. The user works in Office; OMNIX obtains the minimum relevant Office context, routes it according to the privacy policy, streams the model response back into the side panel and exposes only narrowly scoped Office actions.

## What the rebuilt version contains

- **Three native Office hosts** — `OMNIX.Excel`, `OMNIX.Word`, `OMNIX.PowerPoint` share one `OMNIX.Core`.
- **No browser/Web UI/Node.js dependency** for normal operation. The main UI is WPF hosted in a VSTO Custom Task Pane.
- **Compact docked workspace** — designed around a narrow Office side panel rather than a web page squeezed into Office.
- **Per-window isolation** — each Office document window owns its own workspace controller, AI gateway, provider state, cancellation token, cloud-consent session and conversation context.
- **Streaming + cancellation** — provider responses stream into the rendered chat; Stop cancels the active request.
- **Structured Office context** — bounded Excel ranges/values/formulas, Word selection/document structure, and PowerPoint slide/presentation text are read through host adapters.
- **Vision** — current Office view/selection capture, Excel chart capture and PowerPoint slide capture can be attached to Vision-capable models. The model is explicitly told not to claim visibility outside the captured/structured scope.
- **Local AI** — Ollama and LM Studio are discovered in the background and can be preferred when available.
- **Cloud/custom providers** — Gemini, Groq, OpenRouter, Mistral AI, Hugging Face Inference Providers, Cerebras and custom OpenAI-compatible endpoints.
- **Dynamic provider behavior** — live model discovery is used where supported. OpenRouter runtime acceptance prefers `openrouter/free` and current `:free` routes before paid routes. Free/free-tier/trial status is treated as provider/account dependent rather than guaranteed forever.
- **Privacy modes** — `Local Only`, `Cloud Allowed`, `Ask Before Sending`. Enforcement occurs in the AI Gateway before a cloud provider's send path, not just in the UI.
- **DPAPI-protected API keys** — provider keys are protected for the current Windows user in `%LOCALAPPDATA%\OMNIX\settings.dat`; plaintext keys are not written to logs or reports.
- **Untrusted Office data boundary** — document content is data, never executable instructions. Prompt-like content from a workbook/document/presentation remains inside the untrusted-data boundary.
- **Whitelisted Office tools only** — no unrestricted PowerShell, CMD, registry, process-control or arbitrary filesystem tool is exposed to the model.
- **Fail-closed writes** — a write tool requires a before/after preview and explicit user approval. If the confirmation callback is unavailable or the user denies the preview, no write is applied. Runtime acceptance tests this behavior against temporary Office documents.
- **Categorized errors** — network/auth/model/privacy/provider/local-runtime failures are kept distinct instead of turning every failure into “check your Internet.”
- **Bounded storage** — chat history is per-document-key, bounded by configured age/count limits, and raw attached Office screenshots are not persisted into history.

## Provider matrix

| Provider | Kind | API key | Notes |
| --- | --- | --- | --- |
| Ollama | Local | No | Local models discovered from the runtime |
| LM Studio | Local | No | OpenAI-compatible local runtime |
| Google Gemini | Cloud | Yes | Model/capability availability is account/API dependent |
| Groq | Cloud | Yes | Free-plan eligibility/limits are account dependent |
| OpenRouter | Cloud | Yes | Supports live discovery; free router/free routes are preferred when available |
| Mistral AI | Cloud | Yes | Account/free-mode eligibility can change |
| Hugging Face Inference Providers | Cloud | Yes | Routes/models/credits are account and provider dependent |
| Cerebras | Cloud | Yes | Access/trial/quota are account dependent |
| Custom OpenAI-compatible | Local or Cloud | Optional | User supplies base URL, model and optional key |

OMNIX does not hard-code a permanent promise that a third-party cloud model is “free.” Provider availability, quotas and pricing can change independently of this repository.

## Office integration scope

The native v3 architecture targets **Windows desktop Microsoft Office environments that support VSTO**. The installer detects the Office generation/platform and only registers hosts found on the machine. Compatibility must be reported from evidence, not assumed.

Use these support states when documenting a tested environment:

```text
UNSUPPORTED / LEGACY / PARTIAL / SUPPORTED / FULLY_TESTED
```

`FULLY_TESTED` is reserved for a specific Office/Windows environment with real-machine evidence. OMNIX does not claim that one VSTO build universally supports every historical Office version or non-Windows Office.

## Installation model

The development installer is an Inno Setup per-user installer. Its supported path is:

```text
intentional user install
  → detect Office / host apps / platform
  → ensure official Microsoft VSTO Runtime prerequisite when genuinely required
  → copy validated Excel + Word + PowerPoint + Core payload
  → install OMNIX-build-identity.json for exact source/payload verification
  → register only OMNIX-owned Office add-in keys
  → preserve shared Office Resiliency state
  → perform post-install diagnostics and payload-identity verification
```

OMNIX does **not** clear shared `DisabledItems`/`CrashingAddinList` state to force itself enabled. It does not bypass Trust Center or organizational Office policy.

### Installed build identity

Current installer payloads contain `OMNIX-build-identity.json`. It records the exact source commit and SHA-256 values for `OMNIX.Core.dll`, `OMNIX.Excel.dll`, `OMNIX.Word.dll`, and `OMNIX.PowerPoint.dll`.

Post-install verification and the canonical real-machine evidence runner re-hash those files and fail closed if the identity is missing, source-mismatched, or any primary assembly differs. Bound real-machine evidence carries `PayloadIdentitySha256` so the final production gate can reject stale or cross-build report replay.

### Development manifest trust

Current CI development builds use a temporary development manifest certificate. The installer only performs development trust handling when the bundled public certificate is classified as self-signed, records its exact thumbprint, and uninstall targets only that recorded development thumbprint. This is **development-only**, not the production trust model.

Production release requires a normal trusted code-signing certificate and valid timestamped Authenticode evidence. `build/sign-production.ps1` signs using an already provisioned certificate in the Windows certificate/key provider; it does not create/export a private key or handle a PFX password.

## Real release gates

The canonical operator runbook is [docs/PRODUCTION-ACCEPTANCE.md](docs/PRODUCTION-ACCEPTANCE.md).

For Office E2E, local-offline AI, live-provider, and restart evidence, the production entrypoint is:

```powershell
.\tools\bound-real-acceptance.ps1
```

The lower-level scripts (`real-office-acceptance.ps1`, `real-office-ui-acceptance.ps1`, `office-functional-acceptance.ps1`, `real-office-ai-e2e.ps1`, `full-office-e2e.ps1`, `reboot-persistence-acceptance.ps1`, `local-offline-acceptance.ps1`, and `provider-acceptance.ps1`) are implementation harnesses. They remain useful for debugging, but raw PASS reports from them are not sufficient production evidence.

The bound runner executes the underlying harness, requires fresh evidence, validates the installed build identity and all four primary assembly hashes, verifies the source commit, and only then adds the `EvidenceBinding` consumed by the final production gate.

Other mandatory release components include:

- `tools/privacy-acceptance.ps1` — deterministic compiled Gateway proof that privacy enforcement occurs before cloud send.
- `tools/lifecycle-acceptance.ps1` — exact-installer repair/uninstall lifecycle evidence while preserving shared Office recovery state.
- `tools/consumer-security-acceptance.ps1` — real consumer-machine Defender/SmartScreen evidence without weakening protection.
- `build/sign-production.ps1` — trusted production Authenticode signing using a provisioned code-signing certificate and timestamp service.
- `tools/final-production-gate.ps1` — canonical final fail-closed aggregator. It checks exact installer identity, bound real Office/restart/offline/provider evidence, lifecycle, security, privacy, real task-pane evidence and trusted timestamped Authenticode.

The final production result must be:

```json
{
  "TestId": "OMNIX-FINAL-PRODUCTION-GATE-002",
  "FailureCount": 0,
  "OverallPass": true
}
```

Anything else is not a production release.

## Building

Local build prerequisites:

- Windows
- Visual Studio 2022 with .NET desktop development
- Visual Studio Tools for Office / Office development build targets
- .NET Framework 4.8 targeting pack
- Inno Setup for installer compilation (the CI workflow provisions it)

Local entry point:

```bat
build\build.bat
```

GitHub Actions builds a **development artifact**. Preview publication is separate from production approval and is allowed only through the repository's explicit development-preview workflow/provenance contract. A tag or green CI alone does not create a production release.

See [docs/CI-VERIFICATION.md](docs/CI-VERIFICATION.md) for the exact boundary of hosted CI evidence.

## Security and data locations

```text
Settings / protected keys  %LOCALAPPDATA%\OMNIX\settings.dat
Logs                       %LOCALAPPDATA%\OMNIX\logs\
Chat history               %LOCALAPPDATA%\OMNIX\history\
Application                %LOCALAPPDATA%\Programs\OMNIX\
Build identity              %LOCALAPPDATA%\Programs\OMNIX\OMNIX-build-identity.json
```

Logs and acceptance reports are designed not to contain API keys or full private Office documents. Real release evidence stores hashes/status/timing where possible instead of copying sensitive content.

## Repository layout

```text
OMNIX.sln
src/
  OMNIX.Core/
  OMNIX.Excel/
  OMNIX.Word/
  OMNIX.PowerPoint/
installer/
  installer.iss
build/
  build-with-fallbacks.ps1
  package.ps1
  contract-gates.ps1
  final-evidence-binding-contract-gates.ps1
  consumer-security-contract-gates.ps1
  sign-production.ps1
tools/
  bound-real-acceptance.ps1
  real-evidence-binding.ps1
  full-office-e2e.ps1
  local-offline-acceptance.ps1
  provider-acceptance.ps1
  reboot-persistence-acceptance.ps1
  lifecycle-acceptance.ps1
  consumer-security-acceptance.ps1
  privacy-acceptance.ps1
  final-production-gate.ps1
docs/
  PRODUCTION-ACCEPTANCE.md
  CI-VERIFICATION.md
```

## Current honesty boundary

Hosted Windows CI can compile VSTO, validate payloads, build the installer, execute deterministic runtime/security contracts, prove installed-payload tamper detection, create exact-source packages, and publish a provenance-bound **development preview** when explicitly requested.

Hosted CI does **not** provide the real desktop Office/consumer environment required for production Office/UI/restart/live-provider/consumer-security evidence. A Defender scan on a hosted runner also does not replace the consumer-security gate when normal real-time protection is not enabled on that runner.

Do not publish or label the v3 rebuild as production until issue #53 and `OMNIX-FINAL-PRODUCTION-GATE-002` are satisfied for the intended signed installer on the intended Windows/Office environment.

## License

MIT — see [LICENSE](./LICENSE).

## About

**Powered by Mr Ali**

Creator/support: [Telegram @Ali_silent0](https://t.me/Ali_silent0) · [Telegram channel](https://t.me/Ali_shortcuts) · [Email](mailto:Ali.hekmati2026@gmail.com)

OMNIX is developed as an independent Office/AI integration project. Public contact links should be maintained in the product's About view and repository documentation as current, user-approved project metadata.
