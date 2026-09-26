# Test Quality Review: capture recovery

Final review of the authorized silent design prototype slice on September 8,
2026. The review follows the workflow-agents Test Quality role and the build
review-agent output contract. Native audio rendering, appliance validation,
unrelated dirty files, and overall audit completion are outside this review.

## Scope and independence

Independent inspection covers the capture/recovery and publication changes in
`stage-transport-study.js`, the sparse interval length transformations in
`length-performance-study.js`, sparse contours in `stage-display-study.js`, and
the storage publication and sparse meter seams in `fx-ux-prototype.html`.
Independent test review covers `verify_capture_recovery.cjs`, its shared
`audio-state-test-harness.cjs`, and the relevant assertions in
`verify_stage_transport.cjs` and `verify_audio_state_reconciliation.cjs`.
Existing whole-file behavior is not being newly certified.

This reviewer authored `verify_capture_recovery_browser.cjs`. Its Chrome and
Firefox results are identified below as author verification, not independent
review of that test. The nonpersistent `capture-recovery-scenes.js` routes are
review presentation fixtures, not replacements for normal-route persistence
verification. The new scene calls were inspected for that boundary; they were
not counted as acceptance tests.

The repository's application uses Flutter, Bloc and native code. These named
files use the established standalone JavaScript prototype: Node assertions,
`node:test`, VM-loaded real model scripts, and Playwright browser journeys.
Dart/Flutter mocking, widget wrapper, and coverage conventions do not apply to
this slice. No Node package manifest or design JavaScript coverage threshold is
configured; the CI thresholds in `main.yaml` belong to Dart packages.

## Coverage summary

- Independent run: **pass**, 21 focused `node:test` cases plus two existing
  script entries, for 23 Node runner entries. The reconciliation script reports
  ten additional named contracts internally; it is one runner entry.
- Command: `node --test --experimental-test-coverage docs/design/verify_capture_recovery.cjs docs/design/verify_stage_transport.cjs docs/design/verify_audio_state_reconciliation.cjs`.
- Node reported 100% line and 99.36% branch coverage for the test/harness files
  it included. VM-loaded implementation files were omitted from that report.
  These percentages are **not implementation coverage**. Implementation
  coverage is unavailable from this invocation; correspondence was checked by
  tracing commands and output assertions against the changed source.
- Corresponding behavioral tests exist for all four implementation seams in
  scope. No new implementation file lacks a test counterpart. The verified
  missing recovery branch was resolved and independently rechecked below.

## State management test quality

The 21 focused model tests use fresh canonical rigs, a controlled clock and real
transport/edit commands. They cover shared 16-beat Multi windows at ordinary and
wrapped offsets, a first take with no established cycle, frozen initial and
overdub captures, playing/stopped restoration, grouped chronology, zero-length
and waiting-clock cancellation, decay exactly once, fixed Sync/Band windows,
offline recovery refusal, sparse Multiply/Divide, a wholly silent retained half,
and saved history eligibility immediately after reset.

Failure tests assert content, capture state, pending actions, positions and the
entire saved journal. They also advance time after rejected publication and
retry, detecting lost capture start time and duplicate retained takes. Fresh
rigs isolate mutation; synchronous fake time avoids races and real sleeps.
The publication fake is the explicit storage seam, while the transport and
length implementations remain real. Assertions compare observable descriptors
and histories; they do not recreate the recovery algorithm.

The Wave test supplies equal nonzero reference peaks to the real display
implementation, then checks literal occupied bins. This is a useful input
fixture: it distinguishes silence from recorded content without duplicating
region intersection logic. The older scripts add chronology across Peel,
Multiply, imports and Bounce, session history serialization, group overwrite
protection, and ordinary Song/Band transport regression checks.

### Resolved: section normalization at recovery publication

Location: `docs/design/verify_capture_recovery.cjs`.

The newly introduced `recoverySections` path must normalize Song/Band section
playback before `editState.publish` receives a recovery candidate. The original
19 focused cases did not recover a playing section while a different section
was playing. The existing Song/Band reconciliation test exercised direct
transport and MIDI only.

