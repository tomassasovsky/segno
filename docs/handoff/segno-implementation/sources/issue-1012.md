# #1012 Slice 2: recording, timing and reversible audio edits [open]

Second slice of epic #1009 (implementation-map.md item 2), built on slice 1 (#1010, PR #1011).

Accepted contract: docs/handoff/segno-app/accepted-behavior.md section 2 (loops, timing and audio-edit history), docs/design/2026-09-07-loop-mode-transitions-ux.md, docs/design/2026-09-06-loop-setup-ux.md, docs/design/2026-09-08-capture-recovery-ux.md, docs/brainstorm/2026-09-07-undo-redo-brainstorm-doc.md.

## Parts (each its own PR, in order)

- [x] 2a. Reversible audio edits and mode rules (PR #1013, stacked on #1011) (engine + repository): mode change with recorded audio (compatible while stopped, explicit stop-and-switch while playing, blocked by capture and queues; Multi equal spans, Sync/Band integer primary relationships, Song/Free independent; no trim, repetition, stretch or deletion); Undo during overdub removes the in-progress layer and returns to playback with Redo recovery; Undo during the first recording cancels the take and leaves the track empty, Redo restores it and plays immediately; a partial Multi take keeps its position with silence elsewhere; Clear All as one grouped edit (one Undo restores every track's content, layers, lengths and previous playing/stopped state; interrupted captures come back stopped and recoverable; cancelled arms stay idle).
- [x] 2b. Timing ownership (PR #1014, stacked on #1013) (engine + repository + settings): per-track record timing (Immediately, Loop start, bar, half, quarter, eighth, sixteenth) inheriting from a default; per-track overdub decay inheriting from a default; Loop/Once per track in all five modes; count-in and Sound start mutually exclusive.
- [x] 2c. Loop settings surfaces (PR #1015, stacked on #1014) (app): hub with the six accepted submenus (Loop mode cards with the switch dialog, Recording, Tempo & click, Length & quantize and Playback & overdub with the Tracks / Defaults / 1-8 selector, Audio & tempo as a readout of the settings its native contract does not yet exist for), Undo/Redo/Clear All wiring from touch, keys and pedals; goldens; pen departures written back.

## Gates

Native suites (plus ASan and telemetry-off variants), ffigen regen and format after API edits, package and root tests at the CI coverage floors, dart analyze in each touched package, bloc lint, cspell; /code-review clean and CI green before ready-to-merge. Hardware timing and latency proof is out of reach here and stays listed as not verified.



