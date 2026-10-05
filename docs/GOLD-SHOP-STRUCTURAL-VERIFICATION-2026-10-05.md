# OMNIX: multi-sheet gold sample and structural verification

## Concrete changes

- `gold_shop` is a new embedded four-sheet sample plan, while `gold`, `inventory`, and `invoice` remain available. Three sales, three products, two customers and four report metrics use typed inputs and real formulas.
- Sales are created first, followed by products, customers and the report. All cross-sheet names and formula references are bound before returning the plan; embedded apostrophes are escaped in formula references. Invalid generated sheet names fail before any template is delivered.
- Money is AFN, weights are grams, stock is pieces and dates are Gregorian ISO. The sample explicitly labels invented data and unknown shop/contact information. Rates apply to the stated purity and are illustrative, not current prices. Sales capture transaction rates/weights; changing a product rate does not change old sales.
- Native table postconditions can require exact ordered headers, data row count and exact ordered text IDs. Key verification uses one bounded bulk read rather than one COM call per record.
- Heading checks can reference `aboveTable`; the actual merged frame must be outside and entirely above that native table on the same sheet. Explicit recognized quoted shop/seller titles must match the original request.
- Conservative explicit requirements are exposed to the model independently of its execution plan. Resume now loads the business playbook using the original goal rather than the short `continue` command.
- Excel `read_document_section {sheet,part:"objects",kind:"tables|charts|shapes",offset:0,count:10}` reports actual object names, ranges/dimensions and pagination (maximum 20 per call). It does not read external data or execute macros. Object names are data and must be re-inspected after edits.

## Verification

The Windows startup harness validates all steps/checks of every embedded template, four-sheet coverage, escaped cross-sheet names, invalid generated names, title mismatch, cross-sheet heading mismatch and malformed table criteria. Compilation and existing regression gates must pass before merge/publication.

The interactive real-Office functional script now builds the four-sheet sample through the installed core and verifies actual native postconditions. It then deliberately introduces literal formula text, a duplicate record ID, a wrong table header and a heading below the table, verifies rejection, restores the cells and rechecks completion. The scenario is mandatory for the Excel functional result. The existing bound full-Office workflow includes this script.

**Real desktop Office was not available in the implementation environment. Adding this scenario is not evidence that it passed on the user's computer.** The Windows source/build gates do not replace interactive native Office acceptance, provider/network tests or visual screenshots.

## Scope and limits

This is a further upgrade, not a claim that every historical issue or every Ribbon feature is resolved. The four-sheet sample is not certified accounting software. Its formulas intentionally use fixed sample ranges; extending transactions requires updating dependent ranges and acceptance checks. It does not implement relational transactions, taxes, live gold rates or a fully normalized invoice/line-item database. Creation is additive and per-sheet, not an atomic four-sheet transaction: inspect all destination names first, and repair existing objects on follow-up rather than recreate them. Each builder refuses an existing destination.

The deterministic requirement recognizer only handles a small set of explicit Excel wording. It is not a full independent task specification, universal language understanding or a trained model. Word/PowerPoint retain their existing native tools/playbooks; this change does not add equivalent business templates to them. Object metadata is not pixel vision, complete workbook content or evidence that an arbitrary model supports image input. No fictional Ribbon clicks or private reasoning are displayed.

## Remaining acceptance work

1. Run the exact installer through the bound interactive Office workflow and collect crash/dispatcher logs during the user's freezing scenario.
2. Test supported provider models on actual Office tasks; the bounded Working probe remains weaker than end-to-end business quality evidence.
3. Extend task specification coverage to independently checked layout/content requirements across all three hosts.
4. Add calibrated visual checks for models that support images and tested document/presentation business templates.
5. Add teaching mode and richer persistent business preferences after native responsiveness and correctness are demonstrated.
