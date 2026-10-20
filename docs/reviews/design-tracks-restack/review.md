# Tracks reconstruction review

Date: 2026-09-15. Scope: the accepted first Tracks implementation (#1010,
PR #1011), reconstructed on master `848f1337` with original slice
`ec3e25f0` retained as a merge parent. Later FX, assignments, MIDI and
performance flows are outside this review.

## Roles and resolutions

All five required roles reviewed the intended first-slice diff. The original
reports remain under [raw](raw/); their initial findings are historical.
When a reviewer subsequently authored a correction, the architecture reviewer
independently inspected that correction before resolution.

| ID | Finding | Resolution and evidence |
| --- | --- | --- |
| T01 | Waveforms and playheads used different coordinates for multiples and divisions. | Native per-track samples and snapshots now share the resolved full-track position; repository caching uses the same clock. Native and repository tests distinguish track and master wraps. |
| T02 | A running sibling erased a stopped track's waveform before it was first displayed. | Stopped native buffers retain their samples; Clear and Undo-to-empty reset only the removed track. Native audio-pattern tests cover retention, clear, undo and redo. |
| T03 | Both displays calculated bars from master length times a multiple. | One domain projection uses actual finalized frames and known musical timing, with unknown/fractional values left unknown. Domain, view and app tests cover divisions and independent lengths. |
| T04 | App tests counted waveform sends without asserting the selected samples. | Distinct track buffers and phases are asserted through the real app bridge, including equal names and empty selection. |
| T05 | New native snapshot fields lacked projection assertions. | Generated native structures exercise position, queued trigger and output peak through Dart projection and equality. |
| T06 | Native playhead tests covered only the simplest clock. | Multiple, divided Sync, Free and Song cases assert actual frame positions and stopped retention. |
| T07 | Four Wave rows overflowed the retained 800×600 desktop launch size. | Metadata scales within its allotted row. A four-track layout and touch regression passes; full appliance geometry remains unchanged. |
| T08 | Settings and ownership comments described the retired mixed-output display. | Both locales and waveform documentation now describe the selected-track display and its actual buffer ownership. |
| T09 | The compact-layout comment failed fatal analysis. | Comment wrapped; final static results are recorded in the validation report. |
| T10 | Unrendered pending/layer data enlarged the small-display payload and update gate. | Removed from the readout DTO, codec, projection and gate. Domain state and main-track indicators remain intact. Independent architecture review found no remaining caller or behavior gap. |

The final full suite also exposed a pre-existing wall-clock race in a
knob-save debounce test. Its correction is confined to test scheduling;
the save implementation and all 20 behavioral verification statements remain
unchanged. Independent architecture review checked the eight repaired tests,
and the full app rerun passed.

## Gate and limits

The local bug-focused gate is clean. It covered changed hunks and callers,
removed controls and listeners, C/FFI/snapshot/window boundaries, callback
ownership and bounded work, reuse, teardown, recovery, and project conventions.
Its local report remains in the repository's ignored code-review workspace.

See [validation](validation.md) for observed checks on the final contents.
Original PR CI and later integration-tip
checks do not certify this reconstructed revision. Remote CI must run on the
published head. The existing human merge gate and appliance verification
requirements remain in effect.
