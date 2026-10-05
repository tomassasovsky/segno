# Clear history and stationary Fade review

Issue #1142; base `c2e1d728293e2db03848362d6027cbc84692c468`.
Human merge gate. This is the Clear/history portion of durable Fade.

Clear captures the coefficient actually applied by the audio callback. Undo
restores it as a stationary level before playback, preserving ordinary mute and
frozen-capture history. A bounded native completion mailbox replaces the obsolete
frozen event. The existing performance recorder stages exact restored audio and
logs its applied identity, state and phase; no additional recorder, queue,
repository owner or public API is introduced.

The final 22-path candidate has SHA-256
`acdb9ac021d421f0544981210c15eabd85e6489d505f9d9113b0ab0ed495fbe9`.
Production adds 323 lines and removes 108; tests, bindings and documents are
counted separately. Publication adds this report and the progress summary only.

Root and independent reviewers covered all changed source, callers, removed
invariants, architecture, VGV conventions, real-time ownership, FFI, test quality
and simplicity. Findings repaired during review were lost late layer retirement,
missing restored audio in exports, source lifetime errors on Undo-to-empty and
overdub, a double-swap identity race, and a final drain that erased an incomplete
capture marker. A grouped mute test was strengthened to use a playing muted track,
so stopped transport cannot make its silence assertion pass. No actionable local
source-review finding remains. These are grouped review roles, not five separate
independent reviewers.

Validation:

- Normal, AddressSanitizer and telemetry-disabled native suites pass. Each runs
  750 core, 25 MIDI, four scan, 11 slot and three engine-race tests, plus the
  existing plugin runtime and FX ownership checks. After the final three-line
  test-only correction, its grouped fixture passes all three configurations;
  unchanged production and other tests retain the full-suite evidence.
- Six actual-native repository tests pass without skips using the fresh complete
  CMake library. All 187 generated FFI lookups resolve. The reduced test library's
  missing MIDI exports are not credited as complete symbol evidence.
- Ordinary Looper tests pass 716 cases with 44 conditional native skips and
  95.438% coverage; Performance passes 130 with 99.333%. The focused application
  suite passes 317. These unchanged Dart inputs retain their bound evidence;
  no full application coverage run is claimed for this slice.
- Strict analysis, explicit six-file formatting, positive six-file Bloc lint,
  regenerated bindings, surviving event-code parity and the C++ header check pass.
  The removed event is 102; surviving numeric values do not change.

The PCM checks use independent literal samples, nonzero playback phase, frozen
partial capture and grouped mute, plus real staging refusal, missing or malformed
images and bounded capacity failure. Aborted runs sharing temporary executables
and historical failing fixtures are preserved separately and do not count as
passing final evidence. Reviewers did not duplicate the author's test runs.

General ordinary history reconstruction remains #1143: unsupported material
changes fail the affected derived stem instead of silently exporting stale audio.
The separately captured master remains available. A full layer manifest no
longer stops the capture: the drain drops later images, reports
`layers_dropped`, and keeps recording master and monitors; in such a capture
the renderer fails any stem whose logged retire is unlisted (adversarial review
finding, owner decision 2026-10-05). Unconditional fail-closed matching was
tried and reverted: unstaged retires at disarm, Clear, device-change and
arm edges are preexisting and would have turned brief stale tails into failed
stems; exact logged-retire staging and ordered key matching belong to #1143. The render arena now covers a full
manifest; input-derived sizing and whole-render failure reporting remain #1144.
Multi-lane
reconstruction, full-engine reopen (#1140), physical devices and listening tests
are outside this proof.

Actual Claude review, published-head CI and human merge remain separate gates.
This local review does not authorize merging or deploying the branch.
