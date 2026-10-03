# Independent M3.14 execution report

Disposition: the exercised 44-case candidate behavior passes. N1 successfully detects premature receipt acceptance. No candidate product failure was found in these runs. Execution is closed; test slot 1 was released to root. This is independent bounded evidence, not the complete CI, visual, hardware or merge gate.

## Binding and preservation

Original oracle remains unchanged: `c7dbb68821e848c5e565ec7af9b3432d4e3f1b3e2f2bb59c7f7ba0c4613d5889`. Pre-implementation authority source read set: `3c4760a7988e176b9b6cba79a59f388dc4e7129ee9fb39ff9be5bebd22ea62c7`. Final report binding: `final-review-binding-v1.json`, SHA256 `2a3699532293506a3697553e57a14fbad62f8a461da97df549e29c13d68e95db`. It includes exact source, harness, logs, native and dependency hashes.

The 44-case execution used product freeze `1de40a1222958894f1f3e4891a3364f60097ea46aca9edd4cb13333c9e0804bf` (29 paths) and native library `8e980280f9fbe6e8ba89d432ba94635ac8e72ddbe1f6503fb7c27050af85bb65` from source manifest `ae97a3180ebc9008e7a1d19fce0d0611c19f615ab0339ef3b3512c3c26c7bef4`. The library was neither rebuilt nor modified. The executed core source remains unchanged, including RecordOptionsCubit `df23c3c39c149c6389947545e31e0d2551970614c6c011e3d573b8a479295165` and LooperRepository `bf8d4203942cc2e2427474c9d768fbc8c042b88c3d5f0ef28b628bca021e5c22`.

After the 44-case run, three UI product files changed: `external_pedal_page.dart` and `expression_controls_panel.dart` for C2, plus a narrow flexible/ellipsis value-label layout correction in `control_row_list.dart`. Their old/new hashes are explicitly recorded. The conservative runtime/package/config/helper source read set contains 1295 unchanged entries; no runtime rerun was warranted. The subsequent focused control and mutant ran with both C2 hashes included and remained stable; the later value-label layout change was reviewed and bound without rerunning the unrelated runtime probes. UI tests edited by the other author are separate evidence and do not supply this harness's oracle.

## Attempts

| Attempt | Exit | Bound inputs | Observed result |
|---|---:|---:|---|
| independent01 | 1 | 1496 | 34 checks passed; native file compile failure before its 10 cases (wrong fixture EngineConfig type). Two unrelated author UI test files changed during this attempt. |
| independent02 | 0 | 1499 | 44/44 PASS: 26 model/owner/dispatch, 10 native/capture/PCM, 8 lifetime/Session/PowerOff. |
| sensitivity03 | 1 | 1499 | Setup failed before target assertion. Invalid sensitivity evidence; preserved, not counted as a successful negative control. |
| receipt04 | 0 | 1503 | Focused unmodified L05 PASS after assertion-order-only fixture change. |
| sensitivity05 | 1 | 1503 | Expected FAIL at pending-result assertion, after actual native enqueue, unsettled fence and old raw vector were proved. |

Independent02, sensitivity03, receipt04 and sensitivity05 had zero before/after changes. Independent01 retained its two non-imported UI test changes; no product/library/oracle drift occurred. Native v2 corrects only the direct native EngineConfig type, retaining the exact capacities, rates and expected outcomes. Originals and failed logs remain present. No assertion or oracle was relaxed.

## Distinct behavior exercised

- Strict fixed default/eight-track identities, literal normalized rounding, one-bar relative input, immutable membership, Auto versus absent override and Multi eligibility.
- Storage refusal, wrong readback, mutate-then-throw, exact absent/Auto rollback and failed compensation with explicit recovery; rejected native admission and exact-old callback refusal do not publish success or stop a healthy rig.
- Storage/enqueue does not complete acceptance before actual callback. Timeout and autonomous restart failure become recovery; blocked initial reads across reconnect/session replacement and stale compensation do not overwrite replacement native intent.
- MIDI Held 8/Released 2 and External 16/4, accepted holder ordering, rejection, old release/repress, ordinary-before/during, Use default with delayed completion, sibling preservation, non-held durable priority, accepted/refused Multi transitions and restart Released projection.
- Real native Record and Overdub queued before both plain vector and same-mode vector writes; all four reject mid-capture mutation. Capture before admission and after a blocked scalar write is refused. Owed release preserves capture and retries after the performer's explicit stop.
- Real native 64-bar admission at 8 kHz/30 BPM/4:4 with 4,096,000 frames of capacity; small-capacity refusal stays atomic. Existing recorded PCM, length and audio history survive a future-preset change and compatible mode transition.
- Actual Session file Save stores Released length and exact Auto membership with sibling Playback projections. Real PowerOffCubit paths exercise failed flush, Retry/Keep playing, cutoff and fresh input through the owner; these are not the full App capture journey.

## N1 sensitivity

The first mutant bypassed every receipt, corrupting setup semantics; its early failure is not counted. The corrected isolated mutation activates only on the predetermined 16-bar transaction after genuine setup receipts. The original callback/native enqueue stays intact. L05 asserts a new native write, `commandsSettled == false` and raw `[0,4,4,4,4,4,4,8]` before checking its still-pending result. The mutant fails that result assertion with a completed RecordLengthOutcome; the unmodified focused control passes. The mutation therefore exposes enqueue-as-receipt, not a mocked return value or compile error.

Exact patch `receipt-bypass-v2.json`: `e0544ce23b8383680975a06d0c4abf900de0bd986ad5c1c1151aa4aa1be990c1`. Mutated isolated repository: `e45033fa1f8a66ba4e35aff568da4330b8f1c2ac66758a0a96f8af68205bcf4f`. Normal log `a2306ad7f9e3b036f18e1aebc0ae4196a9dbb82d5581dae289a5287830370a51`; expected failing log `447a20fadfe1bc14b7746422c398cfc34afbc9c5a1b03723c01dc46db6a96815`. The raw assertion was moved earlier solely to prove this boundary; its expected values are unchanged.

## Limits

The 25 oracle groups are not 25 fully exhaustive claims. Mapping Add/Save/Cancel/Escape, visual/accessibility validation and actual App startup/shutdown/LooperBloc composition use separately owned tests; this private suite does not count them as its executions. Root's actual App C1 log was inspected and contains two passes (transient and malformed startup Retry). C2 was discovered/reproduced/repaired by the model/UI author; its source and regression were read here, not re-executed.

There is no per-command native acknowledgement. Exact-old-vector refusal and identical-vector membership are inferred from the queue fence, complete raw vector/mode and capture checks; identical-vector command history is not uniquely observable. Representative PCM/mode and source order cases do not exhaust all five modes, spans, track combinations, MIDI formats or every failure interleaving. Hardware/audio-backend timing, process-crash durability and full live-Control Session Load remain outside this proof; inherited M5 is not closed. Author screenshot rendering remains separate from CI. Full aggregate coverage, static checks and exact-head CI belong to root's final gate.
