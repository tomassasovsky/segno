# Shared behavior prototype review

September 8, 2026. The three authorized proposals are ready for local design
review. No unresolved actionable findings remain in the reviewed implementation.
This is uncommitted design work under issue 919, not production implementation,
CI, a PR-head review, or approval of the proposed musical policies.

## Delivered scope

- Recording timing in the existing transport: first-Auto-take whole-bar tempo
  interpretation, stopped-start count-in, visible primary-cycle endings and
  atomic publication of inferred tempo with audio metadata/history.
- A separate symbolic processing comparison: Stop/Mute/Clear/bypass tails, live
  signal and monitoring, mono placement, selected render recipes and performance
  capture before/after final output controls. It produces no PCM and does not
  replace the host's render pipeline.
- Session musical-field capture/projection over current physical setup, exact
  control/media requirements, pending recall, Cancel/Retry, storage failure,
  and STOP/MODE access to the same pending decision.
- Eight editable 1920 × 1080 Pen frames in two labeled proposal sections, with
  browser and native references in the [review gallery](../../design/shared-behavior-previews/index.html).

## Independent reviews

| Role | Report | Scope and result |
| --- | --- | --- |
| VGV conventions | [VGV review](raw/vgv-review.md) | Timing and ownership; no unresolved findings |
| Architecture | [Architecture review](raw/architecture-review.md) | Timing and ownership; no unresolved findings |
| Test quality | [Test quality](raw/test-quality-review.md) | Processing and ownership; coverage finding fixed and independently retested |
| Simplicity | [Simplicity](raw/code-simplicity-review.md) | Processing and ownership; no actionable findings |
| PR readiness | [Mechanical readiness](raw/pr-readiness-review.md) | Timing and processing; clean on its recorded revision |

The [timing bug review](../../code-review/2026-09-08-recording-timing/review.md)
also passes on its final hashes. Each report states the author's excluded
scope; no agent independently approved their own implementation. The primary
agent reconciled the combined changes and reviewed the processing integration,
gallery, native text alignment and saved design source.

The mechanical report predates the final timing-browser guard assertions and
the two processing model tests with matching browser toggle assertions. Its
historical 19-test count is retained as observed; the later independent Test
Quality report certifies the final 21-test revision. The final timing browser
hash is covered by the VGV, architecture and bug-focused reports.
Documentation, gallery and Pen exports were subsequently finalized without
changing the reviewed implementation or test sources.

## Resolved findings

- Recomputed the primary after closing the defining take during recording
  handoff; no stale primary is used for the next Auto recording.
- Refused unsupported primary timebases explicitly, including Speed, Reverse,
  Once and independent tempo. This is a proposal limit, not permanent policy.
- Advanced due scheduler events before authorizing a primary playback change.
- Preserved an active take and clock/history when storage publication fails;
  an ordinary Stop publishes the finished take stopped.
- Corrected the exact-boundary queued countdown and added regression cases.
- Added missing live-signal/monitor tests. A no-op mutation now fails those two
  cases; the real browser live-input toggle is also exercised.

## Observed validation

- 62 recording-timing model cases and Chrome/Firefox timing journeys pass.
- 19 processing model cases plus both browser journeys pass: 21 total.
- 16 ownership/lifecycle cases plus 37 prior media/session-recovery cases pass:
  53 total. Ownership normal-host journeys pass in both browsers.
- 21 capture-recovery model cases, 10 reconciliation contracts and the existing
  transport contract script pass.
- Existing capture-recovery, chronological audio-history and complete
  two-display recording browser journeys pass in Chrome and Firefox.
- Independent model coverage measures 100% lines/functions for both new pure
  modules; branch coverage is 86.52% processing and 82.05% ownership. No
  prototype threshold is configured. This does not measure native/host coverage.
- Native screenshots were visually compared with browser references. All eight
  frames retain the full canvas, text alignment and contained encoder focus.
  Browser wrapper overflow for meter scales, inline labels and clipped meter
  fills is preserved; it is not mislabeled as a new missing-screen defect.

Exact commands and reviewed source hashes remain in the role reports. The final
[artifact record](../../design/shared-behavior-previews/verification.json)
records the saved Pen source and exported references. These are author/local
checks, not CI evidence. Dart/native checks do not apply to this JS-only slice.

## Still open

New count-in and tempo-inference policy, primary-cycle Auto policy, tail rules
beyond ordinary Stop, mono placement, render duration/scope, final recording tap
and session field ownership still need owner acceptance. Explicit primary
handoff, capture against transformed playback, exact sample clocks, physical
controller validation, real audio rendering and power-loss recovery remain
separate work. The 183 audit rows and their remaining gates are not reclassified
as closed by this prototype pass. No commit, push or merge was performed.
