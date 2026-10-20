# M3.14 targeted quality closure v2

This supplements the full sequential VGV, simplicity and test-quality review in `ui-root-quality-review-v1.md`. The same cross-author independence limits apply: my runtime implementation is excluded. No product edits or test processes were used. Current inspected hashes and producer evidence hashes are in `ui-root-quality-source-v2.json`. Final producer freeze is bound below.

## C2: exact expression endpoint restoration — closed on inspected source and producer regression evidence

The separate cancel callback restores the raw opening endpoint, while ordinary endpoint edits continue to quantize Record length. The real-page regression repairs Track volume `.2/.8` to Record length, performs Enter/arrow/Escape, saves, and requires exact `.2/.8`. `model-ui/c2-red.log` records expected `.2` versus actual `.203125` before repair; `c2-and-button-4.log` records 45 passing relevant tests after repair. The test now clears startup interactions and checks `setLengthSettings`, the current vector path. This is a discriminating behavior test, not a new expected value matching the old bug.

## C3: long lock reason overflows picker row — closed on inspected source and producer regression evidence

The corrected External fixture exposed a real 257-pixel horizontal overflow when the Multi lock reason occupied the trailing row value. `model-ui/external-controls-1.log` preserves the failing render. The value now uses Flexible, one line and ellipsis within the existing bounded row; the complete value remains in the outer semantics label. The name/destination column remains flexible, and disabled tap/focus behavior is unchanged. No broad layout rewrite or hard-coded lock-string width was introduced. `external-controls-2.log` records the complete 27-case page suite passing after repair. Accessibility source inspection confirms the full reason remains available; this review does not claim appliance screen-reader execution.

## Fixture and assertion corrections — closed on inspected source

External legacy page and External screenshot fixtures now construct and load RecordOptions, inject the same owner into Control, provide it to the rendered page, and register teardown. MIDI screenshot wiring has the same coherent owner. Existing assertions were retained. The new MIDI/expression Record length Add/Save/Escape tests clear interactions after startup and assert no `setLengthSettings` call, so an accidental dispatch through the current owner cannot evade the no-audio check by avoiding the retired scalar setter.

No additional actionable issue was found in these targeted deltas. Root composition assessment is unchanged from v1. Whole-slice readiness still requires the final producer source/test manifest, root aggregate/static/current-head binding, and independent runtime review; the passing focused producer logs are not a substitute for those gates.

## Final producer binding

All 29 entries (27 Dart, 2 PNG) in `model-ui/freeze2-sha256.txt` match the current checkout. The manifest hash and every entry are retained in `ui-root-quality-source-v2.json`. The two included catalogue/label test files are unchanged from base; the remaining panel fixture delta supplies the new cancel callback without changing its existing assertions. PNG bytes were verified for binding only; root owns visual approval.

`model-ui/focused-final.log` records 211 passing scoped model/UI/Loop settings tests. These are observed producer results, not reviewer reruns. C2/C3 and the fixture/assertion gaps are closed. There is no unresolved actionable finding in this cross-author VGV/simplicity/test-quality scope at freeze2. The root's whole-source/runtime review and full aggregate/static/current-head gates remain separate and were still running when this closure was bound.
