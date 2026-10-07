# VGV Code Review

## Summary

Reviewed the reconstructed first design slice against `origin/master` (`848f1337`), including the resolved staged merge and the accepted Tracks, selected-waveform, and crown implementation from `ec3e25f0`. The implementation retains the repository boundary, immutable Bloc state, native ownership of crown and transport facts, and deliberate removal of the old readout control channel. One concrete display correctness issue needs correction before merge: both displays infer track bars from the master loop's bar count and a multiple that does not describe every supported track length.

This is a source review of this reconstructed slice. Validation from the later integration tip and the original September 9 implementation does not certify this revision. The parent is running current analysis and tests. Hardware and two-screen appliance behavior are not verified here.

## Critical — Must Fix Before Merge

- **`lib/looper/view/tracks_view.dart:397` and `lib/app/view/app.dart:1022` — Project bars from the recorded track duration.**
  - Why: Both new projections calculate `transport.loopBars * track.multiple`. For a divided Sync/Band take, native `finalize_new_track` sets `multiple = 1`, stores a separate divisor, and records `base / divisor` frames (`packages/segno_engine/src/core/engine_process.c:1054`). With a four-bar base and divisor four, the one-bar take is therefore labeled four bars in Tracks and the selected-track readout; Wave also draws a four-bar ruler. Independent Free/Song take lengths likewise cannot be inferred from the master multiple. The existing native half/quarter-division tests establish that this is a supported engine state, not a hypothetical input.
  - Fix: Add one domain projection based on the track's completed duration and available tempo/grid facts, and consume it from Tracks and the selected-track readout. Return unknown for absent tempo/sample rate or non-whole musical lengths, keep recording growth outside chrome/readout rebuild gates, and cover divisions, multiples, and independent lengths in behavioral tests.

## Important — Should Fix

None beyond the bar-count regression coverage required with the correction above.

## Suggestions — Nice to Have

None.

## Simplicity Assessment

- Lines that could be removed: the duplicated bar-count formulas once a shared domain projection replaces them.
- Unnecessary abstractions: none identified in the intended slice.
- YAGNI violations: none identified; removal of obsolete small-display controls follows the accepted slice ledger.
- Complexity verdict: focused correction needed. Native atomics, repository waveform caching, and leaf meter selectors preserve the existing real-time and rebuild boundaries.

## Testing Assessment

- New behavior has native, repository, model, widget, and golden coverage. Crown ownership, pending triggers, layers, independent play positions, waveform refresh, count-in text, and equal-name selection handling have meaningful existing assertions.
- Missing edge case: displayed bars for Sync divisions and independent Free/Song durations. Existing view fixtures only assert the master-times-multiple case.
- State management coverage: reviewed as part of the intended changed surface; no additional uncovered state-management defect identified.
- UI component coverage: substantial, but the shared duration projection needs regression coverage in both its domain calculation and visible bar/ruler updates.
- No test execution performed by this review role for this reconstructed revision; parent-run gates and independent testing review remain separate evidence.

## Follow-up Ownership

After this independent report was saved, the parent assigned the bar-count correction to this agent in a bounded set of implementation files. A different agent must independently review that correction; this report does not certify its author's subsequent changes.
