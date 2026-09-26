# Pedal closure prototype pass

September 8, 2026. Bounded D2 work under the approved design pass for
[issue #919](https://github.com/tomassasovsky/segno/issues/919) and the
[audit closure plan](../plan/2026-09-08-audit-closure-plan.md). This records
prototype behavior for LX-063, LX-089 and LX-095. It does not close the full
comparison or establish production audio, storage or physical pedal behavior.

The accepted ten-pedal layout, separate Press/Hold assignments and fixed
MODE/Exit and BANK controls remain the basis of the interaction.

| Audit item | Prototype behavior | Remaining evidence |
| --- | --- | --- |
| LX-063 | Hold REC/PLAY in Transpose, or assign Toggle transpose, to bypass or enable transpose globally. Every stored shift remains intact. | Matching Pen reference; eventual engine and device proof. |
| LX-089 | Clear custom assignments reviews both banks and both gestures. Confirm changes the draft; Save applies it. Restore assignments recovers the previous mappings within the current setup visit. | Matching Pen reference; eventual production persistence proof. |
| LX-095 | Multi, Sync, Song, Band and Free shortcuts appear in the shared Loop modes assignment group and dispatch to the existing Settings mode owner. | Matching Pen reference; unresolved D3 clock rules and production proof. |

## Transpose

`transpose-performance-study.js` keeps the stored `pitches` separate from
`enabled` and the projected `effectivePitches`. Bypassing sets effective shifts
to zero without writing the stored values. The display labels those values as
stored while bypassed. Changing banks, selecting other tracks or reentering
Transpose does not enable it or reset a pitch.

Pitch up/down still edits the selected stored values while bypassed. Hold on
either pitch pedal still resets the selected values to zero; Reset does not
enable transpose. A refused enable-state write preserves the previous state.
The browser remains silent: effective-pitch state is a contract demonstration,
not a pitch-shifting audio processor.

The host supplies `transposeState.enabled()` and `setEnabled(boolean)` using
the session rig's `transposeEnabled` value, with rollback on save failure. The
direct action `command:transpose-bypass` dispatches operation
`transpose-bypass`; the performance owner calls `transpose.toggleEnabled()`.
Holding REC/PLAY consumes its short gesture through the existing performance
gesture owner. Capture exclusion for pitch edits remains separate from the
global enable-state toggle.

## Clearing custom assignments

The entry is in Pedals → Custom controls. Its confirmation explicitly names
**both banks A and B, Press and Hold, every editable custom pedal**. There is
no hidden current-bank scope. MODE keeps Exit and BANK keeps bank switching.
Track-mode settings, LED colors, custom colors and unrelated state are preserved.

Cancel or Escape closes the confirmation without changing the draft. Confirm
clears only the editable custom pairs. The previous custom mappings are kept
for Restore assignments; both the clear and restore remain drafts until Save.
The existing setup Cancel returns to saved state. Leaving setup discards the
draft and its temporary recovery point. This is setup work, not an assignable
performance command.

Actions use the existing button and encoder dispatcher:

- `setup:clear-custom`: open confirmation, focusing Cancel.
- `setup:clear-cancel`: close without changing assignments.
- `setup:clear-confirm`: clear both banks in the draft, focusing Restore.
- `setup:restore-custom`: restore the previous draft assignments.
- Existing `setup:save` and `setup:cancel`: apply or discard the draft.

`pedalUI.write(value)` returns false on a refused save. The host must restore
the prior saved rig value before returning false; the editor retains the draft
and recovery point and displays the failure. Recovery does not rewrite LED
colors or other fields edited after clearing.

## Loop-mode shortcuts

The shared catalogue adds `loop-mode:multi`, `loop-mode:sync`,
`loop-mode:song`, `loop-mode:band` and `loop-mode:free`. These are direct
commands, not performance-view entries. Existing Custom, external-switch and
MIDI action pickers receive the same keys and Loop modes group.

`mapping-action-dispatch.js` calls the host's `loopMode(mode, token)` callback
once. The host asks `loopUI.modeAvailability(mode)` and routes accepted requests
through `loopUI.action('loop:mode:' + mode)`. It must use the existing playing
confirmation and recheck the existing guard at confirmation. The dispatcher
forwards the source token and reports an unavailable owner instead of claiming
success.

This pass does not change the length-compatibility matrix, primary-track
selection rules or clock behavior. The existing equal-length Multi and primary
length relationship checks for Sync/Band remain authoritative for the prototype.
The coordinator integrated foot Cancel/Confirm routing: MODE cancels and STOP
confirms. Playback stays unchanged until confirmation, and the previous
performance view, bank and target remain selected. A recording begun while the
confirmation is open blocks the transition on the second guard check.

## Verification

Observed locally on this pass:

- `node --test docs/design/pedal-closure.test.cjs`: 6 tests passed. Covers
  distinct pitches and global bypass, selection/bank/reentry, Reset while
  bypassed, refused bypass save, custom clear/cancel/save/restore, fixed-state
  preservation, refused settings save, five mode shortcuts, playback
  confirmation/cancellation, capture recheck, queued actions, refused mode save and incompatible
  mode feedback. Mode cases use the existing audio-state test harness and
  Settings mode owner; they do not run audio.
- `node docs/design/verify_mapping_parity.cjs`: all 7 existing mapping contracts
  passed, including the 64 reference MIDI action mappings and momentary release.
- Node syntax checks passed for the four changed study modules.
- `node docs/design/verify_pedal_closure.cjs`, with Playwright available:
  Chrome and Firefox passed the integrated journeys. Tests assign all five mode
  shortcuts through the real Custom chooser, then trigger, cancel and confirm
  through the physical-pedal simulator. They also cover hold consumption,
  cancelled holds, global transpose bypass, bank/Reset independence, the custom
  clear dialog through touch/encoder/Escape, Save/Restore, incompatible and
  capture/queued refusals, capture recheck, ordinary-URL reload and refused-save
  rollback for transpose and pedal settings.
- The [preview directory](pedal-closure-previews) contains the two browsers'
  confirmation, cleared-settings, bypassed-transpose and foot-mode-confirmation
  screenshots, plus verification records. Screenshots were visually inspected;
  the long transpose Hold caption was shortened before final capture. Browser
  checks cover the 1920 × 1080 bounds of buttons, captions and dialogs.

Saved Pen synchronization belongs to the coordinator's integration pass.
No production files, native or Flutter checks, physical-pedal tests, commits,
publication or audit-baseline status edits are part of this bounded subtask.
