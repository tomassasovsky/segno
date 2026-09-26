# Shared behavior prototypes

The owner authorized developing the next proposals on September 8: recording
timing, FX tail consequences and session ownership. This is local prototype and
design work under the console redesign issue; it does not approve all proposed
behavior or authorize production deployment.

## Implementation

1. Extend the existing transport and Loop settings with stopped-start count-in,
   compatible Sync/Band Auto endings, and a demonstrable first-loop timing rule.
   Preserve the accepted click-independent fixed length, per-track quantization,
   Multi cycle recovery, recording outcome and shared Undo. Use actual transport
   commands for demonstrations; show queued endings in the existing track cue.
2. Add an executable, explicitly symbolic FX-processing comparison. Demonstrate
   Stop, Mute, Clear, bypass and all-sound cut, plus Track Mono placement and
   selected-track Bounce/export versus performance capture. The output-volume
   capture-tap conflict remains a visible comparison, not a silent choice.
3. Separate session musical values from current physical settings using a pure
   capture/projection module. Integrate at session save/load boundaries. Retain
   exact dependency identities and refuse unresolved physical mismatch; do not
   silently reconnect ports or rewind global catalogues.
4. Verify failure and cancellation paths, existing recovery regressions, normal
   browser routes and the two displays. Save grouped review references in Pen,
   update the shared behavior record and audit evidence without closing unapproved
   decision or native/hardware gates. Run the five build-review roles.

## Proposed timing rules

Count-in applies to an explicit record, overdub or play from stopped local
transport. Already running music supplies its own execution grid. External
receive does not introduce a local count-in. Stop cancels any queued start.

Sync/Band Auto captures at the requested point in the primary cycle. A finish
request completes the current primary cycle. Loop duration includes whole
primary cycles; captured-region position is retained and unwritten leading
space remains silent. Fixed compatible shorter windows remain selectable.

For the defining Auto take with click off and internal clock, the draft chooses
the whole-bar interpretation nearest the selected tempo, within 1–64 bars and
30–300 BPM. Audio seconds stay unchanged. This is duration-based interpretation,
not audio beat detection; half/double ambiguity needs owner review and real
audio evidence. Click-on, fixed length, external clock and later tracks preserve
the established tempo. Inference outside those limits leaves the take unchanged.

Primary reassignment and clearing an established primary require a separate
explicit choice; this pass must not add an automatic reassignment rule.

## Success Criteria

```success-criteria
GOAL: Demonstrate the remaining timing, processing and ownership choices through coherent, testable prototype journeys.

SUCCESS CRITERIA:
- Count-in and Sync/Band endings follow the proposed rules without interrupting unrelated playback | verify: node docs/design/verify_recording_timing.cjs
- The processing model distinguishes source feeds and tails for each action and exposes conflicting capture taps | verify: node docs/design/verify_processing_behavior.cjs
- Session recall preserves current physical settings and exact unresolved dependency identities | verify: node docs/design/verify_session_field_ownership.cjs
- Existing short-take and Clear All recovery stay intact | verify: node docs/design/verify_capture_recovery.cjs
- Review scenes match the main prototype and saved Pen references | verify: manual Compare the browser scenes with their grouped Pen exports and exercise touch and encoder controls.

NON-GOALS:
- Native DSP, audio onset detection, sample-clock accuracy or physical-device validation.
- Treating proposed timing, capture tap or ownership behavior as accepted without review.

VERIFICATION COMMAND: node docs/design/verify_recording_timing.cjs && node docs/design/verify_processing_behavior.cjs && node docs/design/verify_session_field_ownership.cjs && node docs/design/verify_capture_recovery.cjs
```

Reference: the [official Looper X guide](https://cdn.inmusicbrands.com/sheeran/looper-x/Sheeran%20Looper%20X%20-%20User%20Guide%20-%20v1.0.0.pdf)
documents Auto first-record tempo/bar inference. Segno's accepted fixed-length
behavior remains independent of audible click; the prototype does not claim to
reproduce the reference's undocumented inference algorithm.

Review clarification: tempo ambiguity uses proportional distance (absolute log ratio), with equal-distance candidates choosing fewer bars. Sync/Band Auto currently requires Normal speed, Forward, Loop and Follow tempo on the primary; timebase changes during capture are refused. These are explicit prototype limits pending a separate capture-timebase decision, not accepted permanent product restrictions.
