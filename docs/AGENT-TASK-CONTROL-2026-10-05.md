# Agent task control — 2026-10-05

Existing VSTO/WPF stack and exact-commit Windows CI retained.

## Delivered and acceptance
- Deterministic request-coverage gate for explicit Excel shop/seller heading above a table, explicit formula creation and quoted sheet names. Missing corresponding native checks reject the plan before writing. This is a limited recognizer, not a universal semantic judge; Word/PowerPoint retain their native checks and playbooks.
- Plan append supports up to 12 new unique steps per segment, 36 cumulative and 60,000 combined JSON characters. Prior executed criteria remain immutable. Native checking still rechecks applied steps after changes. The first plan must cover the explicit guarded obligations.
- At the 24-round boundary, an additional segment is permitted only if the number of currently native-verified steps increased. Three segments maximum, with a 10-minute budget checked between operations and applied to provider waits. No-progress loops stop rather than merely increasing the limit.
- Same-document encrypted checkpoint v2 records original request, host, plan, applied/started step IDs and bounded attempt counts. Exact continue/ادامه commands validate and re-read native state before resuming; saved passed flags are never trusted. Wrong host, corrupt and legacy snapshots do not automatically restore.
- Apply intent is checkpointed immediately before crossing the write boundary. Uncertain non-idempotent/additive writes cannot be blindly replayed; inspect and revise the pending operation to supported idempotent repair while retaining checks. Supported overwrites are explicitly classified. Persistence is still best-effort: a storage failure cannot guarantee recovery after restart.
- Native interactive verification yields between checks and validates cancellation/document scope before each native check, retaining Office STA ownership. A single synchronous COM call still cannot be interrupted.
- A request-local dispatcher heartbeat records gaps >=1 second as metadata only. Host-context reads are timed separately from existing provider/preview/apply/verify timing. This assists freeze diagnosis; it cannot interrupt a stuck COM call or identify its internal stack. Timer runs only during a request and stops on every finally path.

## Regression acceptance
Request obligation rejection, no-formula exception, accepted heading check; append retains prior acceptance, rejects duplicate IDs and 37th step; original-goal/partial resume, wrong-host/unrelated/corrupt rejection, uncertain creation replay blocked; a scripted native-verifiable task continues beyond 24 rounds without duplicating writes while a no-progress fixture stops at 24. Existing privacy, scope, provider, WPF and native contract fixtures remain required.

## Research basis
- Office STA/threading: https://learn.microsoft.com/en-us/visualstudio/vsto/threading-support-in-office?view=vs-2022
- Incremental progress and explicit task state: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- Evaluate environment outcomes: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents

## Remaining work
Full semantic task specification independent of the executing model, versioned document object graph, calibrated per-model business-task evaluation, universal three-host visual grading, selectable fast/step/teaching modes and curated regression fixtures for more Afghan businesses remain partial or missing. New task controls are not model-weight training. Real Excel/Word/PowerPoint interactive tests are needed to prove consumer freeze behavior and layout; hosted CI is insufficient. Do not announce universal Office/Ribbon coverage or completion of every historical request.
