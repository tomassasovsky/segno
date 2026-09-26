## Simplification Analysis

### Core Purpose

The instrument prototype must keep note, sustain, controller and audio ownership attached to stable instrument identities; expose synthesized sounds and their parameters; route controls through the existing shared assignment editors; and preserve saved patches across draft cancellation and failed writes.

Reviewed the current untracked implementation in `instrument-runtime.js`, `instrument-catalogue.js`, `virtual-instruments.js/.css`, the instrument additions to the shared assignment catalogue/dispatch and pedal/MIDI/expression studies, and the instrument host integration in `fx-ux-prototype.html`. The review follows `docs/plan/2026-09-09-fix-instrument-ux-plan.md`. Base checkout: `aaf042655b5059d9aff7c647a02249c1d019de84`. The owner is concurrently finishing encoder lifecycle changes; this report does not assess those unfinished changes or unrelated legacy prototype formatting.

### Unnecessary Complexity Found

- **Suggestion — Keep one raw MIDI decoder.** `docs/design/virtual-instruments.js:119` duplicates the byte-message decoding already performed by `instrumentMidiMessage` at `docs/design/fx-ux-prototype.html:983`. Both host entry points feeding `midiUI.receive` normalize messages first, and the sole production caller of `receiveRaw` is the shared receiver callback at HTML line 823. The branch that decodes another raw byte array therefore maintains a second implementation without a current caller requiring it. Pass the normalized event plus device into `receiveMidi`, and remove `receiveRaw` from the study API. If a raw entry point remains useful for the host, use the existing host decoder there instead of keeping two copies.
- **Suggestion — Schedule drum voice completion once.** `docs/design/instrument-runtime.js:107` calls `stopAt` before the LFO is attached. Lines 125–129 then repeat the duration calculation and call `stopAt` again to include that LFO. Every drum note consequently schedules each initial source twice and replaces an immediately created cleanup timer. Retain the computed one-shot end time and call `stopAt` once after all sources, including the LFO, have been assembled. This keeps the complete voice lifetime visible at one location and avoids two duration formulas drifting apart.

### Code to Remove

- `docs/design/virtual-instruments.js:119` and the corresponding `receiveRaw` API exposure: duplicate decoder, approximately one minified source line plus one exported property (roughly 8 logical statements).
- `docs/design/instrument-runtime.js:107` and the repeated drum duration formula/comment at lines 125–128: replace with one common completion schedule; approximately 2–3 net source lines saved.
- No document removal or broad legacy CSS/minified-file rewrite is recommended.

### Simplification Recommendations

1. Keep decoding at the existing host MIDI boundary and use a single event shape inside the instrument study. This removes an obsolete branch without changing controller routing or learn behavior.
2. Assemble all drum audio sources, then schedule their shared completion once. The sound duration and cleanup timing can stay unchanged.

The catalogue/runtime/study split is justified by the current requirements. Per-instrument voice and sustain maps, source cancellation, held-controller tracking, pending-start retirement, audition state separate from persisted patches, and the shared target catalogue all serve concrete simultaneous-controller or lifecycle behavior. Flattening these into selection-dependent page state would lose required behavior. No new abstraction, dependency, compatibility layer, or generalized framework is warranted.

### YAGNI Violations

Only the duplicate study-level raw MIDI decoding has no current path requiring it. The host's test seams and prototype simulations support the requested verification and repair journeys; they are not speculative extension points.

### Validation

`node docs/design/verify_instrument_runtime.cjs` passed during review: 19 patches, independent sources/routes and audio buses, splits/layers, sustain, remaps, MIDI expression, disconnect/reconnect, pending-start retirement, audition persistence, and audio failure.

This was a scoped static simplicity review with the focused runtime check. It does not replace browser journeys or visual/Pen verification performed by the owner.

### Final Assessment

Critical: 0. Important: 0. Suggestions: 2.

Total potential LOC reduction: under 1% of the scoped implementation. Complexity score: Low for the required behavior. Recommended action: Minor tweaks only.
