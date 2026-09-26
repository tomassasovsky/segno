# FX reference gates

Verified September 9, 2026 against the checked-in catalogue, generated evidence inventory, constructor capture and missing-source manifest. This record identifies what reference evidence still prevents exact parity; it does not reopen accepted UX or certify production audio.

## Required match

Segno must provide the same racks, constituent effects and effect parameters as Looper X. Names and functions must correspond. A smaller catalogue, omitted parameters or generic controls for an unverified effect do not satisfy the requirement. The owner permits independent DSP and different sounds. That waiver removes sonic identity as a requirement; it does not waive parameter contracts or establish rack processing order.

The owner has no working Looper X or complete factory-content backup. Original factory audio is not required for Segno's own sound library. Independent sounds must be identified as such; the original collection must not be claimed as delivered.

## Verified inventory and its limits

| Count | What it establishes | What it does not establish |
| --- | --- | --- |
| **159 presets** | Exact saved preset records and serialized values across nine rack families in `looperx-factory/catalog.js`. | Reset defaults, legal extrema, scale curves or recovered DSP signal order. |
| **300 family/key identities** | The union of exact parameter keys within each family. Identical words in different families remain separate identities. | A complete native control schema for every key. |
| **61 module-enable keys** | Classified enable controls in the evidence inventory. | Verified factory reset values; these remain unknown even for enable controls. |
| **239 unresolved controls** | An exact keyed list of remaining rack control contracts in `unresolvedControls`. | Type, units, legal domain, mapping curve, complete choices, dependent states or defaults. |
| **26 Single FX schemas** | Native effect identifiers and explicit unresolved schema records in `unresolvedSingles`. | Native parameter membership and behavior; borrowed rack controls are not proof. |

All **300 reset defaults** remain unverified. The catalogue also explicitly labels module grouping as proposed rather than recovered DSP order. Keep catalogue membership, rack composition/order and parameter-domain evidence distinct when reporting parity.

## Constructor evidence is useful but incomplete

The reproducible ARM constructor capture records **52** calls whose exact key set matches Ed's Rack, including five numeric arguments plus formatting for **24** calls and ordered string-list arguments for **four**. It preserves duplicate strings. This establishes call arguments and source identity, not their final user-facing meaning.

The capture intercepts builders without executing them and does not instantiate Qt translators, run DSP or capture factory reset. Numeric arguments cannot safely be renamed minimum, maximum or default without tracing their semantics. Eight further family constructor regions reached unresolved dependencies before completion. Their partial traces are not schemas. Native Guitar `Wham` and saved `Whammy` naming also demonstrate why approximate matching is insufficient.

## Work already performed and the closing evidence

The recorded local pass extracted presets and metadata, compared exact keys, traced constructor references, reproduced the Ed's Rack argument capture, and checked the supplied Looper X update and an official Looperboard updater for content. Both inspected packages expect a separate content partition; neither supplies the needed factory collection. Repeating these same scans cannot establish missing live descriptor values. This does not claim all possible reverse engineering is exhausted: a complete builder/translator trace remains a potential route, but the existing partial trace is not closure.

To close each FX row, obtain an official per-control schema, an authorized instantiated runtime descriptor capture, or an equivalently complete trace. Preserve firmware version, source provenance, exact family/Single FX identity and serialized key; translator type and units; legal range and scale curve; every enum value/label pair; visibility/editability dependencies; and genuine factory-reset values distinguished from initialization or preset values. Single FX require their own schemas. Rack composition and processing order require separate verified evidence.

The manifest's **302** historical audio names and expected byte counts establish references only. An authorized content export containing `Resources` and `looper.db` would resolve that historical-source limitation, but the owner has waived it as a product-completion prerequisite.

Sources: [FX findings](../../design/2026-09-09-fx-reference-completion.md), [remaining gates](../../design/2026-09-09-remaining-design-gates.md), [exact missing sources](../../design/fx-reference-evidence/missing-sources.json), [constructor capture](../../design/fx-reference-evidence/native-constructor.json), [catalogue](../../design/looperx-factory/catalog.js), [evidence inspector](../../design/fx-reference-inspector.html).