Verified with an in-memory mutation of the loaded transport source that removes
only `if(!recoverySections(changes,nextPositions,list[0]))return false;`: all 19
original focused cases and both existing scripts passed. Repository
implementation files were not edited.

Another agent added Song and Band Redo regressions that start a different
section before recovering the original one. The small read-only
`publishedAttempts()` harness seam captures cloned candidate state and journal
before storage refusal or live-state mutation. The cases assert exclusivity at
that boundary, unchanged live playback/history on failure, equal complete
candidates on retry, committed/live agreement, and Band primary state and phase
retention. This tests the storage contract without duplicating normalization.

The final independent run passes all 21 focused cases and both existing scripts.
Two independent in-memory mutations were then checked: removing normalization,
and moving normalization after publication. Each mutation fails exactly the two
new Song/Band cases at the publication-candidate assertion; the original 19
cases still pass. The test gap is resolved, with no implementation changes by
this reviewer.

## Browser and visual evidence: author verification

The authored normal-route suite passed Chrome and Firefox using the actual
`segnoDemo` mapping dispatch and fake time. It covers four recorded beats at
shared offset 6 inside a 16-beat cycle, unchanged playback on the established
track, no mode confirmation, actual `Storage.prototype.setItem` exceptions on
partial Undo/Clear All/grouped Undo, retry, persisted history after reload,
newer-audio group protection, and later Mixer/FX preservation. Clear All is
exercised with both initial and overdub captures and a next-bar queued track.

Sparse playback is checked through the shared display data and rendered SVG:
the meter is zero outside the recorded interval and nonzero inside it; only one
bar of the four-bar contour contains peaks. Screenshots of the accepted Wave
view and the selected small display were inspected in both browsers. This is
symbolic audio and simulated metering evidence, not native audio validation.

## Anti-patterns and recommendations

No tautologies, source-text acceptance assertions, empty tests, or mocked
implementation under test were found in the independently reviewed cases.
No actionable test-quality recommendations remain in this bounded review.
Do not advertise the reported test/harness coverage percentage as implementation
coverage or count authored browser review as independent.

## Checked hashes

SHA-256 values identify the checked working files, not a commit or PR head.

| File under `docs/design/` | SHA-256 |
|---|---|
| `stage-transport-study.js` | `3ca5fcc49b8b184406f2691408ceef427b40da79c523ef3f4df2bdd720e866b4` |
| `length-performance-study.js` | `e60f3bdc358e2455cd21ecfc4fbab3ce83a2ab732431c774354d6ecfbaef1337` |
| `stage-display-study.js` | `5dade15c26d7d861c5071e2794a400c74a78b7de42369ea50610661510ba0a12` |
| `fx-ux-prototype.html` | `38e60242e40451630bda5bdf56ac36c2610e4217965e53fadd0c5223fb62a58c` |
| `audio-state-test-harness.cjs` | `faa165ef0aff054c66dbe343046a497e3bfd5bd2a7f19531b5f7bf35315270d4` |
| `verify_capture_recovery.cjs` | `de76c06837e5f98073eeae7ac60f2a0893510e8fa67907142d8e646f89d2d591` |
| `verify_stage_transport.cjs` | `3aff6dd13b31c3b701ed0096c3f7424bebe2e83ce6c484b49216436dc9e4be44` |
| `verify_audio_state_reconciliation.cjs` | `ab6502cdb5941eb3e7f22246126dd31af3549e639fb67d51e6057523e6be6523` |
| `verify_capture_recovery_browser.cjs` — authored evidence | `90e76a69b1383653e12ac95304aef718918a01332fd7d9c8c4f6b02bc6634c34` |
| `capture-recovery-scenes.js` — review fixture | `06a5d0b498089da501dfef640eddd7ffcf3ed34d77264cee19dd6aab55ed391a` |

## Verdict

The independently reviewed tests pass the quality bar for this bounded slice.
No unresolved Critical, Important or Suggestion findings remain. The previously
missing section-publication regression now rejects both verified mutations.
This is not a native implementation, CI, merge-readiness or whole-audit verdict.
