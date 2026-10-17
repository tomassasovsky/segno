# MIDI device selection recovery review

Issue #1101, part of #1026. Reviewed October 4, 2026 against base
`92a35f7a30272c330e39250cf28e21ea74d36b99`, including the complete working
diff and new review record. Human merge gate retained.

## Scope

One atomic saved MIDI device record, selection/deselection lifetime and failure
classification, persistent warning and Retry controls. The ten implementation
and test paths are an isolated extraction of previously reviewed architecture
corrections. No Count-in, settings-owner refactor, native protocol, platform
project, or unrelated artwork change is included.

The coordinator checked the complete extracted diff, removed two-key storage
behavior, hydration and hotplug callers, serialized selection ordering, disposal,
UI error handling, localization and regression assertions. Production blocks
match the reviewed integration source. Independent VGV, architecture, simplicity
and test reviews from that source are reused for unchanged mechanisms; this is
not a claim of another independent review of the extraction.

Claude's adversarial review of the original correction found that native open
exceptions after a successful save were incorrectly labeled as storage failures.
That defect was independently reproduced and repaired by separating the two
exception boundaries. The final independent source review and unchanged
regression confirmed the distinction. No remaining actionable finding was
identified in that boundary or in this extraction.

## Behavioral checks

- Immediate input cutoff while a durable selection is pending; stale queued
  selections cannot reopen the previous device.
- Failed, dropped and mutation-before-error storage operations preserve visible
  uncertainty; Retry is available after reopening the page.
- ID and name are written as one strictly decoded record. Obsolete separate
  keys are removed from the implementation, with no compatibility fallback.
- A confirmed pin followed by a native open error remains eligible for reconnect.
- None and selected-device recovery are separate from MIDI mapping On/Off
  recovery; successful unrelated controls do not hide the device warning.

Package results: MIDI device repository 35 passes, 94.969% coverage; settings
repository 193 passes, 90.960% coverage. MIDI page 52 passes. Strict scoped
analysis, eight-file formatting, whitespace and Bloc over 764 files pass.
The complete app passes 2,676 tests with 124 conditional skips and
91.068% CI-filtered coverage. All ten source hashes remained unchanged
during validation.

## Limits

No physical MIDI device, appliance or native driver failure was tested here.
Existing app/native behavior outside this correction is not certified by these
focused checks. Remote CI and approval labels must refer to the published head;
local review alone does not make the PR ready to merge.
