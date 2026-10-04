# OMNIX reliability audit — 2026-10-04

## Scope and baseline

Existing VSTO / .NET Framework 4.8 / WPF project, baseline main `198c75a`. No framework migration or model training is part of this patch. The existing catalog contains 521 indexed Excel function names and official links. This is not proof that every function exists in every installed Office version.

Source catalog counts, including extensions: Excel: 86, Word: 64, PowerPoint: 51. These describe implemented capability routes, not comprehensive Office coverage or real-machine acceptance.

## Research and decisions

- Microsoft VSTO threading: https://learn.microsoft.com/en-us/visualstudio/vsto/threading-support-in-office?view=vs-2022 — Office uses STA and its object model is not thread-safe. Keep native work on its owner thread; reduce COM round trips and keep network waits off the UI.
- Microsoft Excel function index: https://support.microsoft.com/en-us/excel/excel-functions-alphabetical — availability varies by version. A function name list cannot certify formulas or the installed engine.
- Microsoft Word formulas: https://support.microsoft.com/en-us/word/use-a-formula-in-a-word-table — Word table formulas are fields and need updates; do not describe Word as a second Excel calculation engine.
- Worksheet.Evaluate: https://learn.microsoft.com/en-us/office/vba/api/excel.worksheet.evaluate — use a fixed, bounded expression on the intended worksheet, with an address normalized by Office; do not expose arbitrary evaluation as a new tool.
- OfficeDev samples: https://github.com/OfficeDev/Office-Add-in-samples — useful examples, but Office.js samples are not drop-in VSTO implementations.
- NetOffice: https://github.com/NetOfficeFw/NetOffice — Office automation framework; no evidence that migrating the project would fix the observed provider/verification bugs.
- Excel-DNA: https://github.com/Excel-DNA/ExcelDna — Excel/.NET integration; not a universal Word/PowerPoint agent engine. No dependency added merely to increase tool count.
- Anthropic tool engineering: https://www.anthropic.com/engineering/writing-tools-for-agents and evaluation guidance: https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents — prefer measurable tasks and clear tool contracts over indiscriminate tool expansion.

These are focused primary-source reviews, not a claim to have reviewed every GitHub project or all Office commands.

## Reproduced gaps and required changes

| Gap | Change | Acceptance |
|---|---|---|
| Test model can report TextOnly but the same configuration can still attempt writes | Short-lived evidence keyed by provider, endpoint, protocol, case-sensitive model and API key fingerprint; no credentials/fingerprints logged or persisted | A known failed tool probe blocks a mutation before inference and blocks unsolicited writes during text chat; changed credentials/model do not inherit the verdict |
| Working-only filter hides text-only models in dropdown but leaves them in clickable result rows | Apply the same filter to the tested-result list | TextOnly rows are absent while the filter is checked |
| Verification failure ends with generic message and zero successful writes in the diagnostic summary | Include actual acceptance details and preserve successful/failed write counts | Partial changes remain explicit and are not reported as zero writes |
| Every no-errors check loops over individual Excel cells on the UI thread | One bounded native error-count expression over the normalized range | Build succeeds; real Office acceptance must verify error/no-error cases in manual and automatic calculation modes |
| Word/PPT reference descriptions understate existing tools | Learn and model reference retrieval use the shared implemented capability registry | Word table and PowerPoint shape tools are searchable through the reference |
| Formula index provides names but little task guidance | Add nine bounded recipe notes for common aggregation/lookup/rounding tasks | Existing 521-entry index remains available; examples say to adapt real ranges and units |
| Native verification exceptions hide diagnostic cause | Record exception type and HRESULT, not document content | Diagnostic logging contains no raw document values or keys |

## Coverage and remaining work

Implemented in code: model evidence guard, filtered selection, native failure details, correct partial-write summary, reduced error-scan COM calls, consistent host references, common formula guidance and regression cases.

Partial: capability evidence is process-local, expires after two hours, and is not a certificate of agent quality. Unknown models are not classified as failed; they still use the existing guarded execution loop. Changing credentials requires new evidence. A Working probe verifies the tested protocol, not every multi-step Office task.

Missing/needs real-machine verification: broad Office version/bitness matrix; definitive reproduction and elimination of the user's freeze/restart; full visual quality evaluation; every Ribbon command; hundreds of templates; model training/fine-tuning. No API credential changes a model's weights. Playbooks/reference retrieval and execution checks are inference-time behavior, not training.

There is no current user-supplied log from the latest failure. The older screenshot demonstrates TextOnly and failed acceptance, but cannot identify the exact native exception. Do not claim all historical bugs are resolved from CI alone.

The model probe now makes at most one extra document-free text-protocol attempt when the native probe returns only prose. A verified fallback transport is reused for the same credential tuple; it is not discarded when actual chat begins. Existing timeout/cancellation budgets still apply. Superseded preview 64 is removed only after verified replacement publication, following the user's existing cleanup instruction.
