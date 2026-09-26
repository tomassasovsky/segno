# Library and repair closure pass

September 8, 2026. Prototype and design work under the existing
[console redesign issue](https://github.com/tomassasovsky/segno/issues/919) and
[closure plan](../plan/2026-09-08-audit-closure-plan.md). This pass covers LX-084,
LX-168 and LX-181. It does not claim production media operations, a storage
measurement, a native preset format, or physical control verification.

## Preset packages — LX-084

My presets now opens an appliance chooser for both Import presets and Export.
Internal and USB drive are the same two locations used by the Library. The
chooser uses the existing compact blue-grey controls, encoder focus, and a
bottom keyboard for package names. This is a simulated media directory,
persisted separately from the prototype rig; it does not establish a new
session/global ownership contract.

Import selects a package, reads it, and opens the existing preset review before
adding independent copies to My presets. Cancel at either step preserves the
library. The existing codec validates the complete package and gives duplicate
preset names a numbered suffix. Export writes a new package and uses a numbered
filename when a package already has the same name. No existing package is
replaced. The source preset remains available throughout.

A canceled transfer cannot finish later. Missing media, drive replacement during
transfer, malformed JSON, concurrent storage work, insufficient space and failed
writes retain the prior library/files and expose a retry. USB work shares the
host's transfer, eject and power gates. A complete package read is retained for
review even if USB is subsequently removed; the review does not depend on a
partially read external file.

The appliance host uses `SegnoMediaClosure.createPresetInterchange` through the
preset UI's required media adapter. The obsolete browser download/file-input
helpers and their fallback path have been removed. The codec's existing byte/module/package validation
limits are unchanged by this chooser pass. Their relationship to an unlimited
personal collection is still an open capacity decision in D4; they are not an
approved device budget.

## Remaining recording time — LX-168

Storage shows a time estimate for the Internal volume, its recording format,
and the reserved space used in the calculation. Unknown inputs produce
“Recording time unavailable”; they never produce invented capacity.

The calculation is:

```
usable bytes = max(0, free bytes − reserved bytes)
bytes per second = sample rate × bytes per sample × channels × recording streams
remaining seconds = floor(usable bytes / bytes per second)
```

The default prototype fixture uses 64 GB free, a 1 GB reserve, 48 kHz, 24-bit
PCM, two channels and one simultaneous recording: 60 hr 45 min. The low-space
fixture has 0.2 GB free and reports no recording space after reserve. These are
visible design assumptions, not a measured appliance limit or an approved
capture format. The host reads the applied audio-device sample rate; an
unapplied device draft leaves the estimate unchanged. Applying 96 kHz halves
the same capacity to 30 hr 22 min. The existing Storage simulator accepts
`freeBytes` and `null` for unknown space, updating both the capacity card and
time together. A format-only adapter keeps storage state out of its own
snapshot callback; a higher stream count reduces the estimate. Undo audio and other writes
also consume capacity. USB capacity does not imply recording directly to USB.

The added estimate fits alongside both volume cards and the low-space message
at the prototype's 1920 × 1080 canvas.

## Shared repair and return — LX-181

Expression mappings, external switch parameter mappings and MIDI parameter
mappings use one Repair control sheet. Missing controls stay visible with their
source identity. The sheet follows the existing destination → control pattern,
then shows the replacement and the source's endpoint values before Apply repair.
Continuous targets retain normalized positions, including inverted ranges;
targets with discrete values use their existing coercion and show the resulting
values in review. Repair never writes to a live audio parameter.

Apply changes only the source editor's draft and returns focus to the original
mapping control. The source's normal Save persists it; Cancel setup abandons it.
Calibration, hardware identity, switch conditions, MIDI source/channel/behavior,
sibling controls, and unrelated settings survive the repair. Cancel or Back in
the sheet returns without changing that draft. A mapping changed while repair
was open, a replacement removed before Apply, or a rejected apply leaves the
original intact and reports the problem.

External pedal Save now publishes its settings and staged FX activation changes
in one host write. A failed write restores the host rig, retains both drafts,
and displays “Could not save. Your changes are still here.” Retry uses the same
pending repair. The source no longer displays Saved after a rejected write.

This repair resolves missing parameter references. Disconnected physical
controllers still use their connection/calibration journeys. A deleted FX rack
also removes its source-owned activation rule; this pass does not manufacture a
second copy of that rule in a repair store.

## Backup and ownership remain proposals

Full appliance backup is not implemented by preset interchange or by the
existing session backup. A future review should present a manifest before
restore, distinguish musical/session assets from physical identity/calibration,
and allow an explicit choice before adopting another appliance's physical
settings. Restore must stage a complete bundle, preserve the playable rig on
failure, and return to the initiating Library context.

The existing session pedal setup remains accepted. The broader disagreement
between the prototype's session snapshot and device-global settings needs an
owner decision before production schema changes. This pass neither changes that
boundary nor treats a session archive as a complete appliance backup.

## Verification

The focused Node suite exercises the formula, both media locations, review before
import, duplicate names, cancellation, storage failure, full destination, drive
replacement, stale files/targets, inverted repair ranges, and all three source
editors' draft/Save/Cancel behavior. The existing FX and media suites also pass:

```
node --test docs/design/media-closure-study.test.cjs \
  docs/design/fx-parity.test.cjs docs/design/media-parity-study.test.cjs
```

Result: 42 passing tests, including 14 focused closure tests.

`verify_media_closure.cjs` runs the main prototype in fresh Chrome and Firefox
contexts. It verifies Internal/USB export and import, the bottom keyboard,
explicit import review, cancellation and hotplug, failed persistence and retry,
package persistence after reload, expression/switch/MIDI repair and return,
source Save/Cancel, the applied sample rate versus an uncommitted draft,
changed/unknown free space, failed source Save with retry, atomic publication of a repaired
switch parameter alongside a staged FX activation rule, and the normal/low-space
layouts. The existing external-control and Storage browser suites also pass in
both browsers. The existing expression journey now follows shared Repair and
the current Stage startup navigation; it passes in Chrome and Firefox. The
isolated FX browser test uses the required appliance adapter and passes in
Chrome. Screenshots are in
[closure-previews](closure-previews), with `preset-`, `repair-` and
`storage-recording-time` prefixes. These are author browser evidence, not CI,
native audio or appliance evidence.

Pen reconciliation is handled in the enclosing design pass. Design closure
still requires the saved Pen references and owner review; production closure
still needs real media operations, atomic filesystem publication, storage
measurement and appliance validation.
