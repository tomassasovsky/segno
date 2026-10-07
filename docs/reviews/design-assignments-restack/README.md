# Pedal assignments reconstruction

Local implementation, independent review and required checks are complete.
Remote CI is a separate gate on the published revision; the human merge gate
remains in place. This report covers Press/Hold and target scope, not the
remaining Pedals setup, Custom, external control or MIDI surfaces.

Base: `0d601db8ec3450afb8ca94071ce96c969ffde1d9`.
Original assignments parent: `b89342e2dd8c64d08d2fa928f635016cc1f69374`.
Reviewed twelve-path source/test/configuration fingerprint:
`410241c0e710f3dc6174cf9c175fff241f73669baab7ff78ab4f74913b602e40`.

## Behavior

A bound track pedal can assign Press and Hold independently. Press waits for
release when a Hold is assigned; reaching the shared 800 ms default fires only
Hold. Explicit saved thresholds remain honored. Record/Play and Stop retain
immediate contact. Fixed targets keep their identity; selected targets resolve
when the action fires. A completed momentary retains its resolved target until
release, even after selection or bank changes.

Invalid Hold combinations and malformed explicit scope/behavior values are
rejected consistently. Missing targets remain unavailable. Session changes,
configuration changes, disconnects and take locks prevent pending gestures
from reaching a different session or bypassing the lock.

The current UART owner remains authoritative for built-in controls; CTRL and
MIDI retain their existing source-specific ownership. No retired USB pedal
binding, application heartbeat or second controller interpreter is restored.

## Repaired findings

| ID | Failure | Verified correction |
| --- | --- | --- |
| M3-01 | A released effect could stay enabled after an identical pending recipe completed without a new state emission. | Captured restoration waits for actual recipe readiness; both the original case and a second-recipe sequence pass. |
| M3-02 | Hold LEDs read the Press target; later display memory could leak between assignments. | The last successfully dispatched action is associated with its exact binding; momentary and toggle states remain distinct. |
| M3-03 | Removing a held effect left its pedal blocked after reassignment. | An absent stable identity retires the impossible restore without substituting the replacement effect. |
| M3-04 | System holds could fire through a take lock acquired after contact. | All pending gesture timers share a firing-time lock check; accepted releases still restore. |
| M3-05 | A pending hold could fire during asynchronous session replacement. | Timers capture session ownership at contact and refuse a replacement session. |
| M3-06 | Bank B actions wrote their LED overrides into Bank A's frame positions. | Every branch uses the actual active-bank channel; the independent probe checks wire index 4. |
| M3-T01 | Three historical Redo fixtures used a 600 ms hold. | The fixture crosses the accepted 800 ms boundary with 850 ms; all audio/LED expectations and random draw counts are unchanged. |

Original failures are retained. The final author Bank B regression now checks
both the dark and lit value at the position consumed by firmware, correcting
its earlier misleading internal-index assertion.

## Validation

- Full application: 2,261 passing tests, six existing skips; 91.11% coverage
  against the required 90% floor. Source hashes remained unchanged throughout.
- Fresh Settings suite: 141 tests, 90.82% coverage; no configured floor.
- Six unchanged package suites reuse source-bound evidence: 1,356 tests. Their
  configured floors pass. The already reviewed M2 formatting-only model
  amendment is explicitly reconciled; no new package behavior changed here.
- Strict analysis, explicit formatting, actual Bloc lint over 652 files and
  whitespace checks pass. Dependencies were resolved before formatting.
- Fourteen independent targeted cases pass: eleven fixed gesture/lifetime
  cases, one real second-recipe challenge and two final LED bank cases. The
  first eleven were not rerun solely for the later display amendment; review
  verified their production mechanisms stayed unchanged. The model's later
  amendment was comment-only. This is explicit evidence reuse, not a claim
  that every case ran simultaneously on one byte-identical revision.
- Native code, FFI and firmware are unchanged. The independent probes use the
  actual frozen native test library for admission, acknowledgment and session
  behavior; its existing native safety gates are retained.

One independent reviewer completed all five quality roles sequentially and
reviewed every changed code/test/configuration path. A second independent
reviewer authored and ran the adversarial probes. Neither authored this
implementation. The consolidated bug review reports no unresolved actionable
findings; five role reports do not mean five different reviewers.

## Remaining limits

This slice adds no new setup screen and changes no accepted visual design.
Physical foot timing, electrical disconnects and visible hardware LED behavior
still require the appliance. Later setup, Custom mode, LED color, external
pedal and MIDI journeys remain separate slices. No deployment, hardware
validation or human merge approval is implied by local tests.
