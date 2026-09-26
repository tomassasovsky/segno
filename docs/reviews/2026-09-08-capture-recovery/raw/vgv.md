# VGV Code Review

September 8, 2026. Independent implementation review of the local symbolic
prototype. The reviewer authored `verify_capture_recovery.cjs` and the harness
publication observer; these are excluded from this review's independence claim.
The coordinator assigned their test quality review to another reviewer. No
implementation files were edited in this review.

## Summary

No unresolved actionable findings remain on the source hashes below. Reviewed
the exact transport, display and main-host diff against the task's captured
baseline in `/tmp/segno-capture-recovery-before`, then the corrective length
caller and review-scene integration. The implementation preserves the existing
plain-JavaScript study boundaries: transport owns content and history, the host
owns canonical rig persistence, and the display projects symbolic regions.
This is not a review of native recording, Flutter integration or production CI.

## Regressions and failure paths

- Capture finalization is staged in a cloned journal. A failed recovery
  publication leaves content, journal, capture and queued actions untouched;
  capture can continue before a later successful retry.
- The host builds a complete stored rig, including the edit journal, and
  performs the storage write before applying track changes to live state.
  The extracted serializer retains existing released-contact and unfinished
  inline-edit handling. The same track projection is used for saved and live
  state, avoiding divergent field mappings.
- Clear All freezes nonempty partial capture into its own chronological edit,
  then records a grouped clear. Undo restores completed playing/stopped states
  and stopped playable partial captures, without rearming old queued actions.
  Earlier history, decay restoration and later Mixer/FX edits are preserved.
- Zero-duration captures and queued-only work do not invent recorded layers or
  audio history. Publication failures do not consume Undo/Redo entries.
- Recovery that would resume playback checks audio availability before
  publication. Song/Band secondary-track stops are included in the projected
  change before storage, rather than applied afterward as unsaved side effects.
- Sparse capture keeps its established loop duration and actual captured beat
  interval. Length edits transform those intervals, and Wave uses positive
  modulo arithmetic and explicit empty-region silence. The host's simulated
  meter also respects unwritten regions.

## Findings resolved during review

1. **Unrecoverable Sync/Band Clear All:** an established eight-beat track plus
   three captured beats in a second fixed take could be cleared but not restored
   because recovery rejected the incompatible duration. The author retained the
   already chosen compatible fixed window and added a pre-publication
   compatibility check. Both modes now pass. The Sync/Band fixed-window behavior
   remains a proposal; this review does not promote it to an owner decision.
2. **Sparse regions after length edits:** Multiply omitted the repeated region;
   Divide could render an entire retained half as audio because an old offset
   exceeded the new duration. Canonical plural regions, split/retain/repeat
   transformation, positive modulo and flat empty contours correct both cases.
3. **Saved Undo eligibility after reset:** `canRecover()` no longer loaded the
   stored journal and depended on a later snapshot side effect. The explicit
   history load restores immediate eligibility, with a regression check.

## Conventions and simplicity

The required publication callback is an appropriate existing host/test seam,
not a speculative service abstraction. Journal staging and audio preparation
remain transport concerns. The newly introduced sparse representation uses one
canonical regions array; no migration layer for the intermediate representation
was added. Existing example layers without regions continue to represent
full-loop fixture content. No new dependency, timer or resource lifecycle was
introduced in the core implementation.

No lint suppression or production layer violation was introduced. The
repository's Dart/Flutter formatter and analyzer do not apply to this bounded
plain-JavaScript prototype change. No further source-removal recommendation is
justified in the reviewed delta.

## Verification

Independent runs on the final implementation:

- `node --test docs/design/verify_capture_recovery.cjs`: 21 passed. Authored by
  this reviewer; not an independent test-quality judgment.
- `node docs/design/verify_audio_state_reconciliation.cjs`: 10 contracts passed.
- `node docs/design/verify_stage_transport.cjs`: transport and grouped recovery
  sections passed.
- `node docs/design/verify_capture_recovery_browser.cjs`: Chrome and Firefox
  passed, including actual storage failure/retry, persistence, sparse Wave,
  active grouped recovery, newer-audio protection and later Mixer/FX edits.

Runs use the configured Node 24 and Playwright runtime. They verify symbolic
prototype behavior; no native audio or appliance performance claim follows.

## Final test delta

Two authored Song/Band Redo cases now inspect cloned candidate state and journal
through the harness's read-only `publishedAttempts()` observer, before either
storage refusal or live mutation. They verify section exclusivity at publication,
Band primary retention, and unchanged live state/history after failure. The
independent [Test Quality review](test-quality.md) passed all 21 cases and
mutation-checked both removal of normalization and moving it after publication;
each mutation failed exactly these two new cases. The existing reconciliation
and transport scripts also pass. All implementation hashes below remain
unchanged, so the earlier Chrome/Firefox evidence still applies; browsers were
not rerun for this test-only delta.

## Reviewed source hashes

| File under `docs/design/` | SHA-256 |
| --- | --- |
| `stage-transport-study.js` | `3ca5fcc49b8b184406f2691408ceef427b40da79c523ef3f4df2bdd720e866b4` |
| `fx-ux-prototype.html` | `38e60242e40451630bda5bdf56ac36c2610e4217965e53fadd0c5223fb62a58c` |
| `stage-display-study.js` | `5dade15c26d7d861c5071e2794a400c74a78b7de42369ea50610661510ba0a12` |
| `length-performance-study.js` | `e60f3bdc358e2455cd21ecfc4fbab3ce83a2ab732431c774354d6ecfbaef1337` |
| `capture-recovery-scenes.js` | `06a5d0b498089da501dfef640eddd7ffcf3ed34d77264cee19dd6aab55ed391a` |
| `audio-state-test-harness.cjs` (authored observer) | `faa165ef0aff054c66dbe343046a497e3bfd5bd2a7f19531b5f7bf35315270d4` |
| `verify_capture_recovery.cjs` (execution only) | `de76c06837e5f98073eeae7ac60f2a0893510e8fa67907142d8e646f89d2d591` |

## Verdict

No Critical, Important or Suggestion findings remain in this implementation
review. The three reproduced regressions are corrected and rechecked.
