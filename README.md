# OMNIX — Native AI Bridge for Microsoft Office

OMNIX is a Windows Office AI bridge: a native **C# / WPF / VSTO** add-in that connects **Excel, Word and PowerPoint** to local AI runtimes, cloud providers and custom OpenAI-compatible endpoints from one docked workspace inside Office.

> **Release status:** active v3 rebuild. The code compiles and the development installer is produced in CI, but this repository does **not** call the current branch production-ready until the real-machine release gates in [issue #53](https://github.com/ali-shortcuts/OMNIX-v2/issues/53) pass. A green hosted CI build is not a substitute for opening real desktop Excel/Word/PowerPoint.

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
  → register only OMNIX-owned Office add-in keys
  → preserve shared Office Resiliency state
  → perform post-install diagnostics
```

OMNIX does **not** clear shared `DisabledItems`/`CrashingAddinList` state to force itself enabled. It does not bypass Trust Center or organizational Office policy.

### Development manifest trust

Current CI development builds use a temporary development manifest certificate. The installer only performs development trust handling when the bundled public certificate is classified as self-signed, records its exact thumbprint, and uninstall targets only that recorded development thumbprint. This is **development-only**, not the production trust model.

Production release requires a normal trusted code-signing certificate and valid timestamped Authenticode evidence. `build/sign-production.ps1` signs using an already provisioned certificate in the Windows certificate/key provider; it does not create/export a private key or handle a PFX password.

## Real release gates

The repository contains executable acceptance tooling rather than relying on a “looks okay” checklist:

- `tools/real-office-acceptance.ps1` — Excel/Word/PowerPoint must auto-load OMNIX on two independent launches; diagnostic force-connect cannot turn failure into PASS.
- `tools/real-office-ui-acceptance.ps1` — verifies the real OMNIX Ribbon, `Open Workspace`, and visible WPF task-pane evidence through UI Automation.
- `tools/office-functional-acceptance.ps1` — exercises the installed compiled Core against temporary unsaved Office documents: context/read tools, denied/approved writes and PowerPoint visual capture.
- `tools/real-office-ai-e2e.ps1` — creates a random marker inside a temporary Excel/Word/PowerPoint document and requires that marker to travel through **Office Context → Workspace → AI Gateway/provider → streaming rendered assistant UI**. The prompt itself never contains the marker.
- `tools/full-office-e2e.ps1` — binds the intended installer SHA-256 to install + persistence + UI + functional + real AI round-trip evidence.
- `tools/reboot-persistence-acceptance.ps1` — before/after a normal user-initiated Windows restart; the test never restarts the machine itself.
- `tools/local-offline-acceptance.ps1` — requires public Internet to be observed disconnected while a real Ollama/LM Studio model completes a local chat; the script never changes networking/firewall state.
- `tools/provider-acceptance.ps1` — live model discovery + real streaming provider evidence without copying API keys/prompts/responses into reports.
- `tools/privacy-acceptance.ps1` — deterministic compiled Gateway test proving privacy enforcement occurs before cloud `SendAsync`.
- `tools/lifecycle-acceptance.ps1` — exact-build repair + uninstall lifecycle. It hashes settings and precisely fingerprints shared Office `DisabledItems`, `CrashingAddinList` and `DoNotDisableAddinList` state without dumping their raw values.
- `tools/consumer-security-acceptance.ps1` — requires normal Defender real-time/behavior protection, scans the exact installer, and records a normal SmartScreen UI observation without disabling/bypassing protection.
- `tools/release-readiness.ps1` — base fail-closed evidence aggregator.
- `tools/final-production-gate.ps1` — final production aggregator. It requires exact installer hash binding, all real Office/AI/lifecycle/security evidence, offline/provider/privacy gates and trusted timestamped Authenticode.

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

GitHub Actions builds a **development artifact**. It does not automatically publish a production release merely because a tag exists or CI is green.

## Security and data locations

```text
Settings / protected keys  %LOCALAPPDATA%\OMNIX\settings.dat
Logs                       %LOCALAPPDATA%\OMNIX\logs\
Chat history               %LOCALAPPDATA%\OMNIX\history\
Application                %LOCALAPPDATA%\Programs\OMNIX\
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
  real-evidence-contract-gates.ps1
  final-evidence-contract-gates.ps1
  consumer-security-contract-gates.ps1
  sign-production.ps1
tools/
  real-office-acceptance.ps1
  real-office-ui-acceptance.ps1
  office-functional-acceptance.ps1
  real-office-ai-e2e.ps1
  full-office-e2e.ps1
  reboot-persistence-acceptance.ps1
  local-offline-acceptance.ps1
  provider-acceptance.ps1
  privacy-acceptance.ps1
  lifecycle-acceptance.ps1
  consumer-security-acceptance.ps1
  release-readiness.ps1
  final-production-gate.ps1
```

## Current honesty boundary

Hosted Windows CI can compile VSTO, validate payloads, build the installer, execute deterministic Core privacy tests and scan the development installer. Hosted CI does **not** provide desktop Excel/Word/PowerPoint and therefore cannot produce the real Office/UI/restart evidence required for production.

Do not merge/publish the v3 rebuild as production until issue #53 and `OMNIX-FINAL-PRODUCTION-GATE-002` are satisfied on the intended Windows/Office environment.

## License

MIT — see [LICENSE](./LICENSE).

## About

**Powered by Mr Ali**

OMNIX is developed as an independent Office/AI integration project. Public contact links should be maintained in the product's About view and repository documentation as current, user-approved project metadata.
