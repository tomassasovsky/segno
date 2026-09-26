# Handoff user-flow and readiness review

9 September 2026. Reviewed `IMPLEMENTATION_PROMPT.md`, `README.md`,
`accepted-behavior.md`, `implementation-map.md` and `reference-gates.md` under
`docs/handoff/segno-app/` against the current prototype's gesture, recovery,
selection, capture and source-identity owners and the latest accepted records.
The reviewer authored `accepted-behavior.md`; this is an independent review of
the other four documents and their consistency with that contract, not an
independent certification of the reviewer's own text. The pending delivery
manifest/checklist and active Pen cleanup were excluded as requested.

## Actionable findings

### UF-1 — Preserve the normal transport contact exception

- **Locations:** `IMPLEMENTATION_PROMPT.md:24`; `implementation-map.md:51`.
- **Finding:** Both summaries state without qualification that Hold does not
  execute Press. The accepted normal Tracks behavior deliberately executes
  Record/Play, Stop and track selection on contact; Record/Play may subsequently
  execute its configured hold action. A blanket exclusive recognizer would delay
  recording until release/timeout or eliminate the accepted record-then-hold
  recovery behavior. This conflicts with accepted-behavior section 4.3.
- **Evidence:** `docs/design/pedal-performance-study.js:180` immediately runs the
  action for normal Record/Play, Stop and track selection, marks the gesture
  direct, and separately schedules the eligible hold. The non-direct branch at
  lines 205–213 gives configurable navigation pairs exclusive Hold behavior.
  `docs/design/2026-09-07-stage-recording-ux.md` explicitly documents the distinction.
- **Required correction:** Qualify both summaries: configurable navigation/control
  Press/Hold pairs are exclusive, while normal Record/Play, Stop and track
  selection retain their immediate-contact behavior. Include a regression for
  immediate Record followed by its configured hold and no duplicate release action.

### UF-2 — Clear All recovery restores the audio transaction, not the whole rig

- **Location:** `implementation-map.md:47`.
- **Finding:** The acceptance sentence says Clear All recovery restores “the
  whole prior rig.” That can instruct a native implementation to restore an old
  complete snapshot, rolling back later FX/Mixer changes or resuming microphone
  capture. The accepted behavior instead restores the grouped audio edit and
  relevant timing/playback state, preserving later unrelated settings. An
  interrupted capture returns stopped with its material recoverable.
- **Evidence:** `docs/design/2026-09-08-capture-recovery-ux.md`, Behavior section,
  explicitly preserves subsequent fader/mute/FX changes and never resumes
  microphone capture. `docs/design/stage-transport-study.js:73` restores changed
  audio fields and conditionally restores other relevant fields; it is not a
  whole-rig assignment. Accepted-behavior sections 2.10–2.11 retain this contract.
- **Required correction:** Say that one Undo restores the affected tracks'
  recorded material, lengths/layers and applicable previous playing/stopped and
  timing state, preserves later Mixer/FX edits, and returns interrupted captures
  stopped. Add that combined case to the slice's acceptance sequence.

## Completeness verdict

Review complete for the declared five-document scope. **Two actionable wording
contradictions remain before the entry prompt is ready to hand off.** No other
actionable missing accepted requirement, reopened decision, unsupported source/
production claim, or unsafe transfer/publication permission was found in this
pass. The first slice is concrete: four-track main view, selected-track second
display, first-completed-take crown, existing transport integration and observable
bank/selection/queue/reload checks. Physical evidence is correctly distinguished
from browser proof. The two fixes require clarification of already-settled
behavior, not new owner approval.

## Focused recheck and delivery wording

UF-1 and UF-2 were rechecked against the updated documents on 9 September 2026.
Both are **resolved**:

- **UF-1:** The entry prompt and implementation slice 4 now qualify exclusive
  configurable navigation/control gestures and explicitly retain normal
  Record/Play, Stop and track selection on contact.
- **UF-2:** Implementation slice 2 now restores grouped audio/timing/playback,
  preserves later Mixer/FX changes and returns interrupted captures as stopped
  recoverable material.

`delivery-checklist.md` was additionally reviewed for evidence claims and
consistency with the accepted product contract. No actionable wording finding
was identified. It correctly distinguishes prototype checks, native Pen review,
source-evidence gaps, content delivery and production/device work; it does not
claim an old video includes later refinements or grant deployment authority.
Final Pen save and manifest binding are still the coordinator's active evidence
work and are not independently certified by this text review.

SHA-256 of the rechecked documents:

| File in `docs/handoff/segno-app/` | SHA-256 |
| --- | --- |
| `IMPLEMENTATION_PROMPT.md` | `cb90586e2a2aac72e1cca69e90349865d5ec8d5b363030c0fbefe269d2bb66f4` |
| `implementation-map.md` | `39e0ea6068a81d767bf20a810637e17b027dd4e3eabe19e5fad50d509079389d` |
| `delivery-checklist.md` | `86a4071028e0b9f699d49859ea581bd52c03753cdd66db8ddf680ddce99f8414` |

**Updated verdict:** complete for the declared user-flow/readiness text scope,
with no unresolved actionable findings at these hashes. This focused recheck
does not expand the original independence claim for the authored behavior contract.
