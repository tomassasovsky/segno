# Simplicity and removed-behavior review

Reviewed the complete staged and working production diff against
`origin/master` (`848f13372519`) in the restack workspace, including the
accepted first design slice and its current integration corrections.

## Simplification Analysis

### Core Purpose

Present the active bank as Track columns or Wave rows, show the selected
track on the second display, and derive the crown, waveform coordinates,
bar count, position and output peak from the owning engine or repository.
Retire the superseded secondary-display mixer and its command channel.

### Unnecessary Complexity Found

- **Suggestion — remove unused selected-track readout fields.**
  `lib/visualizer/performance_readout.dart:12` and `:16` retain `pending`
  and introduce `layers`, but neither value is read by the selected-track
  face or waveform window. They still have constructor defaults, wire
  decoding, serialization and equality entries. The app fills both fields
  (`lib/app/view/app.dart:1017`, `:1028`) and explicitly watches `pending`,
  `undoDepth` and `hasContent` in `_sameReadoutFacts` (`:976`–`:982`) for
  them. Consequently an arm or retired layer can push a new readout and
  rebuild the second display while changing nothing it draws.
  Remove these two DTO fields and their projection/gate-only inputs, with
  matching fixture updates. Keep the domain `Track` fields: the main Track
  and Wave views use them. The existing bar-count comparison already covers
  changes to the rendered completed-bar count.

### Code to Remove

- The unused `ReadoutTrack.pending` and `ReadoutTrack.layers` constructor,
  field, codec and equality plumbing, plus the app projection and gate
  conditions used solely to transmit them.
- Estimated production reduction: approximately 20 lines, with additional
  fixture reductions. No documents should be removed.

### Simplification Recommendations

1. Narrow the second-display payload to the facts its current face consumes.
   This completes the otherwise thorough removal of the old multi-track
   readout data and reduces the maintenance surface of its change gate.

### YAGNI Violations

The two unused readout facts above are the only concrete unused extension
found. No speculative abstraction or broad redesign is recommended.

### Removed-behavior and reuse checks

- The volume overlay, `ReadoutControl`, channel method, service callback and
  app dispatch handler are removed together. A production-call site search
  found no surviving caller of these deleted APIs.
- Removal of the MIX entry, all-track second-display face, main-bar mode
  pair and tappable crown agrees with the slice's recorded decisions. The
  crown handoff API/event intentionally remains for the subsequent settings
  slice; the explicit-crown test seam still reaches the repository.
- Main-view commands continue through the existing blocs. Wave-row tap and
  long-press behavior follows the Track column's record/mute/FX and stop
  behavior. Library uses the existing sessions manager, and settings,
  performance-record completion and clear-all undo listeners remain wired.
- Both displayed bar counts call `Track.wholeBars`. The app's readout gate
  compares that derived value, including changes to the actual master grid
  or sample rate that affect it, instead of duplicating the duration math.
- Both waveform consumers use the repository's single per-track cache.
  Native track visual buckets and published positions now use the same
  full-track read coordinate. Clear/undo-to-empty resets only that track's
  visual data; stopped tracks keep their recorded shape. The existing
  sweep cache remains necessary while the native visual buffer is filled
  lazily, so replacing it with a one-shot copy would reintroduce stale
  waveforms.
- The new native snapshot fields are projected into their Dart model,
  equality and generated FFI structure. Crown reconcile calls cover
  completed takes, content removal, restore/redo and session import.
- The fixed-size Wave layout is being independently investigated by the
  architecture reviewer. This review does not claim that desktop size case
  passes and does not duplicate an unverified layout finding.

### Validation and limits

This was a source and caller review. Inspected the relevant waveform,
readout, meter, Track/Wave, repository and native regression-test changes;
did not rerun the parent's validation suites or claim fresh test/CI,
visual, appliance, audio or deployment evidence. No implementation or ref
changes were made.

### Final Assessment

No additional actionable bug was established in this review. One small
payload cleanup is recommended. Complexity is low to medium, principally
from the necessary polling and waveform-sweep behavior; no broader
simplification is justified by the current requirements. Potential
production reduction is approximately 20 lines, less than 1% of the
changed code. Recommended action: minor cleanup only.
