# VGV review — model and UI

Review basis: base `06633b2b537efba4c59108e38764e58c0b2c542e` plus the exact 19 file hashes in the original model review source manifest (fingerprint `854620d05942b5d8bd5a971e4095d5a38b882ff6d46e56e3e5537861207da3ff`). One Astra reviewer applied five role definitions sequentially; these are five perspectives, not five independent people. This reviewer authored runtime/coordinator/session changes and does not independently certify them. The reviewed model, resolver, catalogue, labels, endpoint UI and tests were authored by Sol. No tests, product edits, Git changes or delegation were performed during this review.

## Result

No unresolved actionable findings in the scoped reviewed file set. The Flutter/Dart implementation preserves presentation → state owner → repository boundaries. Pure target parsing/conversion remains in binding model code; human-readable values remain in view formatting. Widgets use existing state callbacks rather than importing data clients. Strict target coordinates reject malformed serialized shapes and retain valid unavailable identities for repair. No compatibility alias or migration was added for the corrected TrackVolume range.

The shared gain helper matches the active Mixer fader law and its extraction in `mixer_column.dart`; track, lane and monitor gain have one normalized travel meaning. Pan/balance and output level retain their actual domain laws. Existing test seams and required generated artifacts are preserved.

## Resolved review finding

M310-5: External expression and button endpoint arrows updated the parent draft, but Escape only reset the slider preview because these consumers omitted `onEditCancel`. A later Save could retain the cancelled change. The endpoint widgets now forward the opening value to their existing parent callback (`expression_controls_panel.dart:313`, `external_controls_editor.dart:459`). Real page regressions assert saved values after Escape, plus a following committed expression edit. The observed red log reproduces the prior button value 0.41; final 74-test log passes. MIDI already forwarded cancellation and now has a stronger Save assertion.

This was an existing endpoint gap explicitly accepted by root as part of this touched UI slice. No further VGV issue was found. Whole-application checks and publication state remain root-owned gates.
