# OMNIX Architecture — Layer Map (spec Section 3 → code)

| Spec layer | What it does | Where in code |
| --- | --- | --- |
| 1 — Office Host Layer | Three separate VSTO projects (VSTO does not support multi-host in one project) | `src/OMNIX.Excel`, `src/OMNIX.Word`, `src/OMNIX.PowerPoint` (`ThisAddIn.*`) |
| 2 — Ribbon & Task Pane | Ribbon XML per host (`insertAfterMso="TabHome"`), `CustomTaskPanes.Add` + `ElementHost` (WinForms⇄WPF bridge), docked RIGHT, 360 px, per-window panes | `OmnixRibbon.xml/.cs`, `*TaskPaneService.cs`, `src/OMNIX.Core/Ui/TaskPaneHostControl.cs` |
| 3 — OfficeContextEngine | Per-host adapters produce the shared `OfficeContext` | `src/OMNIX.Core/Context/*` (`ExcelHostAdapter`, `WordHostAdapter`, `PowerPointHostAdapter`, `OfficeContext`, `VstoHostItemResolver`) |
| 4 — Context Limiter | `TokenEstimator` + `Chunker` + `Summarizer`; never sends a whole workbook unfiltered | `src/OMNIX.Core/ContextLimiter/ContextLimiter.cs` |
| 5 — AI Gateway | Single entry point; UI never touches providers; routing Local-first; privacy enforcement; tool loop | `src/OMNIX.Core/AiGateway/AiGateway.cs`, `PrivacyGate.cs` (incl. `ProviderRouter`) |
| 6 — Provider Adapters | Normalized I/O for every provider | `src/OMNIX.Core/AiGateway/Adapters/` (`Gemini`, `Groq`, `OpenRouter`, `Ollama`, `LmStudio`, `CustomOpenAiCompatible`), `Http/OpenAiCompatibleClient.cs`, `Http/SseLineReader.cs` |
| 7 — Tool Executor | EXACT whitelist from the spec; write tools previewed + confirmed; native undo | `src/OMNIX.Core/Tools/Tools.cs` (`ToolNames`), `ToolExecutor.cs` |
| 7.5 — Privacy Mode | LocalOnly / CloudAllowed / AskBeforeSending (default), enforced in the Gateway BEFORE cloud calls | `AiGateway/PrivacyGate.cs` + Settings UI |
| 8 — Storage | DPAPI-encrypted `settings.dat`; JSON chat history with hard caps | `src/OMNIX.Core/Settings/SettingsManager.cs`, `Storage/ChatStorage.cs` |
| 9 — Diagnostics | `ErrorCode` enum exactly as specified; categorized errors with fix hints; file logs | `src/OMNIX.Core/Errors/OmnixErrors.cs`, `Logging/Logger.cs` |

## Installer flow (spec Section 4 → `installer/installer.iss`)

1. Detect Office bitness: ClickToRun `Configuration\Platform` → MSI folder fallback.
2. Detect installed hosts and versions (16.0 / 15.0) — register only what exists.
3. Check VSTO Runtime in both registry views (x64 Office ⇒ x64 runtime required).
4. Per-user copy to `%LOCALAPPDATA%\Programs\OMNIX` (no admin).
5. Clean previous install: folder, `Addins\OMNIX` keys, `Resiliency\DisabledItems`.
6. VSTO Runtime bootstrap (official Microsoft link) — only UAC step, transparent.
7. Import `OMNIX.cer` into CurrentUser `TrustedPublisher` (+ `Root` for self-signed chain).
8. Write `HKCU\...\{version}\{host}\Addins\OMNIX` with `LoadBehavior=3` + `Manifest=file:///…|vstolocal`.
9. Verify by reading back every value → `install-debug.log`.

## Request lifecycle (UI → answer)

```
User message
  → WorkspaceController: history + OfficeContext via adapter
  → ContextLimiter: caps (cells/chars/tokens) + UntrustedData.Wrap
  → AiGateway.ChatAsync:
       ProviderRouter.Resolve (Local available > selected cloud)
       PrivacyGate.EnsureAllowedAsync (BEFORE any cloud call)
       IProviderAdapter.SendAsync (SSE stream, CancellationToken honored)
       RetryPolicy (2x backoff on NETWORK/TIMEOUT) → FailoverPolicy (≥3 failures → suggest)
       ToolCallParser: ```omnix_tool blocks → ToolExecutor (whitelist, preview+confirm for writes)
  → ChatBubble: streaming markdown render (tables, highlighted code, monospace formulas)
```

## Decisions consciously made (per spec 4.4 / section 11)

- Ribbon tab placed **after Home** (`insertAfterMso="TabHome"`), keytip `OX`.
- Theme default **System** (follows Windows), strings centralized in `Localization/Strings.xaml` (English now, Persian RTL-ready — spec 10.7).
- Privacy default **AskBeforeSending** (most conservative).
- Tool protocol uses a portable fenced-block format so ALL providers work the same way (not only ones with native function-calling APIs).
