# Visible execution and UI review — 2026-10-05

## Scope and acceptance
Existing .NET Framework 4.8 / VSTO / WPF stack retained. Show real host target navigation and tool stages; paced execution must yield and honour Stop/document scope before crossing the Office boundary. Show tool failure and plan acceptance separately. Existing native postconditions and bounded repair loop remain authoritative.

## Delivered
- Request-local current-operation card with expandable, selectable history limited to 80 metadata-only entries. Each new request clears it; late events cannot update an idle view.
- Real executor events: inspecting, preview, applying, verifying, completed/failed/stopped; explicit plan-verified versus plan-incomplete status. No private reasoning, credentials or document values in the timeline.
- Cancellable pauses before dispatch, before apply and after the resulting target is revealed. New installations default to 800 ms per stage; existing user settings preserved. Settings expose 100–2000 ms stage pause; disabling paced mode still yields briefly for painting/cancellation. Network inference is not artificially slowed.
- Actual host selection and existing relevant Ribbon-tab navigation retained. Object Model operations are named as such; no fabricated button clicks. Arbitrary Ribbon/button access is not added.
- Chat keyboard focus border, top-aligned multiline input, stronger bubble/code-comment contrast and clearer borders. Five text/background pairs in each light/dark theme measured above 4.5:1 (minimum 4.57:1). This is pair-level validation, not a claim of complete WCAG conformance.
- Afghanistan business playbook: configured locale/explicit user choice, Dari/AFN, separate shop heading, numeric types, stable IDs, supplied date convention, reconciled totals and stock. Unknown prices/taxes/calendar conversions are not invented. Gold purity is not multiplied twice. This is business-layout guidance, not a legal/accounting certification or a universal template for every Afghan industry.
- Regression acceptance covers ordered progress, failure reporting, cancellation before read, observer failure isolation, bounded WPF history, stale idle events and clearing per request. Existing plan/postcondition/tool transport tests still run.

## Research
- Microsoft Office STA/threading: https://learn.microsoft.com/en-us/visualstudio/vsto/threading-support-in-office?view=vs-2022 — do not move arbitrary Office COM operations to worker threads; use asynchronous waits and bounded work on the owning thread.
- Anthropic agent feedback/stopping conditions: https://www.anthropic.com/engineering/building-effective-agents — use actual tool results and bounded iteration; finish when acceptance passes rather than edit forever.
- W3C contrast rationale: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html — normal text pair target 4.5:1.
- Da Afghanistan Bank currency: https://www.dab.gov.af/Banknote — basis for local currency labeling; no current exchange rate is embedded.

## Unproven and missing
Hosted CI cannot demonstrate smoothness, actual Ribbon appearance or responsiveness of a long synchronous COM operation on a consumer Office installation. Stop is honoured between operations and during waits; it cannot pre-empt an in-flight COM call. Full Ribbon coverage, every Office formula/version and model weight training remain outside this change. A real Excel/Word/PowerPoint interactive acceptance run is still required before calling this production-ready.
